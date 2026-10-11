defmodule ArbiterCli.Cmd.Batch do
  @moduledoc """
  arb batch [--file PATH] [--continue-on-error]

  Run many `arb` commands in one VM. Each `arb` invocation boots a full BEAM
  (~42 MB), so a shell loop over `arb` is slow and, backgrounded, can exhaust
  RAM. `arb batch` reads command lines from stdin (or `--file`), runs them
  sequentially over one HTTP client, and prints one JSON object per line:

      {"line": 2, "argv": ["ticket","show","bd-1"], "exit": 0, "output": {...}}
      {"line": 3, "argv": ["ticket","show","bd-9"], "exit": 4, "error": "..."}

  Input: one command per line, shell-like quoting (`'…'`, `"…"`, `\\x`), blank
  lines and `#` comments ignored, a leading `arb` optional. `--json` is implied
  (appended to each command). `output` is the command's parsed JSON stdout
  (or the raw text when it is not JSON); `error` is its failure message.

  Flags:
    --file PATH          read commands from PATH instead of stdin
    --continue-on-error  keep going after a failing line (default: stop)

  Stops at the first failure unless `--continue-on-error`; the exit status is
  non-zero when any line failed. Interactive or long-lived commands (`watch`,
  `worker log -f`, `server start|restart|deploy`, `restart`, `self-update`,
  `install`, `session`, `scheduler wait`, nested `batch`) are refused per line.

  `arb batch` is the CLI analogue of the bulk API/MCP verbs: API and MCP
  clients already issue many operations per connection, and the bulk endpoints
  take a list in one call. Coalescing runs of same-verb lines into one bulk
  call is not implemented yet (each line is its own request).

  `ARB_FANOUT_WARN` (default 16) and `ARB_FANOUT_MAX` (default 64) tune the
  guard that warns/refuses when too many `arb` VMs are already running;
  `--allow-fanout` or `ARB_ALLOW_FANOUT=1` overrides the refusal.
  """

  alias ArbiterCli.{ArgParser, Main, Output}
  alias ArbiterCli.Output.Halt

  @switches [file: :string, continue_on_error: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} = ArgParser.parse(argv, command: "arb batch", switches: @switches)
      if rest != [], do: Output.die("unexpected argument for arb batch: #{Enum.join(rest, " ")}")

      text = read_input(opts[:file])
      failed? = execute(text, Keyword.get(opts, :continue_on_error, false))
      if failed?, do: Output.halt(1)
    end
  end

  defp read_input(nil) do
    case IO.read(:stdio, :eof) do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp read_input(path) do
    case File.read(path) do
      {:ok, s} -> s
      {:error, reason} -> Output.die("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp execute(text, continue?) do
    inherited = inherited_state()
    ws_env = System.get_env("ARB_WORKSPACE")

    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.reduce_while(false, fn {line, n}, failed? ->
      case split_line(line) do
        :skip ->
          {:cont, failed?}

        parsed ->
          result = process(n, parsed, inherited)
          restore_env(ws_env)
          IO.puts(Jason.encode!(result))
          bad? = result.exit != 0

          if bad? and not continue?,
            do: {:halt, true},
            else: {:cont, failed? or bad?}
      end
    end)
  end

  defp process(n, {:error, msg}, _), do: %{line: n, argv: [], exit: 2, error: msg}

  defp process(n, {:ok, argv}, inherited) do
    case refusal(argv) do
      nil -> Map.merge(%{line: n, argv: argv}, run_line(argv, inherited))
      msg -> %{line: n, argv: argv, exit: 1, error: msg}
    end
  end

  # Per-process state the line's task must see: test stubs/overrides and the
  # `-w` flag marker. (The real process dictionary is not shared with a Task.)
  defp inherited_state do
    for {k, _} = kv <- Process.get(), inherited_key?(k), do: kv
  end

  defp inherited_key?(:arb_workspace_flag), do: true
  defp inherited_key?(k) when is_atom(k), do: String.starts_with?(Atom.to_string(k), "bd2_")
  defp inherited_key?(_), do: false

  defp restore_env(nil), do: System.delete_env("ARB_WORKSPACE")
  defp restore_env(v), do: System.put_env("ARB_WORKSPACE", v)

  defp run_line(argv, inherited) do
    Task.async(fn -> run_isolated(argv, inherited) end) |> Task.await(:infinity)
  end

  defp run_isolated(argv, inherited) do
    for {k, v} <- inherited, do: Process.put(k, v)
    Process.put(:bd2_halt_strategy, :raise)
    {:ok, sio} = StringIO.open("")
    Process.group_leader(self(), sio)
    Output.on_halt(fn _code, msg -> Process.put(:arb_batch_msg, msg) end)

    code =
      try do
        Main.run(with_json(argv))
        0
      rescue
        e in Halt -> e.code
        e -> fail(Exception.message(e))
      catch
        kind, reason -> fail(inspect({kind, reason}))
      end

    {_, out} = StringIO.contents(sio)
    frame(code, String.trim(out), Process.get(:arb_batch_msg))
  end

  defp fail(msg) do
    Process.put(:arb_batch_msg, msg)
    1
  end

  defp with_json(argv), do: if("--json" in argv, do: argv, else: argv ++ ["--json"])

  defp frame(0, out, _), do: %{exit: 0, output: decode(out)}
  defp frame(code, _out, msg), do: %{exit: code, error: msg || "exit #{code}"}

  defp decode(""), do: nil

  defp decode(out) do
    case Jason.decode(out) do
      {:ok, v} -> v
      _ -> out
    end
  end

  # ----- refusal -----

  # {leading words, why}: the first matching prefix refuses the line.
  @refused [
    {["watch"], "it never exits"},
    {["server", "start"], "it is long-lived"},
    {["server", "restart"], "it is long-lived"},
    {["server", "deploy"], "it is long-lived"},
    {["start"], "it is long-lived"},
    {["restart"], "it is long-lived"},
    {["self-update"], "it replaces the running binary"},
    {["upgrade"], "it replaces the running binary"},
    {["install"], "it modifies the host"},
    {["session"], "it is interactive"},
    {["scheduler", "wait"], "it blocks"},
    {["dashboard", "login"], "it is interactive"}
  ]

  @doc false
  @spec refusal([String.t()]) :: String.t() | nil
  def refusal(argv) do
    words = Enum.reject(argv, &String.starts_with?(&1, "-"))

    cond do
      match?(["batch" | _], words) -> "nested `arb batch` is not allowed"
      follow_log?(words, argv) -> not_allowed("logs -f", "it never exits")
      deploy_update?(words, argv) -> not_allowed("update (deploy)", "it is long-lived")
      true -> table_refusal(words)
    end
  end

  defp table_refusal(words) do
    Enum.find_value(@refused, fn {prefix, why} ->
      if Enum.take(words, length(prefix)) == prefix, do: not_allowed(Enum.join(prefix, " "), why)
    end)
  end

  defp follow_log?(words, argv) do
    follow? = Enum.any?(argv, &(&1 in ["-f", "--follow"]))
    follow? and (match?(["worker", "log" | _], words) or hd_in?(words, ["log", "logs"]))
  end

  defp hd_in?([h | _], list), do: h in list
  defp hd_in?(_, _), do: false

  # `arb update` with no id (or flags first) is the legacy deploy.
  defp deploy_update?(["update" | _], argv), do: deploy_update?(argv)
  defp deploy_update?(_, _), do: false

  defp deploy_update?(["update"]), do: true
  defp deploy_update?(["update", first | _]), do: String.starts_with?(first, "-")
  defp deploy_update?(_), do: false

  defp not_allowed(what, why), do: "`arb #{what}` is not allowed in arb batch: #{why}"

  # ----- line splitting -----

  @doc """
  Split one input line into argv with shell-like quoting. Returns `:skip` for
  blank/comment lines, `{:ok, argv}` (a leading `arb` dropped), or
  `{:error, reason}` for malformed quoting.
  """
  @spec split_line(String.t()) :: :skip | {:ok, [String.t()]} | {:error, String.t()}
  def split_line(line) do
    case tokenize(String.to_charlist(line), [], nil, []) do
      {:ok, []} -> :skip
      {:ok, ["arb" | []]} -> :skip
      {:ok, ["arb" | argv]} -> {:ok, argv}
      {:ok, argv} -> {:ok, argv}
      {:error, _} = err -> err
    end
  end

  # tokenize(chars, tokens_rev, current_token_rev | nil, _)
  defp tokenize([], acc, cur, _), do: {:ok, Enum.reverse(push(acc, cur))}

  defp tokenize([?\\], _acc, _cur, _), do: {:error, "trailing backslash"}
  defp tokenize([?\\, c | rest], acc, cur, q), do: tokenize(rest, acc, [c | cur || []], q)

  defp tokenize([?' | rest], acc, cur, q) do
    case Enum.split_while(rest, &(&1 != ?')) do
      {body, [?' | rest2]} -> tokenize(rest2, acc, Enum.reverse(body, cur || []), q)
      _ -> {:error, "unterminated quote"}
    end
  end

  defp tokenize([?" | rest], acc, cur, q), do: dquote(rest, acc, cur || [], q)

  defp tokenize([?# | _], acc, nil, _), do: {:ok, Enum.reverse(acc)}

  defp tokenize([c | rest], acc, cur, q) when c in [?\s, ?\t],
    do: tokenize(rest, push(acc, cur), nil, q)

  defp tokenize([c | rest], acc, cur, q), do: tokenize(rest, acc, [c | cur || []], q)

  defp dquote([?\\, c | rest], acc, cur, q) when c in [?", ?\\, ?$, ?`],
    do: dquote(rest, acc, [c | cur], q)

  defp dquote([?" | rest], acc, cur, q), do: tokenize(rest, acc, cur, q)
  defp dquote([c | rest], acc, cur, q), do: dquote(rest, acc, [c | cur], q)
  defp dquote([], _acc, _cur, _q), do: {:error, "unterminated quote"}

  defp push(acc, nil), do: acc
  defp push(acc, cur), do: [cur |> Enum.reverse() |> List.to_string() | acc]
end
