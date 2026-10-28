defmodule Arbiter.Workflows.MergeQueueHeadSyncTest do
  @moduledoc """
  bd-d4m8qf / #1063 — the merge queue syncs only the front of each target's
  queue (a coalesced merge train) instead of every approved PR on each move of
  the target.

  Driven through the real GitHub adapter against a stub forge (`forge/2`): an
  Agent models the target branches (`main`, `release`), each moving on every
  merge into it or on a merge from outside the queue (`move_target/2`), and,
  per PR, the target revision its branch contains and the state of its CI. An
  update-branch brings a PR's branch up to its target and starts CI on it.
  Every sync and merge is logged in order, so a test can assert exactly which
  PR was synced and merged, and when.

  Two forge shapes, matching the two sync paths the queue has:

    * `up_to_date: true` — the forge enforces up-to-date branches and reports a
      stale PR `behind` (GitHub "require branches to be up to date", GitLab
      fast-forward). The queue syncs on the forge's `:behind_base`.
    * `up_to_date: false` — the forge never calls a branch behind (GitLab Free,
      `merge_method: merge`, vstim). The queue's merge-time freshness check
      (`merge.require_up_to_date`, `Arbiter.Worker.MergeFreshness`) finds the
      stale head and syncs it. Heads keep their SHA across a sync here, so the
      reviewed-SHA guard stays out of the way; the freshness probe answers
      from the model instead. (So a head that goes stale again after its sync
      looks to the gate like one whose sync has not landed yet, and is waited
      on rather than re-synced at once.)
  """

  # async: false — the DataCase sandbox and the freshness probe are shared with
  # the queue's own process.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  # Poll and sync failures, and the coverage shadow on tasks with no coverage
  # rows, log warnings that say nothing about what these tests check.
  @moduletag :capture_log

  alias Arbiter.Mergers.Github
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue
  alias Ecto.Adapters.SQL.Sandbox

  defmodule FakeWorktree do
    @moduledoc false
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
    def rebase_onto_origin(_path, _branch), do: {:ok, :up_to_date}
  end

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123"
      }
    }
  }

  setup do
    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "hs#{System.unique_integer([:positive])}",
        config: @ws_github
      })

    on_exit(fn ->
      Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h -> {:ok, 0} end)
    end)

    %{workspace: workspace}
  end

  # ---- the stub forge -------------------------------------------------------

  # `prs` is `[{number, overrides}]`; each PR defaults to approved, CI green and
  # targeting `main`, its branch at target revision 0 while every target sits at
  # revision 1 — every PR starts one merge behind.
  defp forge(prs, opts) do
    up_to_date? = Keyword.fetch!(opts, :up_to_date)

    model = %{
      up_to_date?: up_to_date?,
      targets: %{"main" => 1, "release" => 1},
      prs:
        Map.new(prs, fn {n, o} ->
          {n, Map.merge(%{base: "main", at: 0, ci: :green, approved: true}, o)}
        end),
      log: []
    }

    {:ok, agent} = Agent.start_link(fn -> model end)

    Req.Test.stub(Github.HTTP, &handle(agent, &1))

    Application.put_env(:arbiter, :merge_freshness_probe, fn _repo, _base, head ->
      {:ok, Agent.get(agent, &behind_by(&1, pr_of(head)))}
    end)

    agent
  end

  defp behind_by(model, n), do: max(model.targets[model.prs[n].base] - model.prs[n].at, 0)

  defp handle(agent, conn) do
    case {conn.method, endpoint(conn.request_path)} do
      {"GET", {:pull, n}} ->
        pull(agent, conn, n)

      {"GET", {:reviews, n}} ->
        Req.Test.json(conn, [%{"state" => review(pr(agent, n))}])

      {"GET", {:check_runs, n}} ->
        Req.Test.json(conn, %{"check_runs" => check_runs(pr(agent, n))})

      {"PUT", {:update_branch, n}} ->
        sync(agent, conn, n)

      {"PUT", {:merge, n}} ->
        merge(agent, conn, n)

      _ ->
        unexpected(conn)
    end
  end

  # The endpoints the queue calls, with the PR they are about. A head SHA names
  # its PR too (`head_sha/2`). Anything else is answered 500.
  defp endpoint(path) do
    [
      pull: ~r{/pulls/(\d+)$},
      reviews: ~r{/pulls/(\d+)/reviews$},
      check_runs: ~r{/commits/pr(\d+)[^/]*/check-runs$},
      update_branch: ~r{/pulls/(\d+)/update-branch$},
      merge: ~r{/pulls/(\d+)/merge$}
    ]
    |> Enum.find_value(:unknown, fn {endpoint, pattern} ->
      with [_, n] <- Regex.run(pattern, path), do: {endpoint, String.to_integer(n)}
    end)
  end

  # `poll: :fail` on a PR makes its GET fail.
  defp pull(agent, conn, n) do
    if Map.get(pr(agent, n), :poll) == :fail,
      do: unexpected(conn),
      else: Req.Test.json(conn, pr_payload(Agent.get(agent, & &1), n))
  end

  defp review(%{approved: true}), do: "APPROVED"
  defp review(_pr), do: "COMMENTED"

  defp merge(agent, conn, n) do
    Agent.update(agent, fn m ->
      %{m | targets: Map.update!(m.targets, m.prs[n].base, &(&1 + 1)), log: [{:merge, n} | m.log]}
    end)

    Req.Test.json(conn, %{"merged" => true, "sha" => "merge-#{n}"})
  end

  defp unexpected(conn),
    do: conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})

  # `sync: :fail` on a PR makes its update-branch fail every time; `sync: :noop`
  # has the forge accept it (202) and never apply it.
  defp sync(agent, conn, n) do
    case Map.get(pr(agent, n), :sync) do
      :fail ->
        log(agent, {:sync_failed, n})
        unexpected(conn)

      :noop ->
        log(agent, {:sync_accepted, n})
        accepted(conn)

      _ ->
        Agent.update(agent, fn m ->
          %{
            m
            | prs: Map.update!(m.prs, n, &%{&1 | at: m.targets[&1.base], ci: :running}),
              log: [{:sync, n} | m.log]
          }
        end)

        accepted(conn)
    end
  end

  defp log(agent, event), do: Agent.update(agent, fn m -> %{m | log: [event | m.log]} end)

  defp accepted(conn),
    do: conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"message" => "Updating"})

  # `state: "closed"` on a PR closes it on the forge.
  defp pr_payload(model, n) do
    pr = model.prs[n]

    state =
      cond do
        Map.get(pr, :state) == "closed" -> "unknown"
        model.up_to_date? and behind_by(model, n) > 0 -> "behind"
        pr.ci == :green and pr.approved -> "clean"
        true -> "blocked"
      end

    %{
      "number" => n,
      "state" => Map.get(pr, :state, "open"),
      "mergeable" => true,
      "mergeStateStatus" => state,
      "head" => %{"sha" => head_sha(model, n), "ref" => "feature-#{n}"},
      "base" => %{"ref" => pr.base},
      "html_url" => "https://github.com/octo/widget/pull/#{n}"
    }
  end

  # A sync moves the head on the up-to-date forge (update-branch writes a merge
  # commit). On the other it keeps the SHA — see the moduledoc.
  defp head_sha(%{up_to_date?: true, prs: prs}, n), do: "pr#{n}at#{prs[n].at}"
  defp head_sha(_model, n), do: "pr#{n}"

  defp check_runs(%{ci: :green}), do: [run("completed", "success")]
  defp check_runs(%{ci: :running}), do: [run("in_progress", nil)]
  defp check_runs(%{ci: :failed}), do: [run("completed", "failure")]

  defp run(status, conclusion),
    do: %{"id" => 1, "name" => "ci", "status" => status, "conclusion" => conclusion}

  defp pr_of("pr" <> sha), do: sha |> Integer.parse() |> elem(0)

  defp pr(agent, n), do: Agent.get(agent, & &1.prs[n])

  # Every running pipeline finishes green.
  defp finish_ci(agent) do
    Agent.update(agent, fn m ->
      %{m | prs: Map.new(m.prs, fn {n, p} -> {n, %{p | ci: done(p.ci)}} end)}
    end)
  end

  defp done(:running), do: :green
  defp done(ci), do: ci

  # A merge into `base` from outside the queue.
  defp move_target(agent, base),
    do: Agent.update(agent, fn m -> %{m | targets: Map.update!(m.targets, base, &(&1 + 1))} end)

  defp set_pr(agent, n, changes),
    do:
      Agent.update(agent, fn m -> %{m | prs: Map.update!(m.prs, n, &Map.merge(&1, changes))} end)

  defp events(agent), do: agent |> Agent.get(& &1.log) |> Enum.reverse()
  defp syncs(agent), do: for({:sync, n} <- events(agent), do: n)
  defp merges(agent), do: for({:merge, n} <- events(agent), do: n)

  # ---- queue helpers --------------------------------------------------------

  defp start_queue(workspace) do
    name = :"merge_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        name: name,
        worktree_module: FakeWorktree
      )

    Req.Test.allow(Github.HTTP, self(), pid)
    Sandbox.allow(Arbiter.Repo, self(), pid)
    name
  end

  # A task already carrying its open PR, so the queue adopts it; enqueued in the
  # order given, which is the queue order within one priority.
  defp enqueue(name, workspace, n, opts \\ []) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "pr #{n}",
        workspace_id: workspace.id,
        priority: Keyword.get(opts, :priority, 2)
      })

    {:ok, task} =
      Ash.update(
        task,
        %{
          pr_ref: "##{n}",
          target_branch: Keyword.get(opts, :target_branch),
          last_reviewed_sha: Keyword.get(opts, :last_reviewed_sha)
        },
        action: :update
      )

    :ok = MergeQueue.enqueue(name, task.id)
    task
  end

  defp item(name, task), do: Enum.find(MergeQueue.state(name).items, &(&1.task_id == task.id))

  defp tick(name, times \\ 1), do: for(_ <- 1..times, do: :ok = MergeQueue.tick(name))

  # Tick until nothing is left in the queue, with CI taking `ci_ticks` ticks to
  # finish — long enough that the queue has to decide what to do with the
  # followers while the head's pipeline is still running.
  defp drain(name, agent, ci_ticks \\ 3) do
    Enum.reduce_while(1..60, nil, fn n, _ ->
      tick(name)
      if rem(n, ci_ticks) == 0, do: finish_ci(agent)
      if MergeQueue.state(name).items == [], do: {:halt, n}, else: {:cont, n}
    end)
  end

  # ---- only the queue head is synced -----------------------------------------

  describe "a forge that reports stale branches behind (:behind_base)" do
    test "only the queue head is synced; followers wait for it and spend no sync budget",
         %{workspace: ws} do
      agent = forge([{301, %{}}, {302, %{}}, {303, %{}}], up_to_date: true)
      name = start_queue(ws)
      head = enqueue(name, ws, 301)
      second = enqueue(name, ws, 302)
      third = enqueue(name, ws, 303)

      tick(name)
      assert syncs(agent) == [301]

      # The head's sync landed; its CI runs for a while. The followers are still
      # behind the target and stay unsynced the whole time.
      tick(name, 4)
      assert syncs(agent) == [301]

      # main moves again under all three (a merge from outside the queue): the
      # head is synced again, and only the head.
      move_target(agent, "main")
      tick(name, 2)
      assert syncs(agent) == [301, 301]

      assert item(name, head).waiting_for_head == nil

      for follower <- [second, third] do
        waiting = item(name, follower)
        assert waiting.waiting_for_head == head.id
        assert waiting.freshness_syncs == 0
      end
    end

    test "when the head merges, the next PR is synced, CI'd and merged, in queue order",
         %{workspace: ws} do
      agent = forge([{311, %{}}, {312, %{}}, {313, %{}}], up_to_date: true)
      name = start_queue(ws)
      tasks = for n <- [311, 312, 313], do: enqueue(name, ws, n)

      drain(name, agent)

      assert events(agent) == [
               {:sync, 311},
               {:merge, 311},
               {:sync, 312},
               {:merge, 312},
               {:sync, 313},
               {:merge, 313}
             ]

      assert Enum.all?(tasks, &(Ash.get!(Issue, &1.id).state == :closed))
    end
  end

  describe "a forge that never calls a branch behind (GitLab Free, merge_method merge)" do
    test "only the queue head is freshness-synced; followers spend none of their budget",
         %{workspace: ws} do
      agent = forge([{321, %{}}, {322, %{}}, {323, %{}}], up_to_date: false)
      name = start_queue(ws)
      head = enqueue(name, ws, 321)
      followers = [enqueue(name, ws, 322), enqueue(name, ws, 323)]

      tick(name)
      assert syncs(agent) == [321]

      # The head's CI on the synced head is still running: the followers are
      # mergeable on the forge and stale, but not synced.
      tick(name, 4)
      assert syncs(agent) == [321]

      # main moves under all three while the head's CI runs, and the CI goes
      # green: whatever the head does about it, the followers are not synced.
      move_target(agent, "main")
      tick(name, 2)
      finish_ci(agent)
      tick(name, 2)
      assert Enum.uniq(syncs(agent)) == [321]

      for follower <- followers do
        waiting = item(name, follower)
        assert waiting.waiting_for_head == head.id
        assert waiting.freshness_syncs == 0
      end
    end

    test "the next PR is synced only once the head has merged, and they merge in order",
         %{workspace: ws} do
      agent = forge([{331, %{}}, {332, %{}}, {333, %{}}], up_to_date: false)
      name = start_queue(ws)
      for n <- [331, 332, 333], do: enqueue(name, ws, n)

      drain(name, agent)

      assert events(agent) == [
               {:sync, 331},
               {:merge, 331},
               {:sync, 332},
               {:merge, 332},
               {:sync, 333},
               {:merge, 333}
             ]
    end
  end

  # ---- what a follower records ----------------------------------------------

  describe "waiting for the queue head" do
    # The suite's Logger floor is :warning, and capture_log's :level option
    # can't lower it — raise just this module to :info for these tests.
    setup do
      Logger.put_module_level(MergeQueue, :info)
      on_exit(fn -> Logger.delete_module_level(MergeQueue) end)
    end

    test "is logged once per follower when it starts waiting, not on every tick",
         %{workspace: ws} do
      forge([{391, %{}}, {392, %{}}, {393, %{}}], up_to_date: true)
      name = start_queue(ws)
      head = enqueue(name, ws, 391)
      followers = [enqueue(name, ws, 392), enqueue(name, ws, 393)]

      log = capture_log([level: :info], fn -> tick(name, 4) end)

      assert occurrences(log, "task=#{head.id} is the queue head") == 1

      for follower <- followers do
        assert occurrences(
                 log,
                 "task=#{follower.id} is waiting for queue head task=#{head.id}"
               ) == 1
      end
    end

    test "shows in the queue view", %{workspace: ws} do
      forge([{394, %{}}, {395, %{}}], up_to_date: true)
      name = start_queue(ws)
      head = enqueue(name, ws, 394)
      follower = enqueue(name, ws, 395)

      tick(name)

      assert [front, back] = MergeQueue.queue_view(name)
      assert %{task_id: head_id, queue_head: true, waiting_for_head: nil} = front
      assert head_id == head.id
      assert %{task_id: follower_id, queue_head: false, waiting_for_head: ^head_id} = back
      assert follower_id == follower.id
    end
  end

  defp occurrences(log, text), do: length(String.split(log, text)) - 1

  describe "items enqueued before the head fields existed" do
    # A queue that keeps running across a code reload holds items built by the
    # previous version of `new_item/3`.
    test "are driven and shown without crashing the queue", %{workspace: ws} do
      agent = forge([{397, %{}}, {398, %{}}], up_to_date: true)
      name = start_queue(ws)
      head = enqueue(name, ws, 397)
      enqueue(name, ws, 398)

      :sys.replace_state(name, fn state ->
        old = [:waiting_for_head, :queue_head, :last_block_reason, :poll_failed?]
        %{state | items: Enum.map(state.items, &Map.drop(&1, old))}
      end)

      assert [%{queue_head: false, waiting_for_head: nil}, _] = MergeQueue.queue_view(name)

      tick(name)
      assert syncs(agent) == [397]
      assert [%{task_id: head_id, queue_head: true}, _] = MergeQueue.queue_view(name)
      assert head_id == head.id
    end
  end

  # ---- one queue head per target branch -------------------------------------

  describe "queue heads are per target branch" do
    test "a PR into another branch is not held behind the head of main", %{workspace: ws} do
      agent =
        forge([{351, %{}}, {352, %{}}, {353, %{base: "release"}}], up_to_date: true)

      name = start_queue(ws)
      main_head = enqueue(name, ws, 351)
      main_follower = enqueue(name, ws, 352)
      release_head = enqueue(name, ws, 353, target_branch: "release")

      tick(name)
      assert Enum.sort(syncs(agent)) == [351, 353]

      assert item(name, main_follower).waiting_for_head == main_head.id
      assert item(name, release_head).waiting_for_head == nil

      # Both heads are green. The queue still merges at most one PR a tick (the
      # front of the queue first), so the other one merges on the next tick; then
      # only main's follower is left.
      finish_ci(agent)
      tick(name)
      assert merges(agent) == [351]
      tick(name)
      assert merges(agent) == [351, 353]
      assert [%{task_id: follower_id}] = MergeQueue.state(name).items
      assert follower_id == main_follower.id
    end
  end

  # ---- the head keeps its place, unless it cannot progress ------------------

  describe "the queue head's place" do
    test "a higher-priority PR approved while the head is in flight waits for it",
         %{workspace: ws} do
      agent = forge([{361, %{}}, {362, %{approved: false}}], up_to_date: true)
      name = start_queue(ws)
      head = enqueue(name, ws, 361, priority: 3)
      urgent = enqueue(name, ws, 362, priority: 1)

      # Not approved yet: the P1 PR is not in the train, so the P3 one leads.
      tick(name)
      assert syncs(agent) == [361]

      # Approved while the head's CI runs. It is next in line, but the head keeps
      # its place: re-syncing it after the P1 merged would waste its pipeline.
      set_pr(agent, 362, %{approved: true})
      tick(name, 2)
      assert syncs(agent) == [361]
      assert item(name, urgent).waiting_for_head == head.id

      finish_ci(agent)
      tick(name, 2)
      assert events(agent) == [{:sync, 361}, {:merge, 361}, {:sync, 362}]
    end

    test "a head whose CI failed gives up its place after a bounded wait", %{workspace: ws} do
      agent = forge([{371, %{}}, {372, %{}}, {373, %{}}], up_to_date: true)
      name = start_queue(ws)
      red = enqueue(name, ws, 371)
      next = enqueue(name, ws, 372)
      last = enqueue(name, ws, 373)

      tick(name)
      assert syncs(agent) == [371]

      # Red on the synced head. A re-run can still turn it around, so the head
      # holds its place for a few ticks...
      set_pr(agent, 371, %{ci: :failed})
      tick(name, MergeQueue.head_stall_grace_ticks())
      assert syncs(agent) == [371]

      # ...then the next PR takes over. The red one is out of the train (it waits
      # on a fix, not on the head) and is not synced again.
      tick(name)
      assert syncs(agent) == [371, 372]
      assert item(name, red).waiting_for_head == nil
      assert item(name, last).waiting_for_head == next.id

      # Fixed (a new push, CI running again): it rejoins as a follower and does
      # not take the place back.
      set_pr(agent, 371, %{ci: :running})
      tick(name, 2)
      assert syncs(agent) == [371, 372]
      assert item(name, red).waiting_for_head == next.id
    end

    test "a red head whose CI is re-run before the wait runs out keeps its place",
         %{workspace: ws} do
      agent = forge([{375, %{}}, {376, %{}}], up_to_date: true)
      name = start_queue(ws)
      head = enqueue(name, ws, 375)
      follower = enqueue(name, ws, 376)

      tick(name)
      set_pr(agent, 375, %{ci: :failed})
      tick(name, MergeQueue.head_stall_grace_ticks())

      # Re-run on the same head: CI is running again, so the head is progressing.
      set_pr(agent, 375, %{ci: :running})
      tick(name, 2)
      assert syncs(agent) == [375]
      assert item(name, follower).waiting_for_head == head.id
    end

    test "a head whose update-branch keeps failing hands its place on after a bounded wait",
         %{workspace: ws} do
      agent = forge([{381, %{sync: :fail}}, {382, %{}}], up_to_date: true)
      name = start_queue(ws)
      failing = enqueue(name, ws, 381)
      next = enqueue(name, ws, 382)
      grace = MergeQueue.head_stall_grace_ticks()

      # One attempt per tick, each refused by the forge: the first, then one on
      # each tick of the wait.
      tick(name, 1 + grace)
      assert events(agent) == List.duplicate({:sync_failed, 381}, 1 + grace)

      tick(name)
      assert syncs(agent) == [382]
      assert item(name, failing).waiting_for_head == next.id
    end

    test "a head the freshness gate parked hands its place on at once", %{workspace: ws} do
      agent = forge([{383, %{sync: :fail}}, {384, %{}}], up_to_date: false)
      name = start_queue(ws)
      parked = enqueue(name, ws, 383)
      enqueue(name, ws, 384)

      # The sync is refused, so the gate parks the head on its SHA and pages once.
      tick(name)
      assert events(agent) == [{:sync_failed, 383}]

      tick(name)
      assert events(agent) == [{:sync_failed, 383}, {:sync, 384}]
      assert item(name, parked).waiting_for_head == nil
    end

    test "a poll that fails right after the head's sync does not cost it its place",
         %{workspace: ws} do
      agent = forge([{385, %{}}, {386, %{}}], up_to_date: false)
      name = start_queue(ws)
      head = enqueue(name, ws, 385)
      follower = enqueue(name, ws, 386)

      tick(name)
      assert syncs(agent) == [385]

      set_pr(agent, 385, %{poll: :fail})
      tick(name)
      assert syncs(agent) == [385]
      assert item(name, follower).waiting_for_head == head.id
    end

    test "a head whose polls keep failing hands its place on after a bounded wait",
         %{workspace: ws} do
      agent = forge([{386, %{}}, {387, %{}}], up_to_date: true)
      name = start_queue(ws)
      enqueue(name, ws, 386)
      next = enqueue(name, ws, 387)

      tick(name)
      assert syncs(agent) == [386]

      # The forge stops answering for it (the PR deleted, say).
      set_pr(agent, 386, %{poll: :fail})
      tick(name, MergeQueue.head_stall_grace_ticks())
      assert syncs(agent) == [386]

      tick(name)
      assert syncs(agent) == [386, 387]
      assert item(name, next).waiting_for_head == nil
    end

    test "a head whose update-branch is accepted but never applied hands its place on",
         %{workspace: ws} do
      agent = forge([{388, %{sync: :noop}}, {389, %{}}], up_to_date: true)
      name = start_queue(ws)
      noop = enqueue(name, ws, 388)
      next = enqueue(name, ws, 389)
      grace = MergeQueue.head_stall_grace_ticks()

      # Still behind on the very head it was synced from, every tick.
      tick(name, 1 + grace)
      assert events(agent) == List.duplicate({:sync_accepted, 388}, 1 + grace)

      tick(name)
      assert syncs(agent) == [389]
      assert item(name, noop).waiting_for_head == next.id
    end

    test "a head whose PR is closed on the forge hands its place on", %{workspace: ws} do
      agent = forge([{390, %{}}, {391, %{}}], up_to_date: true)
      name = start_queue(ws)
      enqueue(name, ws, 390)
      enqueue(name, ws, 391)

      tick(name)
      set_pr(agent, 390, %{state: "closed"})
      tick(name, MergeQueue.head_stall_grace_ticks())
      assert syncs(agent) == [390]

      tick(name)
      assert syncs(agent) == [390, 391]
    end

    test "a head whose CI never finishes hands its place on after a long wait",
         %{workspace: ws} do
      agent = forge([{392, %{}}, {393, %{}}], up_to_date: true)
      name = start_queue(ws)
      pending = enqueue(name, ws, 392)
      next = enqueue(name, ws, 393)

      # Synced; its pipeline starts and never ends. A long pipeline has to be
      # allowed to run, so this is a much longer wait than a stall's.
      tick(name)
      tick(name, MergeQueue.head_ci_wait_ticks())
      assert syncs(agent) == [392]

      tick(name)
      assert syncs(agent) == [392, 393]
      assert item(name, pending).waiting_for_head == next.id
    end

    test "a head its merge guards refuse does not hold back a PR ahead of it in queue order",
         %{workspace: ws} do
      agent = forge([{394, %{at: 1}}, {395, %{approved: false}}], up_to_date: true)
      name = start_queue(ws)

      # Reviewed at a commit the branch has since moved past: refused every tick
      # (M3), which leaves it ready and waiting on a reviewer.
      refused = enqueue(name, ws, 394, priority: 3, last_reviewed_sha: "reviewed-earlier")
      urgent = enqueue(name, ws, 395, priority: 1)

      tick(name, 2)
      assert events(agent) == []

      # The P1 is approved. A refused head has no sync or CI under way to protect,
      # so it keeps no place beyond its queue order: the P1 leads.
      set_pr(agent, 395, %{approved: true})
      tick(name)
      assert syncs(agent) == [395]
      assert item(name, refused).waiting_for_head == urgent.id

      finish_ci(agent)
      tick(name)
      assert events(agent) == [{:sync, 395}, {:merge, 395}]
    end

    test "the PR that takes over no longer shows the head it waited for", %{workspace: ws} do
      agent = forge([{396, %{}}, {397, %{}}], up_to_date: true)
      name = start_queue(ws)
      enqueue(name, ws, 396)
      next = enqueue(name, ws, 397)

      tick(name)
      finish_ci(agent)
      tick(name)
      assert events(agent) == [{:sync, 396}, {:merge, 396}]

      tick(name)
      assert syncs(agent) == [396, 397]

      assert [%{task_id: id, queue_head: true, waiting_for_head: nil}] =
               MergeQueue.queue_view(name)

      assert id == next.id
    end

    test "a PR parked on its head is synced when the forge calls it behind, lifting the park",
         %{workspace: ws} do
      agent = forge([{398, %{}}], up_to_date: true)
      name = start_queue(ws)
      task = enqueue(name, ws, 398)

      # Parked by the freshness gate on the head it is at (a sync from it failed
      # earlier). The forge now reports it behind: a sync moves the head, and a
      # park is only ever on one head.
      :sys.replace_state(name, fn state ->
        %{state | items: Enum.map(state.items, &%{&1 | freshness_parked_head: "pr398at0"})}
      end)

      tick(name)
      assert syncs(agent) == [398]

      finish_ci(agent)
      tick(name)
      assert merges(agent) == [398]
      assert Ash.get!(Issue, task.id).state == :closed
    end
  end

  # ---- throughput with one approved PR is unchanged -------------------------

  describe "a single approved PR" do
    # Characterisation: these hold before and after head-only sync. A lone PR is
    # its own queue head, so it is synced, CI'd and merged on the same ticks.
    for up_to_date <- [true, false] do
      test "behind its target: one sync, merged on the second tick (up_to_date: #{up_to_date})",
           %{workspace: ws} do
        agent = forge([{341, %{}}], up_to_date: unquote(up_to_date))
        name = start_queue(ws)
        task = enqueue(name, ws, 341)

        tick(name)
        assert events(agent) == [{:sync, 341}]

        finish_ci(agent)
        tick(name)
        assert events(agent) == [{:sync, 341}, {:merge, 341}]
        assert Ash.get!(Issue, task.id).state == :closed
      end

      test "already current: merged on the first tick, never synced (up_to_date: #{up_to_date})",
           %{workspace: ws} do
        agent = forge([{342, %{at: 1}}], up_to_date: unquote(up_to_date))
        name = start_queue(ws)
        enqueue(name, ws, 342)

        tick(name)
        assert events(agent) == [{:merge, 342}]
      end
    end
  end
end
