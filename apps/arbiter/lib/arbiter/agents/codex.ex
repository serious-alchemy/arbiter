defmodule Arbiter.Agents.Codex do
  @moduledoc """
  OpenAI Codex CLI adapter implementing `Arbiter.Agents.Agent`.

  Drives `codex exec --json` — Codex's non-interactive mode — inside the
  worker's worktree, streaming its JSONL event feed back through the shared
  `Arbiter.Worker.ClaudeSession` port pipeline (which routes codex events to
  `Arbiter.Agents.Codex.Stream`). The scaffolding this adapter completes was
  landed ahead of it: MCP config injection (`Arbiter.MCP.AgentConfig.Codex`,
  a `.codex/config.toml`), quota tracking (`Arbiter.Quota.Codex`), and the
  `.codex/` worktree-artifact handling all already exist; this module is the
  final dispatch seam that makes `agent.type = "codex"` runnable.

  ## Invocation

  `codex exec --json --skip-git-repo-check <sandbox> [-m model] -- <prompt>`,
  wrapped in `sh -c 'exec "$@" < /dev/null'` so the child's stdin is closed
  (mirrors the Claude/Gemini spawn shape). The prompt is a literal positional
  parameter — never interpolated into the command string — so there is no
  shell-injection surface. Oversize prompts (> `MAX_ARG_STRLEN`) are written to
  a temp file and piped via stdin with a `-` positional, mirroring the E2BIG
  fix in `Arbiter.Agents.Claude.build_argv/3`.

  ## Authentication

  Codex normally authenticates via the operator's ChatGPT login under
  `$CODEX_HOME` (`~/.codex/auth.json`). An API key is optional: when a
  workspace configures one (or `OPENAI_API_KEY` is ambient) the adapter exports
  `OPENAI_API_KEY`; otherwise the CLI uses the on-disk ChatGPT auth.

  ## Security posture

  The normalized `Arbiter.Agents.SecurityPolicy` maps to Codex's OS-level
  sandbox (`-s`) + approval bypass:

    * `:bypass` (the headless-safe default) →
      `--dangerously-bypass-approvals-and-sandbox` — full access, no approval
      prompt to freeze a headless run. Mirrors Claude's
      `--dangerously-skip-permissions` default.
    * `:auto`   → `-s workspace-write` (writes scoped to the worktree + its git common dir; network
      re-enabled so workers can `git push` / install packages).
    * `:strict` → `-s read-only`.

  Codex has no per-tool deny-list analogue to Claude's `--settings`
  (`safe_defaults` categories like `no_force_push` / `no_pr_create`), so
  `security_enforced?/0` returns `false` — the REST posture surface shows the
  gap rather than over-claiming enforcement. The sandbox it *does* apply is a
  real kernel jail (Landlock/seccomp on Linux), stronger than Claude's
  permission-level guard, but the category-level deny contract is not
  expressible, hence the honest `false`.

  ## Read-only reviewer (G12, bd-yoiv39)

  Codex ignores the reviewer's `Edit`/`Write` deny list, and `:bypass` hands it
  full access, so a Codex reviewer could write to the branch it is reviewing.
  `-s read-only` is not the answer: it also cuts the network, which the
  reviewer needs for `gh`. A review dispatch (the policy carries the
  `Write` deny that `Dispatch.review_security_policy/2` adds) is therefore
  wrapped in `Arbiter.Worker.Jail`'s bwrap jail with the worktree `--ro-bind`ed
  and the network shared, the same posture agy's reviewer gets. `$CODEX_HOME`
  stays writable (session rollouts, token refresh). Codex's own sandbox flags
  are untouched inside the jail; the kernel is the enforcement. A host that
  can't jail falls back to the unwrapped argv with a warning, as agy does
  outside `:strict`. The jail is keyed on the policy and worktree only, never
  on the model backend, so a Codex+Ollama / Responses-API reviewer is confined
  identically.
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Codex.Config
  alias Arbiter.Agents.Codex.ModelCatalog
  alias Arbiter.Agents.Codex.Stream
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.Sandbox
  alias Arbiter.Worker.StopReason

  require Logger

  @done_regex ~r/(?:\A|\n)[^\p{L}\p{N}\n]*arb done[^\p{L}\p{N}]*\z/u

  # See Arbiter.Agents.Claude for the MAX_ARG_STRLEN rationale. Codex reads its
  # prompt from stdin when the positional is `-`, so an oversize prompt goes to
  # a temp file piped in via the sh wrapper instead of into argv.
  @max_prompt_argv_bytes 131_072
  @prompt_tmp_prefix "arb_codex_prompt_"

  @impl true
  def provider, do: "codex"

  @impl true
  def security_enforced?, do: false

  @doc """
  `:none` (bd-1abj7u). Codex's `-s read-only` sandbox is real (see the
  moduledoc), but it isn't wired through this adapter's `:strict` mapping as
  a verified worktree-confinement guarantee the way Claude's permission
  layer or a bwrap jail are, so `:strict` dispatch to Codex is refused at
  the fail-closed gate (`Arbiter.Worker.Dispatch`) until it is.
  """
  @impl true
  def write_confinement(%SecurityPolicy{}), do: :none

  @impl true
  def done_sentinel, do: @done_regex

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    case resolve_executable() do
      {:ok, codex} ->
        with {:ok, model_flags} <- model_flag(opts) do
          policy = security_policy(opts)
          flags = sandbox_argv(policy, opts) ++ model_flags ++ effort_argv(opts) ++ mcp_argv(opts)

          # bd-btcdrf: refuse a backend with no implementation for every Codex
          # spawn (implementer, strict reviewer included), not just the ones
          # `maybe_jail_reviewer/3` wraps under bwrap.
          with {:ok, _sandbox} <- Sandbox.module(policy),
               {:ok, argv} <- build_argv(codex, prompt, flags) do
            maybe_jail_reviewer(argv, policy, opts)
          end
        end

      {:error, _} = err ->
        err
    end
  end

  # Base `codex exec` flags shared by every spawn: JSON event stream + tolerate
  # linked worktrees (whose `.git` is a file, which Codex's repo check can trip
  # on). Callers append sandbox + model flags, then the `--`/prompt tail.
  # `--ignore-user-config` (bd-4vgxwi, G5 stopgap) stops workers inheriting the
  # operator's `$CODEX_HOME/config.toml` (model, effort, profiles, personal MCP
  # servers); auth still comes from CODEX_HOME. Everything the worker needs
  # (model, effort, MCP, sandbox) is therefore passed explicitly below.
  @base_exec_flags ["--json", "--skip-git-repo-check", "--ignore-user-config"]
  @inline_prompt_script ~s(exec "$@" < /dev/null)
  @stdin_prompt_script ~s(f="$1"; shift; exec "$@" < "$f")

  @doc false
  def build_argv(codex, prompt, flags)
      when is_binary(codex) and is_binary(prompt) and is_list(flags) do
    head = [codex, "exec"] ++ @base_exec_flags ++ flags

    if byte_size(prompt) > @max_prompt_argv_bytes do
      case write_prompt_tmpfile(prompt) do
        {:ok, tmp} ->
          # `-` positional → codex reads the prompt from stdin (the temp file).
          {:ok, ["sh", "-c", @stdin_prompt_script, "sh", tmp] ++ head ++ ["--", "-"]}

        {:error, reason} ->
          {:error, {:prompt_tmpfile_failed, reason}}
      end
    else
      {:ok, ["sh", "-c", @inline_prompt_script, "sh"] ++ head ++ ["--", prompt]}
    end
  end

  defp write_prompt_tmpfile(prompt) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        @prompt_tmp_prefix <> Integer.to_string(System.unique_integer([:positive])) <> ".txt"
      )

    case File.write(tmp, prompt) do
      :ok -> {:ok, tmp}
      {:error, _} = err -> err
    end
  end

  # Extract the stdin-delivery temp file path from an argv built by
  # `build_argv/3`, or `nil` when this argv used inline delivery. Lets the
  # worker unlink the file once the spawned port exits.
  @doc false
  def prompt_tmpfile(argv) when is_list(argv) do
    {_jail, inner} = split_jail(argv)

    case Enum.at(inner, 4) do
      path when is_binary(path) -> if tmpfile_path?(path), do: path, else: nil
      _ -> nil
    end
  end

  # Splice `insert` (a list of argv elements, e.g. a swapped-in nudge/resume
  # prompt) right after the `--` flag in `argv`. Returns
  # `{:error, :no_print_slot}` when `argv` has no `--` flag at all.
  @doc false
  def splice_prompt(argv, insert) when is_list(argv) and is_list(insert) do
    {jail, inner} = split_jail(argv)

    case Enum.find_index(inner, &(&1 == "--")) do
      nil ->
        {:error, :no_print_slot}

      dash_idx ->
        {head, ["--" | _tail]} = Enum.split(inner, dash_idx)

        {head, new_tail} =
          case insert do
            ["--resume", session_id, prompt] ->
              # Replace "exec" with "exec", "resume" in head
              head =
                Enum.flat_map(head, fn
                  "exec" -> ["exec", "resume"]
                  other -> [other]
                end)

              {head, [session_id, prompt]}

            [nudge] ->
              {head, [nudge]}
          end

        # If it was using stdin delivery (i.e., temporary file positional at index 4),
        # we want to switch the script to inline_prompt_script and drop the temp file positional.
        {head, new_tail} =
          case Enum.at(head, 2) do
            @stdin_prompt_script ->
              head =
                head
                |> List.replace_at(2, @inline_prompt_script)
                |> List.delete_at(4)

              {head, new_tail}

            _ ->
              {head, new_tail}
          end

        {:ok, jail ++ head ++ ["--"] ++ new_tail}
    end
  end

  # A jailed argv (`maybe_jail_reviewer/3`) is `bwrap ... -- <sh wrapper>`; the
  # prompt helpers address the wrapper's own positions and its own `--`, so
  # peel the bwrap prefix off first. An unjailed argv has an empty prefix.
  defp split_jail(["sh" | _] = argv), do: {[], argv}

  defp split_jail(argv) do
    case Enum.find_index(argv, &(&1 == "--")) do
      nil -> {[], argv}
      idx -> Enum.split(argv, idx + 1)
    end
  end

  # A review dispatch is the one carrying the `Write` deny (see
  # `Dispatch.review_security_policy/2`); `strict` is already `-s read-only`.
  defp maybe_jail_reviewer(argv, %SecurityPolicy{permissions: %{mode: :strict}}, _opts),
    do: {:ok, argv}

  defp maybe_jail_reviewer(argv, %SecurityPolicy{permissions: permissions} = policy, opts) do
    worktree = Keyword.get(opts, :worktree) || Keyword.get(opts, :worktree_path)

    if "Write" in Map.get(permissions, :deny, []) and is_binary(worktree) do
      jail_reviewer(argv, policy, worktree)
    else
      {:ok, argv}
    end
  end

  defp jail_reviewer(argv, policy, worktree) do
    # bd-btcdrf: a backend with no implementation refuses the spawn; only a
    # host that cannot run the requested backend degrades to unconfined.
    with {:ok, _sandbox} <- Sandbox.module(policy) do
      result =
        with :ok <- Sandbox.status(policy) do
          Sandbox.wrap(policy, argv,
            worktree: worktree,
            worktree_readonly: true,
            writable_paths: [ModelCatalog.codex_home() | prompt_tmpfiles(argv)]
          )
        end

      case result do
        {:ok, jailed} ->
          {:ok, jailed}

        {:error, reason} ->
          Logger.warning(
            "codex reviewer write jail unavailable (#{inspect(reason)}); running unconfined"
          )

          {:ok, argv}
      end
    end
  end

  # An oversize prompt lives in a host /tmp file, and the jail's /tmp is a
  # private tmpfs, so it has to be bound through.
  defp prompt_tmpfiles(argv), do: List.wrap(prompt_tmpfile(argv))

  defp tmpfile_path?(path), do: Path.basename(path) |> String.starts_with?(@prompt_tmp_prefix)

  @impl true
  def auth_probe(opts \\ []) do
    # Zero-quota auth probe (bd-2r42bq):
    # If an API key is configured (alternative backend: direct OpenAI API, Ollama,
    # or Responses-API backend), ChatGPT auth.json is not used; fall back to
    # the argv probe (`auth_probe_argv/1`) so the key/backend is validated. That
    # turn is billed to the key's backend, not the ChatGPT 30-day budget.
    # Otherwise, probe via Arbiter.Quota.Codex.probe_auth/1 (wham/usage GET) which
    # checks token validity without burning model turns or 30-day budget quota.
    case resolve_executable() do
      {:ok, _path} ->
        if api_key_configured?(opts), do: :skipped, else: probe_chatgpt_usage(opts)

      {:error, {:executable_not_found, exec}} ->
        {:error,
         %StopReason{
           category: :crashed,
           summary: "agent CLI not found on PATH (#{exec})",
           remediation: "Install / fix the agent CLI on the host before dispatching."
         }}
    end
  end

  defp api_key_configured?(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> true
      _ -> Config.api_key_configured?()
    end
  end

  defp probe_chatgpt_usage(opts) do
    case Arbiter.Quota.Codex.probe_auth(opts) do
      {:ok, 200, _body} ->
        :ok

      # A 401 only means the access token was stale when read: nothing in
      # Arbiter refreshes it, the `codex` CLI does that itself. Marking Codex
      # expired here would refuse every dispatch, so no CLI would ever run to
      # refresh it. Defer to the argv probe (which refreshes the token, and only
      # spends a turn when the token really is stale).
      {:ok, 401, _body} ->
        :skipped

      # No ChatGPT login on disk: the CLI may be pointed at a keyless or
      # non-OpenAI backend (Ollama, custom `model_provider`/`base_url`), which
      # never reads auth.json. Defer to the argv probe so the CLI itself
      # decides; a genuinely unauthenticated CLI still fails there.
      {:error, reason} when reason in [:no_access_token, :enoent] ->
        :skipped

      {:ok, status, _body} ->
        {:warn,
         %StopReason{
           category: :preflight_timeout,
           summary: "Codex usage probe returned HTTP #{status}",
           remediation: "Check ChatGPT API status."
         }}

      {:error, reason} ->
        {:warn,
         %StopReason{
           category: :preflight_timeout,
           summary: "Codex usage probe could not reach endpoint: #{inspect(reason)}",
           remediation: "Check network connectivity."
         }}
    end
  end

  @impl true
  def auth_probe_argv(_opts \\ []) do
    # Cheapest auth check: a one-word `codex exec` round-trip under a read-only
    # sandbox. A missing/expired ChatGPT login or bad key exits non-zero, which
    # Arbiter.Worker.StopReason classifies.
    case resolve_argv_probe_executable() do
      {:ok, codex} ->
        argv =
          ["sh", "-c", @inline_prompt_script, "sh", codex, "exec"] ++
            @base_exec_flags ++ ["-s", "read-only", "--", "ping"]

        {:ok, argv}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    env = []

    # Set OPENAI_API_KEY for auth
    env =
      case Keyword.get(opts, :api_key) || Config.resolve_api_key() do
        key when is_binary(key) and key != "" -> [{"OPENAI_API_KEY", key} | env]
        _ -> env
      end

    # Set ARBITER_MCP_TOKEN for the MCP server bearer_token_env_var (if using env-var mode).
    # The token is minted as a worker scope token in dispatch and passed via :arb_token.
    env =
      case Keyword.get(opts, :arb_token) do
        token when is_binary(token) and token != "" -> [{"ARBITER_MCP_TOKEN", token} | env]
        _ -> env
      end

    Enum.reverse(env)
  end

  @impl true
  def async_tool_instruction do
    # A reviewer is forbidden from pushing code, so "commit before verifying"
    # is meaningless guidance on that surface — same as Claude/Gemini's /0.
    async_tool_instruction("your VERDICT or `arb done`", nil, commit_first: false)
  end

  # The `coda` and `:commit_first` guidance is provider-agnostic — "commit
  # before you verify" is about not losing work to a killed session, which has
  # nothing to do with which CLI is running. Before this block was routed
  # through the adapter, codex workers received it via the hard-coded Claude
  # text; dropping it here would have quietly regressed a whole provider's
  # prompt while fixing another's.
  @impl true
  def async_tool_instruction(completion_signal, coda \\ nil, opts \\ []) do
    commit_line =
      if Keyword.get(opts, :commit_first, true) do
        "    COMMIT correct work BEFORE running any long verification — verification\n" <>
          "    confirms work; it must never be the thing that loses it.\n"
      else
        ""
      end

    tail =
      case coda do
        nil -> "."
        extra -> " —\n    #{String.replace(extra, "\n", "\n    ")}."
      end

    "*** TOOLS: Run tools and wait inline for each result before proceeding.\n" <>
      "    Codex `exec` executes commands synchronously; do not attempt to background\n" <>
      "    long-running commands, and do not print #{completion_signal} until\n" <>
      "    every command you started has finished and you have read its output" <>
      tail <> "\n" <> commit_line
  end

  @impl true
  def init_session(opts \\ []) do
    %{
      line_buf: "",
      output_lines: [],
      usage: %{},
      activity: nil,
      activity_at: nil,
      model: Keyword.get(opts, :model)
    }
  end

  @impl true
  def parse_line(session, line) when is_binary(line) do
    case decode_event(line) do
      {:ok, event} ->
        session = absorb_usage(session, event)
        tuples = Stream.format_event(event)
        session = Enum.reduce(tuples, session, fn {text, _arm?}, acc -> accumulate(acc, text) end)
        {tuples, session}

      :error ->
        {[{line, true}], accumulate(session, line)}
    end
  end

  @impl true
  def usage_attrs(session) do
    Map.get(session, :usage, %{}) |> Map.put(:provider, provider())
  end

  @impl true
  def resolved_model(opts \\ []) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        case Keyword.get(opts, :model_tier) do
          tier when is_binary(tier) and tier != "" ->
            Config.model_for_tier(tier) || Config.active_model()

          _ ->
            Config.active_model()
        end
    end
  end

  # ---- Internals ---------------------------------------------------------

  defp accumulate(session, text),
    do: Map.update(session, :output_lines, [text], &[text | &1])

  defp absorb_usage(session, event) do
    fields = Stream.usage_fields(event, Map.get(session, :model))

    usage =
      Enum.reduce(fields, Map.get(session, :usage, %{}), fn {k, v}, acc ->
        if is_nil(v), do: acc, else: Map.put(acc, k, v)
      end)

    Map.put(session, :usage, usage)
  end

  # Decode a JSONL line into a normalized codex event (top-level `"type"`).
  # Handles both the flat payload shape and an `{id, msg}` envelope some codex
  # builds wrap events in.
  defp decode_event(line) do
    with "{" <> _ <- String.trim_leading(line),
         {:ok, obj} when is_map(obj) <- Jason.decode(line),
         {:ok, event} <- normalize_event(obj) do
      {:ok, event}
    else
      _ -> :error
    end
  end

  defp normalize_event(%{"type" => "event_msg", "payload" => %{"type" => _} = p}), do: {:ok, p}
  defp normalize_event(%{"msg" => %{"type" => _} = msg}), do: {:ok, msg}
  defp normalize_event(%{"type" => _} = e), do: {:ok, e}
  defp normalize_event(_), do: :error

  # :bypass — no sandbox, no approval prompt (headless-safe default).
  defp sandbox_argv(%SecurityPolicy{permissions: %{mode: :bypass}}, _opts),
    do: ["--dangerously-bypass-approvals-and-sandbox"]

  # :strict — read-only sandbox; the agent can inspect but not mutate.
  defp sandbox_argv(%SecurityPolicy{permissions: %{mode: :strict}}, _opts),
    do: sandbox_mode_config("read-only")

  # :auto — workspace-write; re-enable network so the worker can push / install.
  defp sandbox_argv(%SecurityPolicy{permissions: %{mode: :auto}} = policy, opts) do
    sandbox_mode_config("workspace-write") ++
      network_config(policy) ++ writable_roots_config(opts)
  end

  defp sandbox_argv(_policy, _opts), do: ["--dangerously-bypass-approvals-and-sandbox"]

  # `-s` is rejected by `codex exec resume` ("unexpected argument '-s'"), but
  # `-c` is accepted by both `exec` and `exec resume`, so express the sandbox
  # as a config override to keep resume working under :strict/:auto.
  defp sandbox_mode_config(mode), do: ["-c", "sandbox_mode=#{inspect(mode)}"]

  # Codex only loads `<worktree>/.codex/config.toml` when the project is trusted
  # in `$CODEX_HOME/config.toml`, so MCP was silently absent in untrusted repos.
  # `-c` overrides apply regardless of trust. The bearer stays off argv: it is
  # read from `ARBITER_MCP_TOKEN` (see `spawn_env/1`).
  @doc false
  def mcp_argv(opts) do
    case Keyword.get(opts, :arb_token) do
      token when is_binary(token) and token != "" ->
        if Arbiter.MCP.inject_config?() do
          name = Arbiter.MCP.server_name()

          [
            "-c",
            "mcp_servers.#{name}.url=#{inspect(Arbiter.MCP.server_url())}",
            "-c",
            "mcp_servers.#{name}.bearer_token_env_var=\"ARBITER_MCP_TOKEN\""
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  # Reasoning effort is set explicitly because the operator's config no longer
  # supplies it; with no `:thinking` opt the Codex default applies.
  @doc false
  def effort_argv(opts) do
    level =
      case Keyword.get(opts, :thinking) do
        l when is_atom(l) and not is_nil(l) -> Atom.to_string(l)
        l -> l
      end

    case level do
      l when l in ["none", "minimal", "low", "medium", "high", "xhigh"] ->
        ["-c", "model_reasoning_effort=#{inspect(l)}"]

      # Routing's "max" has no Codex equivalent; clamp to the highest level.
      "max" ->
        ["-c", "model_reasoning_effort=\"xhigh\""]

      _ ->
        []
    end
  end

  # workspace-write disables network by default; opt back in when the policy's
  # sandbox allows it (workers need it for git push / package installs).
  defp network_config(%SecurityPolicy{sandbox: %{network: true}}),
    do: ["-c", "sandbox_workspace_write.network_access=true"]

  defp network_config(_policy), do: []

  # In a linked worktree `.git` is a file pointing into the main repo's
  # `.git/worktrees/<wt>`, which lies outside the workspace-write root, so
  # `git add`/`commit` fail with "Read-only file system" on index.lock. Add the
  # git common dir as a writable root. Skipped when the worktree is unknown or
  # isn't a git checkout (nothing to add).
  defp writable_roots_config(opts) do
    case git_common_dir(Keyword.get(opts, :worktree_path)) do
      nil -> []
      dir -> ["-c", "sandbox_workspace_write.writable_roots=[#{inspect(dir)}]"]
    end
  end

  defp git_common_dir(path) when is_binary(path) and path != "" do
    if File.dir?(path) do
      case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
             cd: path,
             stderr_to_stdout: true
           ) do
        {out, 0} -> out |> String.trim() |> non_empty()
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp git_common_dir(_), do: nil

  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  # The resolved SecurityPolicy for this spawn; falls back to the install-wide
  # hardened default so a bare adapter call is still safe.
  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  # Tier-map models are already validated (and substituted) by
  # `Config.model_for_tier/1`. A model the caller named explicitly is not
  # silently swapped: one the account provably cannot call fails the dispatch
  # here, before a doomed spawn.
  defp model_flag(opts) do
    case resolved_model(opts) do
      nil ->
        {:ok, []}

      model when is_binary(model) ->
        case Config.validate_model(model) do
          :ok -> {:ok, ["-m", model]}
          {:error, why} -> {:error, {:model_unavailable, model, why}}
        end
    end
  end

  # The argv probe is a real model turn. Config can disable it (test env does)
  # so an unstubbed Preflight.check(Codex, ...) fails closed instead of exec'ing
  # the operator's real `codex` on their quota.
  defp resolve_argv_probe_executable do
    if Application.get_env(:arbiter, :codex_argv_probe, true) do
      resolve_executable()
    else
      {:error, {:executable_not_found, "codex (argv probe disabled by :codex_argv_probe)"}}
    end
  end

  defp resolve_executable do
    case System.find_executable("codex") do
      nil -> {:error, {:executable_not_found, "codex"}}
      path -> {:ok, path}
    end
  end
end
