defmodule Arbiter.ReviewGate.RulingResumeTest do
  @moduledoc """
  A merge-permitting ruling (`accept_as_is` / `amend`) puts the ticket back on
  the ordinary merge path: Arbiter waits for CI on the ruled head, merges
  exactly that head, closes the ticket and says so on the `review_gate` event
  stream — the coordinator no longer waits for the pipeline and merges by hand.

  The forge cases run on `StubMerger` (the lane's adapter is adapter-agnostic:
  GitHub and GitLab differ only in the module behind `Arbiter.Mergers.Merger`);
  the direct case runs a real repository through `Arbiter.Mergers.Direct`.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2, put_state!: 3]

  alias Arbiter.Messages.Message
  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  @head "5ff594325aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @ref "!rr1"

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    :ok
  end

  defp workspace(merge) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rr-#{System.unique_integer([:positive])}",
        prefix: "rr",
        config: %{"review" => %{"required" => true}, "merge" => merge}
      })

    ws
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  # A ticket the gate parked on a REQUEST_CHANGES round: Active, with the round
  # state the gate recorded and its PR open — no author resident.
  defp parked_ticket(ws, extra_state \\ %{}) do
    {:ok, task} =
      Ash.create(Issue, %{title: "ruled", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)
    on_exit(fn -> stop(Watchdog.whereis(task.id)) end)

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: :request_changes,
        findings: "[high] a.ex:1 needs a guard",
        finding_count: 1
      })

    :ok =
      PullRequest.record_review_gate(
        task.id,
        Map.merge(
          %{
            branch: "feature/ruled",
            pr_ref: @ref,
            target_branch: "main",
            verdict: "request_changes",
            merge_opts: %{
              adapter: Atom.to_string(StubMerger),
              workspace_id: ws.id,
              interval_ms: 15,
              initial_delay_ms: 0
            }
          },
          extra_state
        )
      )

    task
  end

  # The ticket as it sits after the gate opened its PR: Merging, with the lane
  # its Watchdog watches it on.
  defp merging(task) do
    task = put_state!(task, :merging, pr_ref: @ref)

    lane =
      PullRequest.lane(
        adapter: StubMerger,
        via_review_gate: true,
        interval_ms: 15,
        initial_delay_ms: 0
      )

    Ash.update!(task, %{merge_watch: lane}, action: :record_merge_watch)
  end

  defp rule(task, decision, extra \\ %{}) do
    {:ok, resolution} =
      Resolutions.record(
        Map.merge(
          %{task_id: task.id, decision: decision, reasoning: "ship it", head_sha: @head},
          extra
        )
      )

    resolution
  end

  defp subscribe(ws),
    do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(15) && do_wait(fun, deadline)
    end
  end

  defp ticket(id), do: Ash.get!(Issue, id)

  defp green(extra \\ %{}),
    do:
      Map.merge(
        %{
          status: :open,
          approved: false,
          ci_clean: true,
          pipeline: :success,
          head_sha: @head,
          base_ref: "main"
        },
        extra
      )

  describe "a forge PR" do
    for decision <- [:accept_as_is, :amend] do
      test "#{decision}: leaves waiting_on_you, waits for CI on the ruled head, merges exactly it, closes",
           _ctx do
        ws = workspace(%{"auto_merge" => true})
        task = parked_ticket(ws)
        subscribe(ws)

        # CI is still running on the first polls, then goes green on the same head.
        StubMerger.queue_get(@ref, [
          green(%{ci_clean: false, pipeline: :running}),
          green(%{ci_clean: false, pipeline: :running}),
          green()
        ])

        StubMerger.next_open_ref(@ref)
        rule(task, unquote(decision))

        assert_receive {:event, %{topic: "review_gate", ruling_event: "resumed"} = resumed}
        assert resumed.task_id == task.id
        assert resumed.head_sha == @head

        # The ticket is back on the merge path with a Watchdog, not parked.
        assert ticket(task.id).state in [:merging, :closed]
        refute ticket(task.id).attention_cause in [:review_gate_not_converged]

        wait_until(fn -> ticket(task.id).state == :closed end)

        assert StubMerger.merge_count(@ref) == 1
        assert StubMerger.last_merge() == {@ref, @head}, "merged exactly the ruled head"
        assert StubMerger.get_count(@ref) >= 3, "did not merge before CI went green"

        assert_receive {:event, %{topic: "review_gate", ruling_event: "merged"} = merged}
        assert merged.task_id == task.id
        assert merged.head_sha == @head
      end
    end

    test "send_back and reject do not resume the ticket", _ctx do
      ws = workspace(%{"auto_merge" => true})
      task = parked_ticket(ws)

      rule(task, :send_back)
      rule(task, :reject)

      assert ticket(task.id).state == :active
      assert Watchdog.whereis(task.id) == nil
      assert StubMerger.merge_count(@ref) == 0
    end

    test "a ticket that was never parked by the gate is left alone", _ctx do
      ws = workspace(%{"auto_merge" => true})
      {:ok, task} = Ash.create(Issue, %{title: "bare", workspace_id: ws.id})
      task = put_state!(task, :active)

      rule(task, :accept_as_is)

      assert ticket(task.id).state == :active
      assert Watchdog.whereis(task.id) == nil
    end

    test "auto_merge off stops at ready-to-merge with an attention cause", _ctx do
      ws = workspace(%{"auto_merge" => false})
      task = parked_ticket(ws)
      StubMerger.next_open_ref(@ref)
      StubMerger.queue_get(@ref, [green()])

      rule(task, :accept_as_is)

      wait_until(fn -> ticket(task.id).attention_cause == :awaiting_manual_merge end)

      assert ticket(task.id).state == :merging
      assert StubMerger.merge_count(@ref) == 0

      assert Enum.any?(
               Message.inbox(Message.coordinator_ref(), workspace_id: ws.id),
               &(&1.task_ref == task.id and &1.kind == :escalation)
             )
    end

    test "a Merging ticket whose Watchdog is gone is watched again", _ctx do
      ws = workspace(%{"auto_merge" => true})
      task = parked_ticket(ws)
      task = merging(task)
      StubMerger.queue_get(@ref, [green()])
      assert Watchdog.whereis(task.id) == nil

      rule(task, :amend)

      wait_until(fn -> ticket(task.id).state == :closed end)
      assert StubMerger.last_merge() == {@ref, @head}
    end

    test "the ruled head is stamped as the reviewed baseline the merge is guarded on", _ctx do
      ws = workspace(%{"auto_merge" => false})
      task = parked_ticket(ws)
      StubMerger.next_open_ref(@ref)
      StubMerger.queue_get(@ref, [green()])

      rule(task, :accept_as_is)

      assert ticket(task.id).last_reviewed_sha == @head
    end
  end

  describe "CI failing on the ruled head" do
    test "takes the normal fix-pass path, never merges, and says so", _ctx do
      ws = workspace(%{"auto_merge" => true})
      task = parked_ticket(ws)
      task = merging(task)
      subscribe(ws)

      StubMerger.queue_get(@ref, [
        green(%{ci_clean: false, pipeline: :failed, block_reason: :ci_failed})
      ])

      Arbiter.ReviewGate.RulingResume.resume(rule_record(task, :accept_as_is),
        watch_opts: [fix_pass_dispatcher: StubFixPassDispatcher]
      )

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)

      assert StubMerger.merge_count(@ref) == 0
      assert_receive {:event, %{topic: "review_gate", ruling_event: "ci_failed"} = event}
      assert event.task_id == task.id
      assert event.head_sha == @head
    end
  end

  @head2 "a1b2c3d4eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

  @ruled_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -10,6 +10,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  # The same net change after a rebase: hunk offsets and blob hashes moved.
  @rebased_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  @pushed_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,8 @@ defmodule A do
     def run do
       :ok
  +    :extra
  +    :something_nobody_ruled_on
     end
   end
  """

  describe "the head changes after the ruling" do
    test "a push is not merged: no review round, the coordinator is told both SHAs", _ctx do
      ws = workspace(%{"auto_merge" => true})
      task = merging(parked_ticket(ws))
      subscribe(ws)

      StubMerger.set_diff(@ref, @head, @ruled_diff)
      StubMerger.set_diff(@ref, @head2, @pushed_diff)
      StubMerger.queue_get(@ref, [green(%{head_sha: @head2})])
      Arbiter.Test.StubAutoResumeDispatcher.reset()
      Watchdog.subscribe(task.id)

      rule_with(task, :accept_as_is,
        watch_opts: [auto_resume_dispatcher: Arbiter.Test.StubAutoResumeDispatcher]
      )

      assert_receive {:watchdog, _, {:unreviewed_head, @head2}}, 2_000

      assert StubMerger.merge_count(@ref) == 0
      assert Arbiter.Test.StubAutoResumeDispatcher.resume_count() == 0

      assert_receive {:event, %{topic: "review_gate", ruling_event: "head_changed"} = event}
      assert event.message =~ "#{@head} -> #{@head2}"

      assert Enum.any?(
               Message.inbox(Message.coordinator_ref(), workspace_id: ws.id),
               &(&1.task_ref == task.id and &1.subject =~ "#{@head} -> #{@head2}")
             )
    end

    test "a pure rebase with an identical net diff is covered, and the event says how",
         _ctx do
      ws = workspace(%{"auto_merge" => true})
      task = merging(parked_ticket(ws))
      subscribe(ws)

      StubMerger.set_diff(@ref, @head, @ruled_diff)
      StubMerger.set_diff(@ref, @head2, @rebased_diff)
      StubMerger.queue_get(@ref, [green(%{head_sha: @head2})])

      rule(task, :amend)

      wait_until(fn -> ticket(task.id).state == :closed end)
      assert StubMerger.last_merge() == {@ref, @head2}

      assert_receive {:event, %{topic: "review_gate", ruling_event: "carried"} = event}
      assert event.message =~ "patch-id"
      assert event.message =~ "#{@head} -> #{@head2}"

      assert [_ruling, carried] = Resolutions.list(task.id)
      assert carried.actor == "system:ruling-resume"
      assert carried.head_sha == @head2
    end
  end

  describe "a worker is resident" do
    test "the ruling is recorded and the ticket is left to it", _ctx do
      ws = workspace(%{"auto_merge" => true})
      task = parked_ticket(ws)

      {:ok, pid} =
        Arbiter.Worker.start(task_id: task.id, repo: "rr/repo", workspace_id: ws.id)

      on_exit(fn -> stop(pid) end)

      rule(task, :accept_as_is)

      assert ticket(task.id).state == :active
      assert Watchdog.whereis(task.id) == nil
      assert StubMerger.merge_count(@ref) == 0
    end
  end

  # `rule/3` goes through `Resolutions.record/1`, which already resumes; this
  # reads the row back so a test can drive `resume/2` with its own watch opts.
  defp rule_record(task, decision) do
    Application.put_env(:arbiter, :ruling_resume, :off)
    on_exit(fn -> Application.put_env(:arbiter, :ruling_resume, :sync) end)
    rule(task, decision)
  end

  defp rule_with(task, decision, resume_opts) do
    resolution = rule_record(task, decision)
    Arbiter.ReviewGate.RulingResume.resume(resolution, resume_opts)
  end
end
