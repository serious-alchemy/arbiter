defmodule ArbiterCli.Main do
  @moduledoc """
  Escript entry point. The CLI uses an `arb <resource> <verb>` grammar:
  the first token names a resource (or a flat meta command), the second the
  action on it.

  ## Resources

      arb ticket list     [--state ...] [--type ...] [--priority ...] [--labels ...] [--tracker]
      arb ticket show     <id>
      arb ticket create   <title> [--description ...] [--priority ...] [--type ...]
                                  [--deps id1,id2] [--labels a,b] [--parent <parent-id>]
                                  [--auto-close]
                                  [--require-provider p | --exclude-provider p]
      arb ticket update   <id> [--title ...] [--priority N] [--difficulty N]
                                  [--description d] [--append-notes text]
                                  [--qa-notes text] [--deployment-notes text]
                                  [--pr-body text]
                                  [--require-provider p | --exclude-provider p |
                                   --clear-provider-constraint]
      arb ticket close    <id> [--reason ...]
      arb ticket reopen   <id>
      arb ticket verify   <id> --observed "<evidence>" | --failed "<evidence>"
                                  record the post-merge restart-and-observe result
                                  for a ticket in state verifying
      arb ticket resolve  <id> --accept-as-is|--amend|--send-back|--reject "<reasoning>"
                                  [--gate review_gate|notes_gate|commit_gate] [--round N]
                                  [--actor <who>]
                                  record your answer to a gate escalation — what the
                                  coordinator decided and why (bd-4qjl0q)
      arb ticket claim    <ref> [--force] [--repo <repo>]
      arb ticket sync     [--dry]
      arb ticket ready
      arb ticket dispatch <id> [<repo>] [--with-claude] [--model <name>] [--force]

                                  `arb issue …` is a deprecated alias for `arb ticket …`:
                                  it still runs, and prints a one-line note on stderr.

      arb epic floor      <id> P1|P2|P3|none
                                  set or clear an epic's priority floor: its children
                                  are scheduled as min(own priority, floor). Operator
                                  and coordinator only; P0 is never a floor.

      arb worker list
      arb worker show     <task-id>
      arb worker log      <task-id>
      arb worker stop     <task-id>
      arb worker resume   <task-id> [<repo>] [--model <name>]
      arb worker review   <task-id> [--repo <repo>] [--model <name>] [--force] [--automation <mode>]
      arb review resolve  <task-id> --amend "<reasoning>"   (== arb ticket resolve)

      arb repo list
      arb repo show       <name>

      arb skill list
      arb skill show      <id|name>
      arb skill create    <name> [--body ... | --body-file PATH | -] [--metadata JSON]
      arb skill update    <id|name> [--name NEW] [--body ... | --body-file PATH | -]
                                  [--metadata JSON]
      arb skill delete    <id|name> [--force]

      arb account list                              [--provider p]
      arb account show    <ref>                      (uuid, provider:slug, or bare slug)
      arb account create  <provider> <slug>          [--label ...] [--plan ...] [--max-concurrent N]
      arb account attach  <workspace-id> <provider> <ref> [--share N]
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
    {workspace, argv} = ArbiterCli.Workspace.take_flag(argv)
    if workspace, do: System.put_env("ARB_WORKSPACE", workspace)

    case argv do
      [] -> usage_and_exit(0)
      ["help" | rest] -> help(rest)
      ["-h"] -> usage_and_exit(0)
      ["--help"] -> usage_and_exit(0)
      ["-v"] -> IO.puts("arb #{ArbiterCli.Version.app_version()}")
      ["--version"] -> IO.puts("arb #{ArbiterCli.Version.app_version()}")
      [cmd | rest] -> dispatch(cmd, rest)
    end
  end

  defp dispatch(cmd, args) do
    # A `--workspace <name|id>` / `-w` flag anywhere in the invocation overrides
    # the active workspace, exactly as `ARB_WORKSPACE` does. Strip it centrally —
    # before any subcommand's own `OptionParser` runs — and seed the env so every
    # subcommand honors it uniformly, without each declaring the switch.
    args =
      case ArbiterCli.Workspace.take_flag(args) do
        {nil, rest} ->
          rest

        {name, rest} ->
          System.put_env("ARB_WORKSPACE", name)
          rest
      end

    dispatch_resolved(cmd, args)
  end

  # bd-4qjl0q: `arb review resolve` is the spelling the gate-escalation mail
  # names. `review` alone is a legacy redirect to `worker review`, which would
  # read `resolve` as a task id — so route it before that, with no note.
  defp dispatch_resolved("review", ["resolve" | rest]), do: ArbiterCli.Cmd.Resolve.run(rest)

  defp dispatch_resolved(cmd, args) do
    case ArbiterCli.AliasResolver.resolve(cmd) do
      {:ok, canonical} ->
        dispatch_known(canonical, args)

      {:unknown, suggestions} ->
        dispatch_legacy_or_unknown(cmd, args, suggestions)
    end
  end

  # An old flat command? Run its new form and point the user at it.
  defp dispatch_legacy_or_unknown(cmd, args, suggestions) do
    case legacy_redirect(cmd, args) do
      {:ok, canonical, new_args, new_form} ->
        IO.puts(:stderr, "arb: note: `arb #{cmd}` is now `arb #{new_form}` — running it for you.")
        dispatch_known(canonical, new_args)

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
  defp dispatch_known("issue", args) do
    IO.puts(:stderr, "arb: note: `arb issue` is deprecated; use `arb ticket` (same subcommands).")
    run_entry("issue", args)
  end

  defp dispatch_known(name, args), do: run_entry(name, args)

  defp run_entry(name, args) do
    {:ok, entry} = ArbiterCli.Verbs.fetch(name)

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
