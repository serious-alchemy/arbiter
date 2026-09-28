defmodule Arbiter.Tasks.AttentionAutoClearTest do
  @moduledoc """
  bd-8if9zt (ticket lifecycle 6/13, AC5): a ticket's attention cause clears
  itself when the ticket's state moves on or its run restarts, and the
  ticket's escalations are marked resolved in the same step.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Messages.Escalation
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, PullRequest, ReviewPark, Verification, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "attention-#{System.unique_integer([:positive])}",
        prefix: "at"
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "attention", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    assert task.state == :active

    %{ws: ws, task: task}
  end

  defp escalations(task_id) do
    Message
    |> Ash.Query.filter(task_ref == ^task_id and kind == :escalation)
    |> Ash.read!()
  end

  defp assert_all_resolved(task_id) do
    rows = escalations(task_id)
    assert rows != []

    for row <- rows do
      assert %DateTime{} = row.resolved_at, "#{row.escalation_kind} was not resolved"
      assert %DateTime{} = row.cleared_at
    end
  end

  test "a ticket parked for review that gets resumed", %{ws: ws, task: task} do
    {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)

    {:ok, _} =
      Escalation.post(%{
        kind: :review_parked,
        workspace_id: ws.id,
        task_ref: task.id,
        subject: "ReviewGate parked #{task.id} — review inconclusive",
        body: "parked"
      })

    parked = Ash.get!(Issue, task.id)
    assert parked.attention_cause == :inconclusive
    assert %DateTime{} = parked.attention_since
    assert parked.review_park_reason == "inconclusive"

    prior =
      Ash.create!(Run, %{
        task_id: task.id,
        repo: "arbiter",
        workspace_id: ws.id,
        state: :finished,
        outcome: :failed,
        started_at: DateTime.add(DateTime.utc_now(), -600, :second)
      })

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "arbiter",
        workspace_id: ws.id,
        meta: %{resume: true, resumed_from_run_id: prior.id}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    resumed = Ash.get!(Issue, task.id)
    assert resumed.attention_cause == nil
    assert resumed.attention_since == nil
    assert resumed.review_park_reason == nil
    assert_all_resolved(task.id)
  end

  test "a :verifying ticket that gets verified", %{task: task} do
    {:ok, task} = Ash.update(task, %{verify_after_deploy: true})
    {:ok, merging} = Issue.pr_opened(task.id, "#41")

    {:ok, :awaiting_verification, verifying} = Verification.finalize_merged(merging)
    assert verifying.state == :verifying
    assert verifying.attention_cause == :awaiting_verification
    assert [%{escalation_kind: :awaiting_verification, cleared_at: nil}] = escalations(task.id)

    {:ok, closed} = Verification.observed(verifying, "the new path answered on the live server")

    assert closed.state == :closed
    assert Ash.get!(Issue, task.id).attention_cause == nil
    assert_all_resolved(task.id)
  end

  test "a :merging ticket with merge_blocked that then merges", %{ws: ws, task: task} do
    {:ok, merging} = Issue.pr_opened(task.id, "#42")
    assert merging.state == :merging

    :ok =
      CoordinatorNotifier.merge_blocked(
        %{task_id: task.id, workspace_id: ws.id},
        "#42",
        :conflict
      )

    blocked = Ash.get!(Issue, task.id)
    assert blocked.attention_cause == :merge_blocked
    assert [%{escalation_kind: :merge_blocked, cleared_at: nil}] = escalations(task.id)

    {:ok, :closed, closed} = Verification.finalize_merged(blocked, close_upstream: false)

    assert closed.state == :closed
    assert Ash.get!(Issue, task.id).attention_cause == nil
    assert_all_resolved(task.id)
  end

  describe "what a clear leaves alone" do
    test "the page a transition itself raises survives it", %{task: task} do
      {:ok, _} = Issue.pr_opened(task.id, "#43")
      {:ok, returned} = PullRequest.closed(task.id, "#43")

      assert returned.state == :active
      assert returned.attention_cause == :pr_closed

      assert [%{escalation_kind: :pr_closed, resolved_at: nil, cleared_at: nil}] =
               escalations(task.id)
    end

    test "a system-scoped escalation about the ticket is not resolved", %{ws: ws, task: task} do
      {:ok, _} =
        Escalation.post(%{
          kind: :budget_exceeded,
          workspace_id: ws.id,
          task_ref: task.id,
          subject: "over budget",
          body: "x"
        })

      {:ok, _} = Ash.update(Ash.get!(Issue, task.id), %{}, action: :close)

      assert [%{escalation_kind: :budget_exceeded, resolved_at: nil}] = escalations(task.id)
    end

    test "another ticket's escalations are untouched", %{ws: ws, task: task} do
      {:ok, other} =
        Ash.create(Issue, %{title: "other", workspace_id: ws.id, issue_type: :feature})

      {:ok, _} =
        Escalation.post(%{
          kind: :worker_stopped,
          workspace_id: ws.id,
          task_ref: other.id,
          subject: "stopped",
          body: "x"
        })

      {:ok, _} = Ash.update(Ash.get!(Issue, task.id), %{}, action: :close)

      assert [%{resolved_at: nil}] = escalations(other.id)
    end
  end

  describe "raising a cause" do
    test "a repeat of the same cause keeps its since", %{ws: ws, task: task} do
      post = fn subject ->
        Escalation.post(%{
          kind: :worker_stopped,
          workspace_id: ws.id,
          task_ref: task.id,
          subject: subject,
          body: "x"
        })
      end

      {:ok, _} = post.("stopped")
      first = Ash.get!(Issue, task.id)
      assert first.attention_cause == :run_crashed

      {:ok, _} = post.("stopped again")
      again = Ash.get!(Issue, task.id)
      assert again.attention_since == first.attention_since
      assert again.attention_detail == "stopped again"
    end

    test "entering verification records its cause once", %{task: task} do
      {:ok, task} = Ash.update(task, %{verify_after_deploy: true})
      {:ok, merging} = Issue.pr_opened(task.id, "#43")

      # The transition records the cause; its notice must not record it again.
      {:ok, :awaiting_verification, _} = Verification.finalize_merged(merging)

      assert Ash.get!(Issue, task.id).attention_cause == :awaiting_verification
      assert [%{escalation_kind: :awaiting_verification}] = escalations(task.id)

      refute Issue.Version
             |> Ash.Query.filter(
               version_source_id == ^task.id and version_action_name == :raise_attention
             )
             |> Ash.read!()
             |> Enum.any?()
    end

    test "a closed ticket takes no cause", %{ws: ws, task: task} do
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, _} =
        Escalation.post(%{
          kind: :worker_stopped,
          workspace_id: ws.id,
          task_ref: task.id,
          subject: "late",
          body: "x"
        })

      assert Ash.get!(Issue, task.id).attention_cause == nil
    end
  end
end
