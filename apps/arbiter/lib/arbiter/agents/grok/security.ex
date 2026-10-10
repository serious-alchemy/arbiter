defmodule Arbiter.Agents.Grok.Security do
  @moduledoc """
  Translates a provider-agnostic `Arbiter.Agents.SecurityPolicy` into grok's
  concrete permission flags (bd-761q6h) — the grok analogue of
  `Arbiter.Agents.Claude.Security`, `Arbiter.Agents.Gemini.Security` and
  `Arbiter.Agents.Codex.Security`.

  ## Mechanism: argv, not a config file

  grok runs under `--always-approve`, and a `deny` rule beats it ("deny wins
  over every other rule", doc 22), so the baseline rides on the command line
  where it is visible in the spawn's argv and cannot be edited away by the
  worker (a `config.toml` in the worker's own `GROK_HOME` could):

    * `--deny <RULE>` per rule, in grok's grammar (`Bash(cmd:*)`, `Read(glob)`,
      `Edit(glob)`, `WebFetch(domain:host)`, `mcp__server__tool`, ...);
    * `--disallowed-tools a,b` to remove built-in tools outright, where a
      whole tool is the policy (the reviewer's write tools, `monitor` and the
      scheduler);
    * `--disable-web-search` when `sandbox.network` is false (it removes
      `web_search` and `web_fetch`);
    * `--no-subagents` when the operator denies `Agent` / `Task`.

  There is deliberately no `--sandbox` (see `docs/worker-security.md`): the
  OS-level guarantees (no write outside the worktree and the bound home, a
  read-only worktree for a reviewer) come from `Arbiter.Worker.Jail`, which
  wraps the whole spawn.

  ## Probed against grok 1.0.25 (no inference, zero quota)

    * A `--deny` rule whose tool prefix grok does not know is a **fatal parse
      error** (`--deny "Foo(bar)": unknown tool prefix: Foo`), and so is
      `--deny NotebookEdit` ("unsupported tool prefix"). An unmapped operator
      entry must therefore be dropped here, never passed through, or the
      worker would not start. See `unmapped/1`.
    * `--disallowed-tools` accepts any name without validating it, so a
      misspelt tool name silently removes nothing. The names used here are the
      ones grok printed in its own `system/init` tool list during the
      bd-7nbwix live probe (`run_terminal_command`, `write`, `search_replace`,
      `web_search`, `web_fetch`, `spawn_subagent`) or documents (`monitor`,
      `scheduler_*` in doc 20; `run_terminal_cmd` is the doc 14 spelling of
      the shell tool, listed alongside).
    * grok does **not** report permission denials (`permission_denials` is
      omitted from the `result` line), so a blocked call is visible only as
      the model's own tool-result text. The posture surface cannot count them.

  ## Honesty about enforcement level

  Like Claude's list these are permission-layer guards: they stop the agent's
  own tools in the common shapes. grok matches a `Bash` rule against every
  segment of a chained command, peels `env` / `timeout` / `nice` wrappers and
  looks inside a literal `bash -c '…'`, which is stricter than a plain prefix
  match, but a script written to a file and then run is not matched. Read and
  Edit denies also apply to the paths a shell command touches. These flags are
  also not live-probed for enforcement (a real run costs free-tier quota): the
  argv shape is test-covered and parse-checked against the real CLI, the
  enforcement is grok's documented behaviour.
  """

  alias Arbiter.Agents.SecurityPolicy

  # Tool classes grok accepts as a `--deny` prefix (doc 22, "Tool Names"),
  # plus the `mcp__server__tool` spelling it rewrites onto `MCPTool`.
  @rule_tools ~w(Bash Read Edit Write Grep Glob MCPTool WebFetch WebSearch)

  # Built-in tool names, as grok itself names them.
  @shell_tools ~w(run_terminal_command run_terminal_cmd)
  @write_tools ~w(write search_replace)
  @async_tools ~w(monitor scheduler_create scheduler_list scheduler_delete)

  @network_tools ~w(curl wget nc ncat telnet)
  @upload_tools ~w(curl wget http nc)

  @credential_dirs ~w(.ssh .claude .config .grok)

  @doc """
  The argv fragment for `policy`: every `--deny`, then `--disallowed-tools`,
  `--disable-web-search` and `--no-subagents` as the policy requires.

  Options: `:home` (the operator's home, for the absolute spellings of the
  credential dirs; defaults to the server user's) and `:grok_home` (the
  spawn's own `GROK_HOME`, which a worker must not be able to edit).
  """
  @spec argv(SecurityPolicy.t(), keyword()) :: [String.t()]
  def argv(%SecurityPolicy{} = policy, opts \\ []) do
    {_dropped, plan} = plan(policy, opts)

    Enum.flat_map(plan.deny, &["--deny", &1]) ++
      csv_flag("--disallowed-tools", plan.tools) ++
      flag("--disable-web-search", plan.no_web) ++
      flag("--no-subagents", plan.no_subagents)
  end

  @doc "The deduped `--deny` rules for `policy`."
  @spec deny_rules(SecurityPolicy.t(), keyword()) :: [String.t()]
  def deny_rules(%SecurityPolicy{} = policy, opts \\ []) do
    {_dropped, plan} = plan(policy, opts)
    plan.deny
  end

  @doc """
  The operator `permissions.deny` entries of `policy` that have no grok
  spelling and so are not enforced. Surfaced so a caller can log them: silently
  dropping a deny is exactly the gap this module exists to close.
  """
  @spec unmapped(SecurityPolicy.t()) :: [String.t()]
  def unmapped(%SecurityPolicy{} = policy) do
    {dropped, _plan} = plan(policy, [])
    dropped
  end

  # ---- internals ---------------------------------------------------------

  defp plan(%SecurityPolicy{permissions: perms, sandbox: sandbox}, opts) do
    empty = %{deny: [], tools: [], no_web: false, no_subagents: false}

    {dropped, plan} =
      Enum.reduce(perms.deny, {[], empty}, fn entry, {dropped, plan} ->
        case operator_entry(entry) do
          {:ok, update} -> {dropped, merge_plan(plan, update)}
          :ignore -> {dropped, plan}
          :drop -> {[entry | dropped], plan}
        end
      end)

    plan =
      Enum.reduce(perms.safe_defaults, plan, &merge_plan(&2, category(&1, opts)))
      |> merge_plan(network(sandbox))

    {Enum.reverse(dropped), %{plan | deny: Enum.uniq(plan.deny), tools: Enum.uniq(plan.tools)}}
  end

  defp merge_plan(a, b) do
    %{
      deny: a.deny ++ Map.get(b, :deny, []),
      tools: a.tools ++ Map.get(b, :tools, []),
      no_web: a.no_web or Map.get(b, :no_web, false),
      no_subagents: a.no_subagents or Map.get(b, :no_subagents, false)
    }
  end

  defp flag(name, true), do: [name]
  defp flag(_name, false), do: []

  defp csv_flag(_name, []), do: []
  defp csv_flag(name, tools), do: [name, Enum.join(tools, ",")]

  # Recursive force-deletes. grok splits a command on `&&`, `||`, `;`, `|` and
  # checks every segment, so a prefix rule covers a chain.
  defp category(:no_destructive_fs, _opts) do
    %{
      deny:
        for(
          cmd <- [
            "rm -rf",
            "rm -fr",
            "rm -r -f",
            "rm -f -r",
            "rm -Rf",
            "rm -fR",
            "rm --recursive --force",
            "rm --force --recursive",
            "sudo rm",
            "mkfs",
            "dd"
          ],
          do: "Bash(#{cmd}:*)"
        )
    }
  end

  # `--force-with-lease` is intentionally not denied (same as every adapter).
  defp category(:no_force_push, _opts) do
    %{
      deny:
        for(cmd <- ["git push --force", "git push -f", "git push --force="], do: "Bash(#{cmd}:*)")
    }
  end

  # A Read deny also binds `grep` and the files a shell command touches
  # (`cat .env`), so no separate `Bash(cat …)` rule is needed.
  defp category(:no_secret_reads, _opts) do
    %{
      deny:
        for(
          glob <- [
            "**/.env",
            "**/.env.*",
            "**/*.pem",
            "**/*_rsa",
            "**/id_rsa",
            "**/id_ed25519",
            "**/.ssh/**",
            "**/.aws/credentials",
            "**/.netrc",
            "**/.npmrc",
            "**/secrets/**"
          ],
          do: "Read(#{glob})"
        )
    }
  end

  # grok matches a `~`-prefixed tool path literally and never expands a `~/` in
  # a pattern, so a credential dir needs both spellings plus the absolute one.
  # The spawn's own GROK_HOME holds the worker's credential seam and is denied
  # by its absolute path. The OS-level guarantee is the jail, not these.
  defp category(:no_outside_writes, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home/0)

    dirs =
      Enum.flat_map(@credential_dirs, fn dir ->
        ["~/#{dir}/**"] ++ if(is_binary(home), do: ["#{home}/#{dir}/**"], else: [])
      end)

    own = if is_binary(opts[:grok_home]), do: ["#{opts[:grok_home]}/**"], else: []

    %{deny: for(path <- ["/etc/**", "/usr/**"] ++ dirs ++ own, do: "Edit(#{path})")}
  end

  # The MergeQueue owns PR creation (bd-53xrmi).
  defp category(:no_pr_create, _opts),
    do: %{deny: ["Bash(gh pr create:*)", "Bash(glab mr create:*)"]}

  # grok has the same two failure-prone tools Claude does: `monitor` and the
  # scheduler end a `-p` turn with the wakeup that can never arrive. Removed
  # outright rather than denied.
  defp category(:no_async_wait, _opts), do: %{tools: @async_tools}

  # grok's `domain:` pattern matches the host and every subdomain and takes no
  # wildcard, so `*.host` is not emitted. The Bash rules use grok's glob.
  defp category(:no_public_upload, _opts) do
    hosts = SecurityPolicy.public_upload_hosts()

    %{
      deny:
        Enum.map(hosts, &"WebFetch(domain:#{&1})") ++
          for(tool <- @upload_tools, host <- hosts, do: "Bash(#{tool} *#{host}*)")
    }
  end

  defp category(:no_gh_publish, _opts),
    do: %{deny: ["Bash(gh gist create:*)", "Bash(gh gist edit:*)", "Bash(gh issue comment:*)"]}

  defp category(:no_ci_watch, _opts),
    do: %{
      deny: [
        "Bash(gh run watch:*)",
        "Bash(gh run view:*)",
        "Bash(gh pr checks --watch:*)",
        "Bash(gh pr checks -w:*)"
      ]
    }

  # A category added to `SecurityPolicy` without a grok mapping must fail a
  # test (`security_test.exs`, "coverage guard"), not weaken the spawn quietly.
  defp category(_unknown, _opts), do: %{}

  defp network(%{network: false}) do
    %{
      deny: ["WebFetch", "WebSearch"] ++ for(tool <- @network_tools, do: "Bash(#{tool}:*)"),
      no_web: true
    }
  end

  defp network(_sandbox), do: %{}

  # An operator `deny` entry, in Claude's grammar. `:ignore` is a tool grok has
  # no analogue of (nothing to enforce, nothing wrong); `:drop` is an entry grok
  # would abort on or that cannot be expressed.
  defp operator_entry(entry) when is_binary(entry) do
    cond do
      entry in ["Edit", "Write"] -> {:ok, %{deny: [entry], tools: @write_tools}}
      entry == "NotebookEdit" -> :ignore
      entry == "Bash" -> {:ok, %{deny: ["Bash"], tools: @shell_tools}}
      entry in ["WebFetch", "WebSearch"] -> {:ok, %{deny: [entry], no_web: true}}
      entry in ["Agent", "Task"] -> {:ok, %{no_subagents: true}}
      entry in ["Monitor", "ScheduleWakeup"] -> {:ok, %{tools: @async_tools}}
      rule?(entry) -> {:ok, %{deny: [entry]}}
      true -> :drop
    end
  end

  defp operator_entry(_other), do: :drop

  defp rule?(entry) do
    not String.contains?(entry, ["\n", "\r", "\0"]) and
      (String.match?(entry, ~r/\A(?:#{Enum.join(@rule_tools, "|")})(?:\(.+\))?\z/s) or
         String.match?(entry, ~r/\Amcp__[A-Za-z0-9_*\-]+\z/))
  end
end
