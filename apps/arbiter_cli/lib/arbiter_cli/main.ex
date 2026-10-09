defmodule ArbiterCli.Main do
  @moduledoc """
  Escript entry point. The CLI uses an `arb <resource> <verb>` grammar:
  the first token names a resource (or a flat meta command), the second the
  action on it.

  ## Resources

      arb ticket list     [--state ...] [--type ...] [--priority ...] [--labels ...] [--tracker]
      arb ticket show     <id>
      arb ticket create   <title> [--description ...] [--priority ...] [--type ...]
                                  [--acceptance a | --acceptance-file PATH]
                                  [--notes t] [--qa-notes t] [--deployment-notes t]
                                  [--deps id1,id2] [--labels a,b] [--parent <parent-id>]
                                  [--auto-close] [--tracker-ref R] [--tracker-type T]
                                  [--tracker-context-type T] [--tracker-context-ref R]
                                  [--require-provider p | --exclude-provider p]
      arb ticket update   <id> [--title ...] [--priority N] [--difficulty N] [--type T]
                                  [--description d] [--notes t | --append-notes t]
                                  [--acceptance a | --acceptance-file PATH]
                                  [--qa-notes text] [--deployment-notes text]
                                  [--pr-body text] [--pr-ref R] [--target-branch B]
                                  [--tracker-ref R] [--tracker-type T]
                                  [--tracker-context-type T] [--tracker-context-ref R]
                                  [--auto-close | --no-auto-close]
                                  [--require-provider p | --exclude-provider p |
                                   --clear-provider-constraint]
                                  [--permission p] [--remove-permission p]
                                  ("" clears a field; `arb ticket update --help` lists all)
      arb ticket close    <id> [--reason ...] [--no-upstream]
      arb ticket reopen   <id>
      arb ticket verify   <id> --observed "<evidence>" | --failed "<evidence>"
                                  record the post-merge restart-and-observe result
                                  for a ticket in state verifying
      arb ticket resolve  <id> --accept-as-is|--amend|--send-back|--reject "<reasoning>"
                                  [--gate review_gate|notes_gate|commit_gate] [--round N]
                                  [--fix-round-attempt N]
                                  record your answer to a gate escalation — what the
                                  coordinator decided and why (bd-4qjl0q)
      arb ticket claim    <ref> [--force] [--repo <repo>]
      arb ticket sync     [--dry]
      arb ticket ready
      arb ticket dispatch <id> [<repo>] [--provider claude|gemini|codex|grok | --no-agent]
                          [--model <name>] [--force] [--over-cap]
                          [--force-quota [--force-quota-reason <why>]]
                                  (== arb dispatch; --with-claude/--with-gemini are deprecated aliases)

                                  `arb issue …` is a deprecated alias for `arb ticket …`:
                                  it still runs, and prints a one-line note on stderr.

      arb epic floor      <id> P1|P2|P3|none
                                  set or clear an epic's priority floor: its children
                                  are scheduled as min(own priority, floor). Operator
                                  and coordinator only; P0 is never a floor.

      arb worker list
      arb worker show     <task-id>
      arb worker runs     [<task-id>] [--kind K] [--state S] [--outcome O] [--before ISO] [--limit N]
      arb worker runs     --run <run-id> | <task-id> --corpus
      arb worker log      <task-id> [--run <run-id>] [--tail N]
      arb worker prompt   <task-id> [--run <run-id>]
      arb worker stop     <task-id>
      arb worker resume   <task-id> [<repo> | --repo <repo>] [--model <name>] [--force]
                          [--force-quota [--force-quota-reason <why>]] [--mode session|briefing]
      arb worker review   <task-id> [--repo <repo>] [--model <name>] [--force] [--automation <mode>]
                          [--force-quota [--force-quota-reason <why>]]
      arb queue retry-auto-resolve <task-id>
      arb queue restart-watchdog   <task-id>
      arb queue rerun-ci           <task-id> [--mode <mode>] [--workflow <w>] [--input k=v]
      arb queue mark-ci-external   <task-id> <note...>
      arb review          <task-id> | --pr <url|number> [--report-only] [--force] [--follow-up|--no-follow-up]
                          [--scope diff|repo] [--automation <mode>] [--repo <repo>]
                          [--tracker-context-ref <ref> [--tracker-context-type <t>]]
      arb review list     [--status running|completed|failed] [--since <ts>] [--limit <n>]
      arb review show     <record-id>              proposed comments, numbered
      arb review transcript <record-id> [--tail <n>] [--no-prompt]
      arb review rounds   <task-id> [--limit <n>]  ReviewGate rounds + outcome
      arb review greenlight <record-id> [--select all|none|0,2] [--no-post-verdict]
      arb review resolve  <task-id> --amend "<reasoning>"   (== arb ticket resolve)

      arb repo list
      arb repo show       <name>

      arb skill list
      arb skill show      <id|name>
      arb skill create    <name> [--body ... | --body-file PATH | -] [--metadata JSON]
      arb skill update    <id|name> [--name NEW] [--body ... | --body-file PATH | -]
                                  [--metadata JSON]
      arb skill delete    <id|name> [--force]

      arb account list                              [--provider p] [--include-merged] [--include-deleted]
      arb account show    <ref>                      (uuid, provider:slug, or bare slug)
      arb account create  <provider> <slug>          [--label ...] [--plan ...] [--max-concurrent N]
                          [--disable] [--provider-account-ref ID] [--provider-org-ref ID] [quota flags]
      arb account set     <ref>                      [--label ...] [--plan ...] [--enable|--disable]
                          [--max-concurrent N|none] [--threshold-mode flat|paced] [--throttle-threshold F]
                          [--weekly-threshold F] [--paced-floor F] [--weekly-paced-floor F]
                          [--weekly-warning-policy ignore|hold] [--window-seconds LABEL=SECONDS]
                          [--pace-exempt-priority 0..4|none] [--pace-exempt-threshold F]
                          [--weekly-pace-exempt-threshold F] [--unset QUOTA_KEY]
      arb account attach  <workspace> <provider> <ref> [--share N]
      arb account detach  <workspace> <ref>
      arb account rotate  <ref> --kind k --env-var V (--secret S | --secret-file PATH | -)
      arb account merge   <from-ref> --into <into-ref>

      arb dep add         <from> <type> <to>
      arb dep remove      <from> <to>

      arb config get      [dotted.key] [--workspace W] [--json]
      arb config set      <dotted.key> <value> [--workspace W] [--force]
      arb config unset    <dotted.key> [--workspace W] [--force]

      arb server start    [--timeout SECONDS] [--json]
      arb server restart  [--timeout SECONDS] [--json]
      arb server deploy   [--version vX.Y.Z] [--timeout SECONDS] [--json] [--force]
                          deploy from a GitHub Release (add --git-pull for the
                          legacy git-pull deploy).
      arb server migrate  [--json]
      arb server doctor   [--json]
      arb server version  [--json]

      arb dashboard login [--json]   print a one-time browser login link

      arb workspace list
      arb workspace show  <id>

      arb message inbox   [--all | read <id> | clear | <task-id>]
      arb message send    <recipient> <body> [--subject ...] [--task bd-x] [--kind ...]
                                  (--directive is a deprecated alias for --task)
      arb message notify  [--limit N]

      arb usage show      [--by day|task|epic|workspace|repo|model|step|provider]
                                  [--since 7d|24h|<iso>] [--workspace <id>] [--limit N]
      arb usage events    [--task <task-id>] [--workspace <id>] [--step work|review]
                                  [--since ...] [--limit N]

      arb loop analyze    [--since 7d|24h|<iso>] [--until <iso>] [--limit N]
                                  [--workspace <id>] [--propose] [--discover] [--json]
      arb loop pending    [--state proposed|hypothesis|...] [--kind ...]
                                  [--workspace <id>] [--limit N] [--json]
      arb loop diff       <id>
      arb loop apply      <id> | all [--state proposed]
      arb loop reject     <id> [--reason "..."]

      arb settings get    [key] [--json]          install-wide settings (not workspace config)
      arb settings set    <key> <value>
      arb settings unset  <key>
      arb settings schema [--json]

      arb scheduler pause|resume|status
      arb scheduler wait  [--timeout SECS] [--interval SECS]
      arb node add     [--name N] [--label k=v ...] [--max-workers N] [--ttl 15m] [--token-file PATH]
                       mint a join token: prints the one-liner for the new node and,
                       separately, the token (terminal or --token-file only)
      arb node list|show <name|id>|events <name|id>
      arb node set <name|id> [--name N] [--label k=v ...] [--max-workers N|none]

      arb provider pause <provider|account-ref> [--reason TEXT] [--stop-running]
      arb provider resume <provider|account-ref>
      arb provider list

      arb quota           [--workspace <id|name>] [--json]

      arb preflip-gate    [--json]
                                  §6.3's coverage-shadow rollout gate: may
                                  `merge.coverage_enabled` be flipped?

      arb alert list      [--workspace <id|name>] [--kind <k>] [--json]
      arb breaker list    [--workspace <id|name>] [--kind <k>] [--open] [--json]
      arb breaker reset   <signature> | --all [--kind <k>] [--json]

      arb grok-token                          a grok worker's GROK_AUTH_PROVIDER_COMMAND:
                                  prints {"access_token","expires_in"} from the server

      arb image list      [--json]            worker images (podman backend) + base digest pins
      arb image build     <repo> [--workspace <id|name>] [--json]
                                  build <repo>'s image from its DEFAULT BRANCH
      arb image refresh   [--json]            re-pin base images now, then prune
      arb image prune     [--json]

      arb install cli     [--json]
      arb install service [--system] [--uninstall] [--json]

      arb mcp token mint  --tier coordinator [--workspace <id>] [--ttl <seconds>] [--json]
      arb mcp token verify <token> [--json]

      arb session list                        works with the server stopped (§4.7):
                                               reads systemd + tmux directly, never HTTP
      arb session attach <id> [--read-only]

  ## Meta commands (no resource)

      arb prime                Mission briefing — run at the start of a session
      arb where                Resolve the active workspace / paths
      arb init [path] [--force]
      arb self-update          [--version vX.Y.Z] [--json] [--force]
                               download and atomically replace ~/.local/bin/arb
                               from the latest GitHub Release (or --version).
                               alias: arb upgrade
      arb version
      arb help

  ## Global flags

      --json               Emit machine-readable JSON (default is human-readable text)
      -w, --workspace <n>  Target workspace by name or id; overrides ARB_WORKSPACE
      -h, --help           Show usage

  ## Env

      ARB_HOST       Phoenix base URL (default http://127.0.0.1:4848)
      ARB_WORKSPACE  Workspace name or id (unset: "default", else the sole workspace); overridden by -w / --workspace
  """

  def main(argv) do
    # Start :req's transitive applications. The escript bundles them but does
    # not auto-start. Without this, Req.get crashes with :finch not started.
    {:ok, _} = Application.ensure_all_started(:req)

    # Strip -w / --workspace from the full argv before splitting into cmd/rest,
    # so the flag works at any position (including before the subcommand).
    {flag, workspace, argv} = extract_workspace_flag(argv)

    case argv do
      [] ->
        reject_flag!(flag, "arb")
        usage_and_exit(0)

      ["help" | rest] ->
        reject_flag!(flag, "arb help")
        help(rest)

      [h] when h in ["-h", "--help"] ->
        reject_flag!(flag, "arb help")
        usage_and_exit(0)

      [v] when v in ["-v", "--version"] ->
        reject_flag!(flag, "arb version")
        IO.puts("arb #{ArbiterCli.Version.app_version()}")

      [cmd | rest] ->
        dispatch(cmd, rest, flag, workspace)
    end
  end

  # `arb node set --workspace W` (repeatable, or `none`) is the node's own pin
  # switch, not the global workspace selector: leave it for node.ex to parse.
  # Only the long form is the pin; `-w` stays global everywhere.
  defp extract_workspace_flag(["node", "set" | _] = argv) do
    {flag, name, rest} =
      ArbiterCli.Workspace.extract_flag(Enum.map(argv, &protect_pin/1))

    {flag, name, Enum.map(rest, &unprotect_pin/1)}
  end

  defp extract_workspace_flag(argv), do: ArbiterCli.Workspace.extract_flag(argv)

  defp protect_pin("--workspace"), do: {:pin, "--workspace"}
  defp protect_pin("--workspace=" <> _ = a), do: {:pin, a}
  defp protect_pin(a), do: a
  defp unprotect_pin({:pin, a}), do: a
  defp unprotect_pin(a), do: a

  # `-w` means nothing to help/version/the bare usage screen: refuse it rather
  # than run the command and ignore it.
  defp reject_flag!(nil, _verb), do: :ok

  defp reject_flag!(flag, verb),
    do: ArbiterCli.Output.die("unknown option #{flag_label(flag)} for #{verb}")

  defp dispatch(cmd, args, flag, ws_val) do
    # A `--workspace <name|id>` / `-w` flag anywhere in the invocation overrides
    # the active workspace, exactly as `ARB_WORKSPACE` does. Strip it centrally —
    # before any subcommand's own `OptionParser` runs — and seed the env so every
    # subcommand honors it uniformly, without each declaring the switch.
    {extra_flag, extra_name, args} = extract_workspace_flag([cmd | args])
    args = tl(args)
    flag = flag || extra_flag
    ws_val = ws_val || extra_name

    dispatch_resolved(cmd, args, flag, ws_val)
  end

  defp dispatch_resolved(cmd, args, flag, ws_val) do
    case ArbiterCli.AliasResolver.resolve(cmd) do
      {:ok, canonical} ->
        dispatch_known(canonical, args, flag, ws_val)

      {:unknown, suggestions} ->
        dispatch_legacy_or_unknown(cmd, args, suggestions, flag, ws_val)
    end
  end

  # An old flat command? Run its new form and point the user at it.
  defp dispatch_legacy_or_unknown(cmd, args, suggestions, flag, ws_val) do
    case legacy_redirect(cmd, args) do
      {:ok, canonical, new_args, new_form} ->
        case ArbiterCli.Verbs.fetch(cmd) do
          {:ok, entry} -> check_workspace_guard!(entry, flag, ws_val)
          _ -> :ok
        end

        IO.puts(:stderr, "arb: note: `arb #{cmd}` is now `arb #{new_form}` — running it for you.")
        dispatch_known(canonical, new_args, flag, ws_val)

      :none ->
        IO.puts(:stderr, "arb: unknown command: #{cmd}")

        if suggestions != [] do
          IO.puts(:stderr, "Did you mean: #{Enum.join(suggestions, ", ")}?")
        end

        IO.puts(:stderr, "Run `arb help` for usage.")
        ArbiterCli.Output.halt(2)
    end
  end

  # `arb update` was dual-mode: an id edits a ticket, a bare/flag-first call
  # deploys. Split it across the two new homes.
  defp legacy_redirect("update", args) do
    if deploy_invocation?(args) do
      {:ok, "server", ["deploy" | args], "server deploy"}
    else
      {:ok, "ticket", ["update" | args], "ticket update"}
    end
  end

  defp legacy_redirect(cmd, args) do
    case ArbiterCli.Verbs.fetch(cmd) do
      {:ok, %{kind: :legacy} = entry} ->
        {:ok, entry.redirect_to, entry.prefix ++ args, ArbiterCli.Verbs.new_form(entry)}

      _ ->
        :none
    end
  end

  # A bare verb, or one whose first token is a flag, is a deploy. The moment a
  # positional appears (the ticket id) it's an edit.
  defp deploy_invocation?([]), do: true
  defp deploy_invocation?([first | _]), do: String.starts_with?(first, "-")

  # bd-4jojpw: `issue` was renamed `ticket`. The old resource name keeps working
  # for one release, with a single note on stderr so `--json` stdout stays clean.
  defp dispatch_known("issue", args, flag, ws_val) do
    {:ok, entry} = ArbiterCli.Verbs.fetch("issue")
    check_workspace_guard!(entry, flag, ws_val)
    ArbiterCli.Workspace.put_selected(ws_val)
    IO.puts(:stderr, "arb: note: `arb issue` is deprecated; use `arb ticket` (same subcommands).")
    run_entry(entry, args)
  end

  defp dispatch_known(name, args, flag, ws_val) do
    {:ok, entry} = ArbiterCli.Verbs.fetch(name)
    check_workspace_guard!(entry, flag, ws_val)
    ArbiterCli.Workspace.put_selected(ws_val)
    run_entry(entry, args)
  end

  defp check_workspace_guard!(entry, flag, ws_val) do
    cond do
      flag != nil and entry.workspace == :none ->
        ArbiterCli.Output.die("unknown option #{flag_label(flag)} for arb #{entry.name}")

      flag != nil and is_nil(ws_val) ->
        ArbiterCli.Output.die("option #{flag_label(flag)} for arb #{entry.name} requires a value")

      true ->
        :ok
    end
  end

  defp flag_label(flag) when is_binary(flag) do
    cond do
      String.starts_with?(flag, "--workspace=") -> "--workspace"
      String.starts_with?(flag, "-w=") -> "-w"
      true -> flag
    end
  end

  defp flag_label(_), do: "--workspace"

  defp run_entry(entry, args) do
    case entry.handler do
      __MODULE__ -> usage_and_exit(0)
      handler -> handler.run(ArbiterCli.Verbs.handler_args(entry, args))
    end
  end

  # Terminates the VM via `Output.halt/1` on every clause — spelled out so
  # dialyzer does not report it as an accidental "no local return".
  @spec help(term()) :: no_return()
  defp help(_), do: usage_and_exit(0)

  # Terminates the VM via `Output.halt/1` on every clause — spelled out so
  # dialyzer does not report it as an accidental "no local return".
  @spec usage_and_exit(non_neg_integer()) :: no_return()
  defp usage_and_exit(code) do
    IO.puts(@moduledoc)
    ArbiterCli.Output.halt(code)
  end
end
