defmodule Arbiter.ReviewGate.MergeAuthorizationTest do
  @moduledoc """
  bd-651ine / #529 — the ReviewGate's record decides whether the merge path may
  merge: only a reviewer APPROVE, or an `accept_as_is` / `amend` resolution
  covering the head, permits it. A `send_back` never does.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.ReviewGate.{MergeAuthorization, Resolutions, Round}
  alias Arbiter.Tasks.{Issue, Workspace}

  @head "5ff594325aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "ma-#{System.unique_integer([:positive])}"})
    {:ok, task} = Ash.create(Issue, %{title: "merge auth", workspace_id: ws.id})
    %{task: task}
  end

  defp round!(task, attrs) do
    {:ok, row} =
      Ash.create(
        Round,
        Map.merge(
          %{
            task_id: task.id,
            round: 1,
            role: :review,
            verdict: :request_changes,
            finding_count: 1
          },
          attrs
        )
      )

    row
  end

  defp resolve!(task, decision, extra \\ %{}) do
    {:ok, r} =
      Resolutions.record(
        Map.merge(%{task_id: task.id, decision: decision, reasoning: "because"}, extra)
      )

    r
  end

  test "a ticket the gate never argued is not blocked", %{task: task} do
    assert :ok = MergeAuthorization.check(task.id, @head)
    assert :ok = MergeAuthorization.check(nil, @head)
  end

  test "a latest reviewer APPROVE permits the merge", %{task: task} do
    round!(task, %{verdict: :request_changes})
    round!(task, %{round: 2, verdict: :approve, finding_count: 0})
    assert :ok = MergeAuthorization.check(task.id, @head)
  end

  test "an impl row after the last reviewer row does not hide the REQUEST_CHANGES", %{task: task} do
    round!(task, %{verdict: :request_changes})
    round!(task, %{role: :impl, verdict: nil, finding_count: 0})

    assert {:error, {:review_not_approved, %{verdict: :request_changes, round: 1}}} =
             MergeAuthorization.check(task.id, @head)
  end

  test "the NEWEST reviewer row wins even when a fresh gate restarts at round 1", %{task: task} do
    round!(task, %{round: 2, verdict: :request_changes})
    round!(task, %{round: 1, fix_round_attempt: 1, verdict: :approve, finding_count: 0})
    assert :ok = MergeAuthorization.check(task.id, @head)
  end

  test "an unanswered REQUEST_CHANGES refuses", %{task: task} do
    round!(task, %{})
    assert {:error, {:review_not_approved, _}} = MergeAuthorization.check(task.id, @head)
  end

  test "a timed-out reviewer pass is not an approval", %{task: task} do
    round!(task, %{verdict: :timed_out, finding_count: 0})

    assert {:error, {:review_not_approved, %{verdict: :timed_out}}} =
             MergeAuthorization.check(task.id, @head)
  end

  for decision <- ~w(send_back reject) do
    test "#{decision} never authorises a merge", %{task: task} do
      round!(task, %{})
      resolve!(task, unquote(decision))

      assert {:error, {:review_not_approved, %{resolution: resolution}}} =
               MergeAuthorization.check(task.id, @head)

      assert Atom.to_string(resolution) == unquote(decision)
    end
  end

  for decision <- ~w(accept_as_is amend) do
    test "#{decision} authorises the merge", %{task: task} do
      round!(task, %{})
      resolve!(task, unquote(decision))
      assert :ok = MergeAuthorization.check(task.id, @head)
    end
  end

  test "a resolution recorded against another head does not cover this one", %{task: task} do
    round!(task, %{})
    resolve!(task, "accept_as_is", %{head_sha: "0ld"})

    assert {:error, {:review_not_approved, _}} = MergeAuthorization.check(task.id, @head)
    assert :ok = MergeAuthorization.check(task.id, "0ld")
  end

  test "a resolution recorded against this head covers it", %{task: task} do
    round!(task, %{})
    resolve!(task, "amend", %{head_sha: @head})
    assert :ok = MergeAuthorization.check(task.id, @head)
  end

  test "an accept_as_is recorded BEFORE the latest reviewer round answers an older argument",
       %{task: task} do
    round!(task, %{})
    resolve!(task, "accept_as_is")
    round!(task, %{round: 2, verdict: :request_changes})

    assert {:error, {:review_not_approved, %{round: 2}}} =
             MergeAuthorization.check(task.id, @head)
  end

  test "a later send_back withdraws an earlier accept_as_is", %{task: task} do
    round!(task, %{})
    resolve!(task, "accept_as_is")
    resolve!(task, "send_back")

    assert {:error, {:review_not_approved, %{resolution: :send_back}}} =
             MergeAuthorization.check(task.id, @head)
  end

  test "a resolution for another gate is not an answer to the ReviewGate", %{task: task} do
    round!(task, %{})
    resolve!(task, "accept_as_is", %{gate: "notes_gate"})
    assert {:error, {:review_not_approved, _}} = MergeAuthorization.check(task.id, @head)
  end

  test "describe/1 says send_back is not a pass", %{task: task} do
    round!(task, %{})
    resolve!(task, "send_back")
    {:error, refusal} = MergeAuthorization.check(task.id, @head)
    assert MergeAuthorization.describe(refusal) =~ "another review round must follow"
  end

  test "Resolutions.record stamps the PR head the ticket was last seen at", %{task: task} do
    {:ok, task} =
      Ash.update(task, %{merger_status: %{"head_sha" => @head}}, action: :record_merger_status)

    assert resolve!(task, "accept_as_is").head_sha == @head
    assert resolve!(task, "accept_as_is", %{head_sha: "abc"}).head_sha == "abc"
  end
end
