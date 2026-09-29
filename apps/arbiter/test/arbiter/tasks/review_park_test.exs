defmodule Arbiter.Tasks.ReviewParkTest do
  @moduledoc """
  The park row as the escalation claim (bd-9zuvbh, invariant I3 of design
  #1635 §5.1: one escalation per episode).

  The claim lives in the row rather than in the worker's memory for the reason
  `ReviewPatrol.claim_review_cap_escalation/1` does: a worker that restarts, or
  a gate that reports its terminal twice, must not buy a second page. The
  episode's reset condition is the guard's own — here, the park reason changing,
  or a human clearing the park and the gate reaching the same terminal again.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.{Issue, ReviewPark, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "park-unit-#{System.unique_integer([:positive])}",
        prefix: "pu"
      })

    {:ok, task} = Ash.create(Issue, %{title: "parkable", workspace_id: ws.id})
    task = put_state!(task, :active)

    %{ws: ws, task: task}
  end

  test "the first park claims the episode", %{task: task} do
    assert {:ok, :claimed, parked} = ReviewPark.park(task.id, :inconclusive)
    # bd-36ytcl: the park is the ticket's attention cause, stamped when it parked.
    assert parked.attention_cause == :inconclusive
    assert %DateTime{} = parked.attention_since
    assert ReviewPark.parked?(parked)
    assert ReviewPark.reason(parked) == :inconclusive
  end

  test "re-parking for the same reason does not re-claim", %{task: task} do
    {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)

    assert {:ok, :already_parked, _} = ReviewPark.park(task.id, :inconclusive)
  end

  test "re-parking for the same reason keeps the wait clock", %{task: task} do
    {:ok, :claimed, first} = ReviewPark.park(task.id, :inconclusive)
    {:ok, :already_parked, again} = ReviewPark.park(task.id, :inconclusive)

    assert again.attention_since == first.attention_since
  end

  test "a reason ReviewPark does not know is refused, not recorded", %{task: task} do
    assert {:error, {:unknown_park_reason, :some_future_guard}} =
             ReviewPark.park(task.id, :some_future_guard)

    refute ReviewPark.parked?(Ash.get!(Issue, task.id))
  end

  test "a ticket carrying a cause that is not a park is not parked", %{task: task} do
    {:ok, flagged} =
      Ash.update(task, %{cause: :pr_closed, detail: "closed"}, action: :raise_attention)

    refute ReviewPark.parked?(flagged)
    assert ReviewPark.reason(flagged) == nil
  end

  test "a different reason is a new episode", %{task: task} do
    {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)

    assert {:ok, :claimed, parked} = ReviewPark.park(task.id, :reviewer_timeout)
    assert parked.attention_cause == :reviewer_timeout
  end

  test "clearing and re-reaching the same terminal is a new episode", %{task: task} do
    {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)
    {:ok, cleared} = ReviewPark.clear(task.id, :review_rerun)
    refute ReviewPark.parked?(cleared)

    assert {:ok, :claimed, _} = ReviewPark.park(task.id, :inconclusive)
  end

  test "clearing an unparked task is a no-op success", %{task: task} do
    assert {:ok, unchanged} = ReviewPark.clear(task.id, :review_rerun)
    refute ReviewPark.parked?(unchanged)
  end

  test "the park does not move the task out of :active", %{task: task} do
    {:ok, :claimed, parked} = ReviewPark.park(task.id, :verdict_guard_exhausted)

    # A cause, not a state: Tasks.Claim and the board must keep seeing live work.
    assert parked.state == :active
  end

  test "every reason renders a subject phrase and an explanation" do
    for {reason, _} <- ReviewPark.reasons() do
      assert is_binary(ReviewPark.subject_phrase(reason))
      assert ReviewPark.explain(reason) != ""
      refute ReviewPark.explain(reason) =~ "terminal no-verdict state ("
    end
  end

  test "an unknown reason renders rather than raising" do
    assert ReviewPark.explain(:something_new) =~ "something_new"
    assert ReviewPark.subject_phrase("not_an_atom_anywhere") == "not_an_atom_anywhere"
  end
end
