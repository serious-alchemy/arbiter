defmodule Arbiter.Tasks.IssueVerificationTest do
  @moduledoc """
  bd-9so315 — post-merge verification state.

  A task flagged `verify_after_deploy: true` must not close on merge. It enters
  `:verifying` and only leaves that state when the coordinator records a
  restart-and-observe result.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  require Ash.Query

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Verification
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "verify-ws", prefix: "vfy"})
    {:ok, ws: ws}
  end

  defp task(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id}, attrs))

    issue
  end

  # bd-842qio: a task parks for verification only from work in progress, so the
  # tests that park one directly start it first.
  defp in_progress(issue), do: put_state!(issue, :active)

  describe "verify_after_deploy flag" do
    test "defaults to false and is settable at create", %{ws: ws} do
      assert task(ws).verify_after_deploy == false
      assert task(ws, %{verify_after_deploy: true}).verify_after_deploy == true
    end

    test "is settable via the :update action", %{ws: ws} do
      issue = task(ws)
      {:ok, updated} = Ash.update(issue, %{verify_after_deploy: true}, action: :update)
      assert updated.verify_after_deploy == true
    end
  end

  describe ":await_verification action" do
    test "moves a task in progress into :verifying and stamps the clock", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true}) |> in_progress()

      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      assert awaiting.state == :verifying
      assert awaiting.attention_cause == :awaiting_verification
      assert %DateTime{} = awaiting.awaiting_verification_at
      assert awaiting.closed_at == nil
      assert awaiting.verification_outcome == nil
    end

    # bd-842qio: the lifecycle table parks only work in progress (active |
    # merging). A ticket still in the queue has nothing merged to verify.
    test "is rejected for a task that was never started", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})

      assert {:error, %Ash.Error.Invalid{}} = Ash.update(issue, %{}, action: :await_verification)
      assert Ash.get!(Issue, issue.id).state == :backlog
    end

    test "is rejected for an already-closed task", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)

      assert {:error, _} = Ash.update(closed, %{}, action: :await_verification)
    end
  end

  describe "lifecycle guards" do
    test ":update cannot move a task into or out of :verifying", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})

      assert {:error, _} = Ash.update(issue, %{state: :verifying}, action: :update)

      {:ok, awaiting} = issue |> in_progress() |> Ash.update(%{}, action: :await_verification)
      assert {:error, _} = Ash.update(awaiting, %{state: :queued}, action: :update)
      assert Ash.get!(Issue, awaiting.id).state == :verifying
    end

    test ":close is allowed from :verifying", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true}) |> in_progress()
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      {:ok, closed} = Ash.update(awaiting, %{close_upstream: false}, action: :close)
      assert closed.state == :closed
    end

    test ":reopen is allowed from :verifying", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true}) |> in_progress()
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      {:ok, reopened} = Ash.update(awaiting, %{}, action: :reopen)
      assert reopened.state == :queued
    end
  end

  describe "Verification.observed/2" do
    test "closes the task and persists the evidence", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true}) |> in_progress()
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      {:ok, verified} = Verification.observed(awaiting, "hit /doctor after restart: 3 repos")

      assert verified.state == :closed
      assert verified.verification_outcome == :observed
      assert verified.verification_evidence == "hit /doctor after restart: 3 repos"
      assert %DateTime{} = verified.closed_at
    end

    test "rejects a task that is not awaiting verification", %{ws: ws} do
      issue = task(ws)
      assert {:error, :not_awaiting_verification} = Verification.observed(issue, "x")
    end

    test "requires non-blank evidence", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true}) |> in_progress()
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      assert {:error, :evidence_required} = Verification.observed(awaiting, "   ")
    end
  end

  describe "Verification.failed/2" do
    test "reopens the task and persists the evidence", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, issue} = Ash.update(issue, %{pr_ref: "1633"}, action: :update)
      {:ok, awaiting} = issue |> in_progress() |> Ash.update(%{}, action: :await_verification)

      {:ok, failed} = Verification.failed(awaiting, "capture_source still reads headers")

      assert failed.state == :queued
      assert failed.verification_outcome == :failed
      assert failed.verification_evidence == "capture_source still reads headers"
      assert failed.closed_at == nil
      # A reopen starts a fresh attempt — the merged PR is no longer its PR.
      assert failed.pr_ref == nil
      # The flag survives, so the retry re-enters verification on its next merge.
      assert failed.verify_after_deploy == true
    end
  end

  describe "Verification.finalize_merged/2" do
    test "an unflagged task closes, exactly as before the flag existed", %{ws: ws} do
      issue = task(ws)

      assert {:ok, :closed, closed} = Verification.finalize_merged(issue, close_upstream: false)
      assert closed.state == :closed
      assert Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id) == []
    end

    test "a flagged task parks and escalates exactly once", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})

      assert {:ok, :awaiting_verification, parked} =
               Verification.finalize_merged(issue, close_upstream: false, mr_ref: "#1633")

      assert parked.state == :verifying
      assert [escalation] = Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id)
      assert escalation.subject =~ "awaiting verification"
      assert escalation.body =~ "#1633"

      # A second finalize (a re-tick, a second sweep) must not park again or
      # page again — the guard refuses and no escalation is sent.
      assert {:error, _} = Verification.finalize_merged(parked, close_upstream: false)
      assert length(Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id)) == 1
    end
  end

  describe "Verification.awaiting_since/1" do
    test "prefers the parked-at stamp", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true}) |> in_progress()
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      assert Verification.awaiting_since(awaiting) == awaiting.awaiting_verification_at
      refute is_nil(Verification.awaiting_since(awaiting))
    end

    test "falls back to updated_at for a row parked before the column existed" do
      at = ~U[2026-09-01 00:00:00Z]
      assert Verification.awaiting_since(%{updated_at: at}) == at
    end
  end

  # bd-842qio (ticket lifecycle 1/13, AC7): the verification funnel moves the
  # stored state through the lifecycle transitions.
  describe "the ticket's lifecycle state" do
    test "finalize_merged closes an unflagged merging ticket → :closed", %{ws: ws} do
      issue = merging(ws)

      assert {:ok, :closed, closed} = Verification.finalize_merged(issue, close_upstream: false)
      assert {closed.state, closed.close_reason} == {:closed, :completed}
    end

    test "finalize_merged parks a flagged merging ticket → :verifying", %{ws: ws} do
      issue = merging(ws, %{verify_after_deploy: true})

      assert {:ok, :awaiting_verification, parked} =
               Verification.finalize_merged(issue, close_upstream: false)

      assert {parked.state, parked.attention_cause} == {:verifying, :awaiting_verification}
    end

    test "finalize_merged walks a flagged ticket still in the queue through start → :verifying",
         %{ws: ws} do
      # A PR merged while its ticket sat in the queue — e.g. a requeue after
      # the PR opened, then a merge by hand.
      {:ok, queued} =
        ws
        |> task(%{verify_after_deploy: true, acceptance: "- works"})
        |> Ash.update(%{}, action: :promote)

      assert {:ok, :awaiting_verification, parked} =
               Verification.finalize_merged(queued, close_upstream: false)

      assert parked.state == :verifying
      assert Enum.take(version_actions(queued.id), -2) == [:start, :await_verification]
    end

    test "finalize_merged walks a flagged Backlog ticket with a merged PR → :verifying",
         %{ws: ws} do
      {:ok, backlog} = Ash.update(task(ws, %{verify_after_deploy: true}), %{pr_ref: "#9"})
      assert backlog.state == :backlog

      assert {:ok, :awaiting_verification, parked} =
               Verification.finalize_merged(backlog, close_upstream: false)

      assert parked.state == :verifying
    end

    test "observed closes a verifying ticket → :closed", %{ws: ws} do
      {:ok, parked} = ws |> merging(%{verify_after_deploy: true}) |> park()

      {:ok, closed} = Verification.observed(parked, "restarted; the new path answers")

      assert {closed.state, closed.close_reason} == {:closed, :completed}
    end

    test "failed reopens a verifying ticket → :queued", %{ws: ws} do
      {:ok, parked} = ws |> merging(%{verify_after_deploy: true}) |> park()

      {:ok, reopened} = Verification.failed(parked, "after restart the old path still answers")

      assert {reopened.state, reopened.close_reason} == {:queued, nil}
    end
  end

  # A ticket with an open PR, through the lifecycle transitions.
  defp merging(ws, attrs \\ %{}) do
    ws
    |> task(Map.put(attrs, :acceptance, "- works"))
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)
    |> Ash.update!(%{pr_ref: "#1633"}, action: :open_pr)
  end

  defp park(issue), do: Ash.update(issue, %{}, action: :await_verification)

  defp version_actions(issue_id) do
    Issue.Version
    |> Ash.Query.filter(version_source_id == ^issue_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!()
    |> Enum.map(& &1.version_action_name)
  end
end
