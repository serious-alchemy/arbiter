defmodule Arbiter.Boot.TicketTransitionsTest do
  @moduledoc """
  bd-d8fi92: the boot-time `ticket_transitions` backfill — one-shot,
  primary-only, applied, and never fatal to the boot.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Boot.TicketTransitions
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, TicketTransition, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "btt-#{System.unique_integer([:positive])}", prefix: "btt"})

    # A ticket from before the triggers: no rows yet.
    issue = Ash.create!(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- ok"})
    Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [issue.id])

    {:ok, issue: issue}
  end

  test "is a one-shot temporary worker with this module's id" do
    spec = TicketTransitions.child_spec([])

    assert spec.id == TicketTransitions
    assert spec.restart == :temporary
    assert spec.type == :worker
    assert {TicketTransitions, :start_link, [[]]} = spec.start
  end

  test "the primary applies the backfill", %{issue: issue} do
    capture_log(fn -> assert TicketTransitions.start_link(primary?: true) == :ignore end)

    assert [%{source: "backfill", to_state: :backlog}] = TicketTransition.for_ticket!(issue.id)
  end

  test "a non-primary instance writes nothing", %{issue: issue} do
    assert TicketTransitions.start_link(primary?: false) == :ignore
    assert TicketTransition.for_ticket!(issue.id) == []
  end

  test "a failing backfill is logged and does not abort the boot" do
    Repo.query!("ALTER TABLE ticket_transitions RENAME TO ticket_transitions_gone")

    log = capture_log(fn -> assert TicketTransitions.start_link(primary?: true) == :ignore end)

    assert log =~ "Boot.TicketTransitions"
  end
end
