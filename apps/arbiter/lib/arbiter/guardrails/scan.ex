defmodule Arbiter.Guardrails.Scan do
  @moduledoc """
  Pure classifiers for guardrail event capture (G17,
  `docs/design/guardrail-profiles.md` §6.1). No I/O: callers hand in a tool
  name and its input map and get findings back.

    * `tool_input/2` is the **transcript hidden-channel scan**. It reads the
      input of a tool call the worker made, never prose, and reports

        * `:hidden_channel_attempt` (critical): an *executed* `systemd-run`,
          `busctl`, `secret-tool`, `dbus-send`, `gdbus` or `gh auth token`;
        * `:credential_read` (major): a reader command (`cat`, `tar`,
          `sqlite3`, …) aimed at a credential directory or the install DB, or a
          file tool whose path argument is one.

      A shell command is tokenised with quote and operator awareness, so
      `git commit -m "block systemd-run"` and `grep busctl lib` name the
      program only as an argument and do not flag. After G1 these calls fail,
      but trying is the signal.

    * `denial/2` classifies a tool call the permission layer refused: a public
      upload host is critical, a safe-default category (force push, `rm -rf`,
      `gh gist create`, …) is major, anything else minor.
  """

  alias Arbiter.Agents.SecurityPolicy

  @type finding :: %{kind: atom(), severity: :critical | :major, match: String.t()}
  @type denial :: %{
          kind: atom(),
          severity: :critical | :major | :minor,
          category: String.t() | nil
        }

  @shell_tools ~w(Bash bash shell Shell run_command)
  @path_keys ~w(file_path path notebook_path AbsolutePath SearchPath DirectoryPath SearchDirectory)

  @hidden_exes ~w(systemd-run busctl secret-tool dbus-send gdbus)
  @wrappers ~w(sudo doas env command exec nohup time nice ionice stdbuf xargs timeout setsid)
  @shells ~w(sh bash zsh dash ksh)

  @readers ~w(cat less more head tail cp mv scp rsync tar zip base64 xxd od strings sqlite3
              bat sed awk grep rg find ls tree cut sort source dd)

  @credential_patterns [
    {"~/.ssh", ~r{(?:^|/|~|\$HOME|\$\{HOME\})\.ssh(?:/|$)}},
    {"~/.aws", ~r{(?:^|/|~|\$HOME|\$\{HOME\})\.aws(?:/|$)}},
    {"~/.gnupg", ~r{(?:^|/|~|\$HOME|\$\{HOME\})\.gnupg(?:/|$)}},
    {"~/.kube", ~r{(?:^|/|~|\$HOME|\$\{HOME\})\.kube(?:/|$)}},
    {"~/.netrc", ~r{(?:^|/)\.netrc$}},
    {"~/.git-credentials", ~r{(?:^|/)\.git-credentials$}},
    {"~/.config/gh", ~r{\.config/gh(?:/|$)}},
    {"~/.config/gcloud", ~r{\.config/gcloud(?:/|$)}},
    {"arbiter.sqlite3", ~r{(?:^|/)arbiter\.sqlite3(?:$|[-.])}}
  ]

  # ---- the transcript scan -------------------------------------------------

  @doc "Findings for one tool call's input. `[]` for anything not understood."
  @spec tool_input(String.t() | nil, term()) :: [finding()]
  def tool_input(name, %{} = input) when is_binary(name) do
    findings =
      if name in @shell_tools do
        case input["command"] do
          cmd when is_binary(cmd) -> cmd |> segments() |> Enum.flat_map(&segment_findings/1)
          _ -> []
        end
      else
        input |> path_args() |> Enum.flat_map(&credential_match/1)
      end

    Enum.uniq(findings)
  end

  def tool_input(_name, _input), do: []

  defp segment_findings(words) do
    case command(words) do
      {exe, args} -> exe_findings(exe, args)
      nil -> []
    end
  end

  defp exe_findings(exe, _args) when exe in @hidden_exes, do: [hidden(exe)]

  defp exe_findings("gh", args) do
    plain = Enum.reject(args, &String.starts_with?(&1, "-"))

    cond do
      Enum.take(plain, 2) == ["auth", "token"] ->
        [hidden("gh auth token")]

      Enum.take(plain, 2) == ["auth", "status"] and show_token?(args) ->
        [hidden("gh auth status --show-token")]

      true ->
        []
    end
  end

  defp exe_findings(exe, args) when exe in @shells do
    case Enum.drop_while(args, &(&1 != "-c")) do
      [_, script | _] -> script |> segments() |> Enum.flat_map(&segment_findings/1)
      _ -> []
    end
  end

  defp exe_findings(exe, args) when exe in @readers,
    do: exe |> read_targets(args) |> Enum.flat_map(&credential_match/1)

  defp exe_findings(_exe, _args), do: []

  # The arguments of a reader that name something read. A search tool's pattern
  # and a `find` name test are search terms, not paths.
  defp read_targets(exe, args) when exe in ~w(grep rg sed awk), do: strip_pattern(args)
  defp read_targets("find", args), do: strip_find_tests(args)
  defp read_targets(_exe, args), do: args

  defp strip_pattern(args) do
    {kept, explicit?} = strip_explicit_patterns(args, [], false)

    if explicit? do
      kept
    else
      case Enum.split_while(kept, &String.starts_with?(&1, "-")) do
        {opts, [_pattern | rest]} -> opts ++ rest
        {opts, []} -> opts
      end
    end
  end

  defp strip_explicit_patterns([], acc, explicit?), do: {Enum.reverse(acc), explicit?}

  defp strip_explicit_patterns([f, _ | rest], acc, _explicit?)
       when f in ["-e", "--regexp", "--expression"],
       do: strip_explicit_patterns(rest, acc, true)

  defp strip_explicit_patterns(["--regexp=" <> _ | rest], acc, _explicit?),
    do: strip_explicit_patterns(rest, acc, true)

  defp strip_explicit_patterns(["--expression=" <> _ | rest], acc, _explicit?),
    do: strip_explicit_patterns(rest, acc, true)

  defp strip_explicit_patterns([a | rest], acc, explicit?),
    do: strip_explicit_patterns(rest, [a | acc], explicit?)

  @find_tests ~w(-name -iname -path -ipath -wholename -iwholename -regex -iregex -lname -ilname)

  defp strip_find_tests([]), do: []
  defp strip_find_tests([t, _ | rest]) when t in @find_tests, do: strip_find_tests(rest)
  defp strip_find_tests([a | rest]), do: [a | strip_find_tests(rest)]

  defp show_token?(args), do: Enum.any?(args, &(&1 in ["--show-token", "-t"]))

  defp hidden(match), do: %{kind: :hidden_channel_attempt, severity: :critical, match: match}

  defp credential_match(path) when is_binary(path) do
    for {label, regex} <- @credential_patterns, Regex.match?(regex, path) do
      %{kind: :credential_read, severity: :major, match: label}
    end
  end

  defp credential_match(_), do: []

  defp path_args(input), do: for(k <- @path_keys, is_binary(input[k]), do: input[k])

  # ---- permission-layer denials ---------------------------------------------

  @doc "Classify a tool call the permission layer denied."
  @spec denial(String.t() | nil, term()) :: denial()
  def denial(name, input) do
    input = if is_map(input), do: input, else: %{}

    cond do
      host = upload_host(input) ->
        %{kind: :public_upload_attempt, severity: :critical, category: host}

      category = safe_default_category(name, input) ->
        %{kind: :permission_denial, severity: :major, category: category}

      true ->
        %{kind: :permission_denial, severity: :minor, category: nil}
    end
  end

  defp upload_host(input) do
    text = input |> Map.values() |> Enum.filter(&is_binary/1) |> Enum.join(" ")

    Enum.find(SecurityPolicy.egress_deny_hosts(), fn host ->
      Regex.match?(
        ~r/(?<![A-Za-z0-9.-])(?:[a-z0-9-]+\.)*#{Regex.escape(host)}(?![A-Za-z0-9-])/i,
        text
      )
    end)
  end

  defp safe_default_category(name, _input) when name in ["Monitor", "ScheduleWakeup"],
    do: "no_async_wait"

  defp safe_default_category(name, input) when name in @shell_tools do
    with cmd when is_binary(cmd) <- input["command"] do
      cmd |> segments() |> Enum.find_value(&segment_category/1)
    end
  end

  defp safe_default_category(_name, _input), do: nil

  defp segment_category(words) do
    case command(words) do
      {exe, args} -> exe_category(exe, args)
      nil -> nil
    end
  end

  defp exe_category("git", args),
    do: if("push" in args and force_flag?(args), do: "no_force_push")

  defp exe_category("rm", args), do: if(recursive_force?(args), do: "no_destructive_fs")
  defp exe_category("gh", args), do: gh_category(positional(args))

  defp exe_category("glab", args),
    do: if(Enum.take(positional(args), 2) == ["mr", "create"], do: "no_pr_create")

  defp exe_category(_exe, _args), do: nil

  defp positional(args), do: Enum.reject(args, &String.starts_with?(&1, "-"))

  defp gh_category(["gist", verb | _]) when verb in ["create", "edit"], do: "no_gh_publish"
  defp gh_category(["issue", "comment" | _]), do: "no_gh_publish"
  defp gh_category(["pr", "create" | _]), do: "no_pr_create"
  defp gh_category(_), do: nil

  defp force_flag?(args),
    do:
      Enum.any?(args, fn a ->
        a in ["-f", "--force"] or String.starts_with?(a, "--force-with-lease") or
          String.starts_with?(a, "+")
      end)

  defp recursive_force?(args) do
    flags = Enum.filter(args, &String.starts_with?(&1, "-"))

    short =
      for "-" <> f <- flags, not String.starts_with?(f, "-"), reduce: "", do: (acc -> acc <> f)

    recursive? = String.contains?(short, ["r", "R"]) or "--recursive" in flags
    force? = String.contains?(short, "f") or "--force" in flags
    recursive? and force?
  end

  # ---- shell tokenising -------------------------------------------------------

  # `cmd` split into simple-command segments, each a list of words. Quotes
  # protect operators and spaces; `; & | ( ) \n` and backticks outside quotes
  # end a segment. A heredoc (`<<DELIM`, `<<-DELIM`, quoted or not) is data, not
  # commands: its body lines, up to the delimiter line, are dropped.
  defp segments(cmd) do
    {segs, word, cur, _q} = scan(String.to_charlist(cmd), {[], [], [], nil}, [])

    [finish_word(cur, word) | segs]
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == []))
  end

  defp scan([], state, _pending), do: state

  # `<<<` is a here-string, not a heredoc.
  defp scan([?<, ?<, ?< | rest], {segs, word, cur, nil}, pending),
    do: scan(rest, {segs, word, [?<, ?<, ?< | cur], nil}, pending)

  defp scan([?<, ?< | rest], {segs, word, cur, nil}, pending) do
    {heredoc, rest} = read_heredoc_delimiter(rest)
    scan(rest, {segs, finish_word(cur, word), [], nil}, pending ++ [heredoc])
  end

  defp scan([?\n | rest], {segs, word, cur, nil}, [_ | _] = pending) do
    rest = rest |> List.to_string() |> skip_heredoc_bodies(pending) |> String.to_charlist()
    scan(rest, {[finish_word(cur, word) | segs], [], [], nil}, [])
  end

  defp scan([c | rest], state, pending), do: scan(rest, step(c, state), pending)

  # After `<<`: optional `-` (strip leading tabs from the delimiter line), then
  # the delimiter word, which may be quoted.
  defp read_heredoc_delimiter(chars) do
    {tabs?, chars} =
      case chars do
        [?- | rest] -> {true, rest}
        _ -> {false, chars}
      end

    chars = Enum.drop_while(chars, &(&1 in [?\s, ?\t]))

    {delim, rest} =
      case chars do
        [q | rest] when q in [?', ?"] -> Enum.split_while(rest, &(&1 != q))
        _ -> Enum.split_while(chars, &(&1 not in [?\s, ?\t, ?\n, ?;, ?&, ?|, ?(, ?), ?<, ?>]))
      end

    rest = if match?([q | _] when q in [?', ?"], rest), do: tl(rest), else: rest
    delim = delim |> List.delete(?\\) |> List.to_string()
    {{delim, tabs?}, rest}
  end

  defp skip_heredoc_bodies(text, pending) do
    Enum.reduce(pending, text, fn {delim, tabs?}, text ->
      lines = String.split(text, "\n")

      lines
      |> Enum.drop_while(fn line ->
        if(tabs?, do: String.trim_leading(line, "\t"), else: line) != delim
      end)
      |> Enum.drop(1)
      |> Enum.join("\n")
    end)
  end

  defp step(c, {segs, word, cur, nil}) when c in [?', ?"], do: {segs, word, cur, c}
  defp step(q, {segs, word, cur, q}), do: {segs, word, cur, nil}
  defp step(c, {segs, word, cur, q}) when q != nil, do: {segs, word, [c | cur], q}

  defp step(c, {segs, word, cur, nil}) when c in [?\s, ?\t] do
    {segs, finish_word(cur, word), [], nil}
  end

  defp step(c, {segs, word, cur, nil}) when c in [?;, ?&, ?|, ?(, ?), ?\n, ?`] do
    {[finish_word(cur, word) | segs], [], [], nil}
  end

  defp step(c, {segs, word, cur, nil}), do: {segs, word, [c | cur], nil}

  defp finish_word([], word), do: word
  defp finish_word(cur, word), do: [cur |> Enum.reverse() |> List.to_string() | word]

  # The program and its arguments, after env assignments and wrappers.
  defp command(words) do
    words =
      Enum.drop_while(words, fn w ->
        Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, w) or w == "$"
      end)

    skip_wrappers(words)
  end

  defp skip_wrappers([]), do: nil

  defp skip_wrappers([first | rest]) do
    exe = Path.basename(first)

    if exe in @wrappers do
      rest
      |> Enum.drop_while(
        &(String.starts_with?(&1, "-") or Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))
      )
      |> skip_wrappers()
    else
      {exe, rest}
    end
  end
end
