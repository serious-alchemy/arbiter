defmodule Arbiter.Tasks.IssuePrStateTest do
  @moduledoc """
  bd-741sid: the ticket owns its PR's state — the ref, its URL, the Watchdog's
  lane, the forge's last answer and when it was read, and the ReviewGate round
  state — so no worker has to stay resident to hold it.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pr-state-#{System.unique_integer([:positive])}",
        prefix: "ps"
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "pr state", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    assert task.state == :active

    %{task: task}
  end

  test "pr_opened/3 records the ref, its URL and the Watchdog lane in the open_pr write", %{
    task: task
  } do
    lane = %{"via_review_gate" => true, "local_head_sha" => "abc123"}

    assert {:ok, opened} =
             Issue.pr_opened(task.id, "#42",
               merger_url: "https://github.com/o/r/pull/42",
               merge_watch: lane
             )

    assert opened.state == :merging

    reloaded = Ash.get!(Issue, task.id)
    assert reloaded.pr_ref == "#42"
    assert reloaded.merger_url == "https://github.com/o/r/pull/42"
    assert reloaded.merge_watch == lane
  end

  test "record_merger_status/2 keeps the forge's answer, decodable, with when it was read", %{
    task: task
  } do
    {:ok, _} = Issue.pr_opened(task.id, "#43")

    assert :ok =
             PullRequest.record_merger_status(task.id, %{
               status: :open,
               approved: true,
               block_reason: :ci_failed,
               pipeline: :failed,
               head_sha: "def456",
               body: "the whole PR description, which the ticket has no use for"
             })

    reloaded = Ash.get!(Issue, task.id)
    assert %DateTime{} = reloaded.merger_checked_at

    assert PullRequest.merger_status(reloaded) == %{
             status: :open,
             approved: true,
             block_reason: :ci_failed,
             pipeline: :failed,
             head_sha: "def456"
           }

    refute Map.has_key?(reloaded.merger_status, "body")
  end

  test "a poll is not an edit: recording the merger status leaves updated_at alone", %{
    task: task
  } do
    {:ok, opened} = Issue.pr_opened(task.id, "#45")

    :ok = PullRequest.record_merger_status(task.id, %{status: :open, pipeline: :running})

    reloaded = Ash.get!(Issue, task.id)
    assert %DateTime{} = reloaded.merger_checked_at
    assert reloaded.updated_at == opened.updated_at
  end

  test "an unknown value read back from the row stays a string, never a new atom", %{task: task} do
    {:ok, _} = Issue.pr_opened(task.id, "#44")

    :ok =
      PullRequest.record_merger_status(task.id, %{status: :open, pipeline: "some_future_state"})

    assert %{pipeline: "some_future_state"} = PullRequest.merger_status(Ash.get!(Issue, task.id))
  end

  test "a closed PR sends the ticket back to work with the pr_closed cause", %{task: task} do
    {:ok, _} = Issue.pr_opened(task.id, "#45")

    assert {:ok, back} = Issue.pr_closed(task.id, "#45")
    assert back.state == :active
    assert back.attention_cause == :pr_closed
    assert back.attention_detail =~ "#45"
    assert %DateTime{} = back.attention_since
  end

  test "opening a PR again clears the pr_closed cause", %{task: task} do
    {:ok, _} = Issue.pr_opened(task.id, "#46")
    {:ok, _} = Issue.pr_closed(task.id, "#46")

    assert {:ok, reopened} = Issue.pr_opened(task.id, "#47")
    assert reopened.state == :merging
    assert is_nil(reopened.attention_cause)
    assert is_nil(reopened.attention_detail)
    assert is_nil(reopened.attention_since)
  end

  test "record_review_gate/2 merges the ReviewGate round state onto the row", %{task: task} do
    assert :ok = PullRequest.record_review_gate(task.id, %{branch: "feat/x", round: 1})
    assert :ok = PullRequest.record_review_gate(task.id, %{verdict: :request_changes})

    assert %{"branch" => "feat/x", "round" => 1, "verdict" => "request_changes"} =
             Ash.get!(Issue, task.id).review_gate_state
  end

  test "reopening the ticket drops the old PR's state", %{task: task} do
    {:ok, _} =
      Issue.pr_opened(task.id, "#48",
        merger_url: "https://github.com/o/r/pull/48",
        merge_watch: %{"via_review_gate" => false}
      )

    :ok = PullRequest.record_merger_status(task.id, %{status: :merged})
    :ok = PullRequest.record_review_gate(task.id, %{verdict: :approve})

    closed = Ash.get!(Issue, task.id) |> Ash.update!(%{}, action: :close)
    reopened = Ash.update!(closed, %{}, action: :reopen)

    assert is_nil(reopened.pr_ref)
    assert is_nil(reopened.merger_url)
    assert is_nil(reopened.merger_status)
    assert is_nil(reopened.merger_checked_at)
    assert is_nil(reopened.merge_watch)
    assert is_nil(reopened.review_gate_state)
  end

  # bd-cw3w9p: a review-only run adopting the PR leaves the ticket open for
  # ReviewPatrol when it merges. `worker_review` onto a ticket already In
  # progress does not stamp `review_only` on the row, so the lane carries it.
  test "a PR adopted by a review-only run leaves the ticket open when it merges", %{task: task} do
    {:ok, _} = Issue.pr_opened(task.id, "#52", merge_watch: PullRequest.lane(review_only: true))

    assert {:ok, :engagement} = PullRequest.merged(task.id)
    refute Ash.get!(Issue, task.id).state in [:closed, :verifying]
  end

  # A PR opened before its ticket recorded a lane — every PR open when
  # bd-741sid deploys. Its Watchdog, restarted from the row, must still know
  # the ReviewGate approved it, or it waits on a forge approval that an
  # Arbiter-authored PR never gets.
  describe "watch_opts/1 for a PR opened before its lane was recorded" do
    defp stamp_reviewed(id),
      do: Ash.update!(Ash.get!(Issue, id), %{last_reviewed_sha: String.duplicate("a", 40)})

    test "the ReviewGate's approval stamp puts it on the gate's lane", %{task: task} do
      {:ok, _} = Issue.pr_opened(task.id, "#49")
      stamp_reviewed(task.id)

      assert {:ok, opts} = PullRequest.watch_opts(task.id)
      assert opts[:via_review_gate] == true
    end

    test "with no stamp it is not on the gate's lane", %{task: task} do
      {:ok, _} = Issue.pr_opened(task.id, "#50")

      assert {:ok, opts} = PullRequest.watch_opts(task.id)
      assert opts[:via_review_gate] == false
    end

    test "a recorded lane is taken as recorded", %{task: task} do
      {:ok, _} =
        Issue.pr_opened(task.id, "#51", merge_watch: PullRequest.lane(via_review_gate: false))

      stamp_reviewed(task.id)

      assert {:ok, opts} = PullRequest.watch_opts(task.id)
      assert opts[:via_review_gate] == false
    end
  end
end
