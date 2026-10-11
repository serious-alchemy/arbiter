defmodule Arbiter.Agents.Qwen.Security do
  @moduledoc """
  Translates a provider-agnostic `Arbiter.Agents.SecurityPolicy` into qwen's
  permission settings (bd-az8ycn, Q5 of bd-3km00p), the qwen analogue of
  `Arbiter.Agents.Grok.Security`.

  ## The jail is the boundary, this is the steer

  A headless qwen needs `--yolo` (nobody can answer an approval prompt), and a
  qwen deny rule matches the command string qwen is about to run: it does not
  see through `bash -c '…'`, `sh -c`, `eval`, a script the model just wrote or a
  `python -c` one-liner (`docs/worker-security.md`). So every rule here is
  best effort, a way of steering a model away from the common shapes; the
  guarantees come from `Arbiter.Worker.Jail` (read-only root, writable worktree
  and per-worker `HOME`, hidden credential paths, pid namespace, no network but
  the egress proxy and the tunnels). `coverage/0` records, per safe-default
  category, which layer carries it.

  ## Mechanism: the read-only system settings

  qwen has no `--deny` flag. The rules ride in the system settings file
  (`Arbiter.Agents.Qwen.ConfigDir`), which outranks user and workspace settings
  and which the jail binds read-only, so neither the worker nor a repo's
  `.qwen/settings.json` can loosen them:

    * `permissions.deny`, in qwen's rule grammar (`Bash(cmd *)`, `Read(glob)`,
      `Edit(glob)`, `WebFetch(domain:host)`). A shell rule is a space-star
      prefix: Claude's `Bash(cmd:*)` is rewritten to it;
    * `tools.exclude`, qwen's tool names (`run_shell_command`, `edit`,
      `write_file`, `web_fetch`, `web_search`, `task`), to remove a tool outright
      where the whole tool is the policy: a reviewer's write tools, or
      `network: false`.

  The rule grammar and the setting keys are qwen's documented ones; they have
  not been run against a live qwen (none was available, `docs/qwen-test-harness.md`).
  The shapes are test-covered here and must be re-confirmed on the first host
  with qwen.

  Operator `permissions.deny` entries with no qwen spelling cannot be expressed;
  they are dropped rather than passed through (an invalid rule could stop qwen
  from starting) and reported by `unmapped/1`.
  """

  alias Arbiter.Agents.SecurityPolicy

  @rule_tools ~w(Bash Read Edit Grep Glob WebFetch WebSearch)

  # qwen's own tool names.
  @shell_tools ["run_shell_command"]
  @edit_tools ["edit"]
  @write_tools ["write_file"]
  @web_tools ["web_fetch", "web_search"]
  @agent_tools ["task"]

  @network_commands ~w(curl wget nc ncat telnet)
  @upload_commands ~w(curl wget http nc)

  @credential_dirs ~w(.ssh .claude .config .qwen .grok)

  # Which layer carries each safe-default category. `:deny` and `:tools` are
  # qwen's permission layer; `:jail` is `Arbiter.Worker.Jail` (and the egress
  # proxy), the only layer that holds against a wrapped command.
  @coverage %{
    no_destructive_fs: [:deny, :jail],
    no_force_push: [:deny],
    no_secret_reads: [:deny, :jail],
    no_outside_writes: [:deny, :jail],
    no_pr_create: [:deny],
    # qwen has no Monitor / scheduler tool to remove. A background process the
    # model starts and then abandons dies with the jail's pid namespace
    # (`--unshare-pid --die-with-parent`) when the headless run ends.
    no_async_wait: [:jail],
    no_public_upload: [:deny, :jail],
    no_gh_publish: [:deny],
    no_ci_watch: [:deny]
  }

  @doc """
  The layers that carry each safe-default category: `%{category => [:deny |
  :tools | :jail]}`. A test holds this against
  `SecurityPolicy.safe_default_categories/0`, so a new category cannot ship
  without a qwen decision.
  """
  @spec coverage() :: %{atom() => [:deny | :tools | :jail]}
  def coverage, do: @coverage

  @doc """
  The system-settings fragment for `policy`: `permissions.deny`, and
  `tools.exclude` when a tool is removed.

  Options: see `deny_rules/2`.
  """
  @spec settings(SecurityPolicy.t(), keyword()) :: map()
  def settings(%SecurityPolicy{} = policy, opts \\ []) do
    {_dropped, plan} = plan(policy, opts)
    base = %{"permissions" => %{"deny" => plan.deny}}

    case plan.tools do
      [] -> base
      tools -> Map.put(base, "tools", %{"exclude" => tools})
    end
  end

  @doc """
  The deduped `permissions.deny` rules for `policy`.

  Options: `:home` (the operator's home, for the absolute spellings of the
  credential dirs; defaults to the server user's) and `:qwen_home` (the spawn's
  own `QWEN_HOME`, which a worker must not be able to edit).
  """
  @spec deny_rules(SecurityPolicy.t(), keyword()) :: [String.t()]
  def deny_rules(%SecurityPolicy{} = policy, opts \\ []) do
    {_dropped, plan} = plan(policy, opts)
    plan.deny
  end

  @doc "The qwen tool names `policy` removes (`tools.exclude`)."
  @spec exclude_tools(SecurityPolicy.t()) :: [String.t()]
  def exclude_tools(%SecurityPolicy{} = policy) do
    {_dropped, plan} = plan(policy, [])
    plan.tools
  end

  @doc """
  The operator `permissions.deny` entries of `policy` that have no qwen
  spelling and so are not enforced. Surfaced so a caller can log them: silently
  dropping a deny is the gap this module exists to close.
  """
  @spec unmapped(SecurityPolicy.t()) :: [String.t()]
  def unmapped(%SecurityPolicy{} = policy) do
    {dropped, _plan} = plan(policy, [])
    dropped
  end

  # ---- internals ---------------------------------------------------------

  defp plan(%SecurityPolicy{permissions: perms, sandbox: sandbox}, opts) do
    {dropped, plan} =
      Enum.reduce(perms.deny, {[], %{deny: [], tools: []}}, fn entry, {dropped, plan} ->
        case operator_entry(entry) do
          {:ok, update} -> {dropped, merge(plan, update)}
          :ignore -> {dropped, plan}
          :drop -> {[entry | dropped], plan}
        end
      end)

    plan =
      perms.safe_defaults
      |> Enum.reduce(plan, &merge(&2, category(&1, opts)))
      |> merge(network(sandbox))

    {Enum.reverse(dropped), %{deny: Enum.uniq(plan.deny), tools: Enum.uniq(plan.tools)}}
  end

  defp merge(a, b) do
    %{deny: a.deny ++ Map.get(b, :deny, []), tools: a.tools ++ Map.get(b, :tools, [])}
  end

  defp category(:no_destructive_fs, _opts) do
    cmds = [
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
    ]

    %{deny: Enum.map(cmds, &bash/1)}
  end

  # `--force-with-lease` is intentionally not denied (same as every adapter).
  defp category(:no_force_push, _opts),
    do: %{deny: Enum.map(["git push --force", "git push -f"], &bash/1)}

  defp category(:no_secret_reads, _opts) do
    globs = [
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
    ]

    %{deny: Enum.map(globs, &"Read(#{&1})")}
  end

  # A credential dir needs the `~` spelling and the absolute one: a rule is
  # matched against the path as the tool was given it. The spawn's own
  # QWEN_HOME holds the worker's settings and session files and is denied by
  # its absolute path. The OS-level guarantee is the jail, not these.
  defp category(:no_outside_writes, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home/0)

    dirs =
      Enum.flat_map(@credential_dirs, fn dir ->
        ["~/#{dir}/**"] ++ if(is_binary(home), do: ["#{home}/#{dir}/**"], else: [])
      end)

    own = if is_binary(opts[:qwen_home]), do: ["#{opts[:qwen_home]}/**"], else: []

    %{deny: Enum.map(["/etc/**", "/usr/**"] ++ dirs ++ own, &"Edit(#{&1})")}
  end

  # The MergeQueue owns PR creation (bd-53xrmi).
  defp category(:no_pr_create, _opts),
    do: %{deny: Enum.map(["gh pr create", "glab mr create"], &bash/1)}

  # No qwen tool to remove: the jail carries it (see `@coverage`).
  defp category(:no_async_wait, _opts), do: %{}

  defp category(:no_public_upload, _opts) do
    hosts = SecurityPolicy.public_upload_hosts()

    %{
      deny:
        Enum.map(hosts, &"WebFetch(domain:#{&1})") ++
          for(tool <- @upload_commands, host <- hosts, do: "Bash(#{tool} *#{host}*)")
    }
  end

  defp category(:no_gh_publish, _opts),
    do: %{deny: Enum.map(["gh gist create", "gh gist edit", "gh issue comment"], &bash/1)}

  defp category(:no_ci_watch, _opts),
    do: %{deny: Enum.map(["gh run watch", "gh run view", "gh pr checks"], &bash/1)}

  # A category added to `SecurityPolicy` without a qwen mapping must fail a
  # test (`security_test.exs`, "coverage guard"), not weaken the spawn quietly.
  defp category(_unknown, _opts), do: %{}

  defp network(%{network: false}) do
    %{
      deny: ["WebFetch", "WebSearch"] ++ Enum.map(@network_commands, &bash/1),
      tools: @web_tools
    }
  end

  defp network(_sandbox), do: %{}

  defp bash(command), do: "Bash(#{command} *)"

  # An operator `deny` entry, in Claude's grammar. `:ignore` is a tool qwen has
  # no analogue of (nothing to enforce); `:drop` cannot be expressed.
  defp operator_entry(entry) when is_binary(entry) do
    cond do
      entry == "Edit" -> {:ok, %{deny: ["Edit"], tools: @edit_tools}}
      entry == "Write" -> {:ok, %{deny: ["Edit"], tools: @write_tools}}
      entry in ["NotebookEdit", "Monitor", "ScheduleWakeup"] -> :ignore
      entry == "Bash" -> {:ok, %{deny: ["Bash"], tools: @shell_tools}}
      entry in ["WebFetch", "WebSearch"] -> {:ok, %{deny: [entry], tools: @web_tools}}
      entry in ["Agent", "Task"] -> {:ok, %{tools: @agent_tools}}
      true -> rule(entry)
    end
  end

  defp operator_entry(_other), do: :drop

  defp rule(entry) do
    cond do
      String.contains?(entry, ["\n", "\r", "\0"]) ->
        :drop

      String.match?(entry, ~r/\Amcp__[A-Za-z0-9_*\-]+\z/) ->
        {:ok, %{deny: [entry]}}

      String.match?(entry, ~r/\AWrite\(.+\)\z/s) ->
        {:ok, %{deny: [String.replace_prefix(entry, "Write(", "Edit(")]}}

      String.match?(entry, ~r/\A(?:#{Enum.join(@rule_tools, "|")})\(.+\)\z/s) ->
        {:ok, %{deny: [prefix_spelling(entry)]}}

      true ->
        :drop
    end
  end

  # Claude's `Bash(cmd:*)` prefix spelling is qwen's `Bash(cmd *)`.
  defp prefix_spelling("Bash(" <> _ = entry), do: String.replace(entry, ~r/:\*\)\z/, " *)")
  defp prefix_spelling(entry), do: entry
end
