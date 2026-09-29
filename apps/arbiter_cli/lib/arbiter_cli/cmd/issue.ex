defmodule ArbiterCli.Cmd.Issue do
  @moduledoc """
  `arb ticket <verb>` — the ticket resource. `arb issue <verb>` is its
  deprecated alias (bd-4jojpw): `ArbiterCli.Main` prints a one-line note and
  runs the same verb here.

      arb ticket list     [--status ...] [--type ...] [--priority ...]
                          [--labels ...] [--tracker]
      arb ticket show     <id>
      arb ticket create   <title> [--description ...] [--priority ...]
                          [--type ...] [--deps id1,id2] [--labels a,b]
                          [--parent <parent-id>] [--auto-close]
                          [--repo <repo_paths key>]
      arb ticket update   <id> [--title ...] [--priority N] [--difficulty N]
                          [--status s] [--description d]
                          [--append-notes text] [--qa-notes text]
                          [--deployment-notes text] [--pr-body text]
      arb ticket close    <id> [--reason ...]
      arb ticket reopen   <id>
      arb ticket promote  <id> [--waive REASON]
      arb ticket demote   <id>
      arb ticket rank     <id> --top | --bottom | --before <id> | --after <id>
      arb ticket verify   <id> --observed "<evidence>" | --failed "<evidence>"
      arb ticket handoff  <id> --note "<what the operator has to do>"
      arb ticket handback <id> [--note "<what changed>"]
      arb ticket claim    <issue#> [--force] [--repo <repo>]
      arb ticket sync     [--dry]
      arb ticket ready
      arb ticket dispatch <id> [<repo>] [--with-claude] [--model <name>]
  """

  alias ArbiterCli.Cmd
  alias ArbiterCli.Output
  alias ArbiterCli.Workspace

  # Pre-existing complexity 18 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    # A `--workspace <name>` flag anywhere in an `arb ticket *` invocation
    # overrides the active workspace, exactly as `ARB_WORKSPACE` does. We
    # strip it here and seed the env so every subcommand below — each of
    # which resolves the workspace through `ARB_WORKSPACE` — honors it
    # uniformly, without each having to declare the switch itself.
    argv =
      case Workspace.take_flag(argv) do
        {nil, rest} ->
          rest

        {name, rest} ->
          System.put_env("ARB_WORKSPACE", name)
          rest
      end

    case argv do
      ["list" | rest] -> Cmd.List.run(rest)
      ["show" | rest] -> Cmd.Show.run(rest)
      ["create" | rest] -> Cmd.Create.run(rest)
      ["update" | rest] -> Cmd.Update.edit_issue(rest)
      ["close" | rest] -> Cmd.Close.run(rest)
      ["reopen" | rest] -> Cmd.Reopen.run(rest)
      ["promote" | rest] -> Cmd.Promote.run(rest)
      ["demote" | rest] -> Cmd.Demote.run(rest)
      ["rank" | rest] -> Cmd.Rank.run(rest)
      ["verify" | rest] -> Cmd.Verify.run(rest)
      ["handoff" | rest] -> Cmd.Handoff.run(:operator, rest)
      ["handback" | rest] -> Cmd.Handoff.run(:coordinator, rest)
      ["claim" | rest] -> Cmd.Claim.run(rest)
      ["sync" | rest] -> Cmd.Sync.run(rest)
      ["ready" | rest] -> Cmd.Ready.run(rest)
      ["dispatch" | rest] -> Cmd.Dispatch.run(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("ticket requires a subcommand", usage_hint())
      [unknown | _] -> Output.die("unknown ticket subcommand: #{unknown}", usage_hint())
    end
  end

  @subcommands ~w(list show create update close reopen promote demote rank verify handoff handback claim sync ready dispatch)

  @doc "Every verb `arb ticket` (and its deprecated alias `arb issue`) accepts."
  @spec subcommands() :: [String.t()]
  def subcommands, do: @subcommands

  defp usage_hint, do: "verbs: " <> Enum.join(@subcommands, ", ")
end
