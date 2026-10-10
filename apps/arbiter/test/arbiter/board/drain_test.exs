defmodule Arbiter.Board.DrainTest do
  @moduledoc """
  bd-9fgg04 / #1903: a paused scheduler must not look idle while it is still
  draining. `Drain.status/1` is the one definition of running / draining /
  quiescent that every surface reads.

  The load-bearing tests spawn real non-scheduler workers through their
  production entry points — `FixPassDispatcher.dispatch/1` and
  `ConflictResolver.resolve/1` (with `start_claude: false`, their documented
  test escape) — while the autopilot is paused, and assert both that the spawn
  still happens (a pause is not a freeze) and that the state is NOT quiescent.
  """

  # async: false — spawns workers under the global Arbiter.Worker.Supervisor and
  # flips :worktree_root / :repo_paths app env.
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Drain
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Workflows.MergeQueue.ConflictResolver
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  defp board(paused?, promote \\ nil) do
    %{
      ready: [],
      backlog: [],
      blocked: [],
      in_progress: [],
      merging: [],
      verifying: [],
      closed_today: [],
      attention: [],
      promote: promote,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: paused?,
      now: DateTime.utc_now()
    }
  end

  defp start_autopilot!(opts) do
    defaults = [
      name: nil,
      interval_ms: :never,
      topics: [],
      snapshot: fn o -> board(o[:paused]) end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end

  # A private, empty stand-in for Arbiter.Worker.Supervisor, so a quiescence
  # assertion can't be tripped by another test's leftover worker.
  defp empty_supervisor! do
    name = :"drain_test_sup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: name})
    name
  end

  describe "status/1 — the three states" do
    test "running: the autopilot is not paused" do
      ap = start_autopilot!(paused: false)

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert status.state == :running
      assert status.paused == false
      refute status.safe_to_restart
    end

    test "quiescent: paused, and nothing of any kind is live" do
      ap = start_autopilot!(paused: true)

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert status.state == :quiescent
      assert status.paused == true
      assert status.safe_to_restart
      assert status.in_flight == []
      # bd-36ytcl: an idle worker is simply not in flight; there is no
      # separate `parked` list any more.
      refute Map.has_key?(status, :parked)
    end

    test "an unrecognised child of the worker supervisor is counted, not ignored (fail closed)" do
      ap = start_autopilot!(paused: true)
      sup = empty_supervisor!()
      {:ok, _pid} = DynamicSupervisor.start_child(sup, {Agent, fn -> nil end})

      status = Drain.status(autopilot: ap, supervisor: sup)

      assert status.state == :draining
      refute status.safe_to_restart
      assert [%{kind: :unclassified}] = status.in_flight
    end

    test "an autopilot promotion still in flight when the pause lands keeps it draining" do
      test_pid = self()

      # Tracks itself exactly as `Dispatch.dispatch/2` does, so the promotion
      # must still be listed once, not twice.
      dispatch = fn id ->
        Drain.track(:dispatch_pending, %{task_id: id}, fn ->
          send(test_pid, {:dispatching, id, self()})

          receive do
            :release -> {:ok, id}
          end
        end)
      end

      ap =
        start_autopilot!(
          paused: false,
          dispatch: dispatch,
          snapshot: fn o -> board(o[:paused], "bd-promo1") end
        )

      tick = Task.async(fn -> Autopilot.tick(ap, 10_000) end)
      assert_receive {:dispatching, "bd-promo1", dispatcher}, 5_000
      :ok = Autopilot.pause(ap, "test")

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert status.state == :draining
      assert [%{task_id: "bd-promo1", kind: :board_promotion}] = status.in_flight

      send(dispatcher, :release)
      Task.await(tick, 10_000)

      assert Drain.status(autopilot: ap, supervisor: empty_supervisor!()).state == :quiescent
    end
  end

  # bd-b2iigy: a resume waiting on the primary's own cap is visible, not silent.
  describe "resumes held for local capacity" do
    test "are listed, in the order they will resume, and do not make the scheduler busy" do
      ap = start_autopilot!(paused: true)

      :ok = Autopilot.defer_resume(ap, "bd-held-1", :resume, held_for: :local_capacity)
      :ok = Autopilot.defer_resume(ap, "bd-slot-1", :resume, [])
      :ok = Autopilot.defer_resume(ap, "bd-held-2", :resume_session, held_for: :local_capacity)

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert status.held_local_capacity == ["bd-held-1", "bd-held-2"]
      # A held resume is queued work, not a running agent: a paused scheduler
      # with only those is still quiescent (a restart re-resumes them).
      assert status.state == :quiescent

      assert %{held_local_capacity: held} = Drain.to_json(status)

      assert held == [
               %{task_id: "bd-held-1", reason: "held: local capacity"},
               %{task_id: "bd-held-2", reason: "held: local capacity"}
             ]
    end

    test "none are listed when none are held" do
      ap = start_autopilot!(paused: true)
      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())
      assert status.held_local_capacity == []
      assert Drain.to_json(status).held_local_capacity == []
    end
  end

  describe "track/3 — live work outside the worker supervisor" do
    test "an entry is in flight exactly while its function runs" do
      ap = start_autopilot!(paused: true)
      sup = empty_supervisor!()
      test_pid = self()

      runner =
        spawn_link(fn ->
          result =
            Drain.track(:external_review, %{detail: "github:o/r#7"}, fn ->
              send(test_pid, :running)

              receive do
                :release -> :reviewed
              end
            end)

          send(test_pid, {:returned, result})
        end)

      assert_receive :running

      status = Drain.status(autopilot: ap, supervisor: sup)
      assert status.state == :draining
      refute status.safe_to_restart

      assert [%{kind: :external_review, detail: "github:o/r#7", pid: ^runner} = entry] =
               status.in_flight

      assert %DateTime{} = entry.started_at

      send(runner, :release)
      assert_receive {:returned, :reviewed}

      assert Drain.status(autopilot: ap, supervisor: sup).state == :quiescent
    end

    test "an entry is dropped when its function raises" do
      ap = start_autopilot!(paused: true)

      assert_raise RuntimeError, fn ->
        Drain.track(:review_reply, %{task_id: "bd-raise"}, fn -> raise "boom" end)
      end

      assert Drain.status(autopilot: ap, supervisor: empty_supervisor!()).state == :quiescent
    end

    test "an entry is dropped when its process is killed mid-run" do
      ap = start_autopilot!(paused: true)
      test_pid = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Drain.track(:patrol_rereview, %{task_id: "bd-killed"}, fn ->
            send(test_pid, :running)

            receive do
              :never -> :ok
            end
          end)
        end)

      assert_receive :running
      sup = empty_supervisor!()
      assert [%{kind: :patrol_rereview}] = Drain.status(autopilot: ap, supervisor: sup).in_flight

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      # The Registry's (single) pid partition is linked to the caller and
      # cleans up on its :EXIT — sync on that process, not the Registry's
      # supervisor (which is what the bare registry name resolves to).
      _ = :sys.get_state(Module.concat(Drain.Registry, "PIDPartition0"))

      assert Drain.status(autopilot: ap, supervisor: sup).state == :quiescent
    end

    test "nested calls are separate entries" do
      ap = start_autopilot!(paused: true)
      sup = empty_supervisor!()

      kinds =
        Drain.track(:dispatch_pending, %{task_id: "bd-outer"}, fn ->
          Drain.track(:external_review, %{}, fn ->
            Drain.status(autopilot: ap, supervisor: sup).in_flight |> Enum.map(& &1.kind)
          end)
        end)

      assert Enum.sort(kinds) == [:dispatch_pending, :external_review]
    end

    test "a registry that is not running is read as empty, and the work still runs" do
      ap = start_autopilot!(paused: true)

      status =
        Drain.status(autopilot: ap, supervisor: empty_supervisor!(), registry: :no_such_registry)

      assert status.state == :quiescent
    end
  end

  describe "status/1 — worker classification" do
    test "a parked or terminal worker is not in flight; an active one is, with its kind" do
      ap = start_autopilot!(paused: true)
      id = "bd-drainkind#{System.unique_integer([:positive])}"

      {:ok, main} = Worker.start(task_id: id, repo: "r")
      on_exit(fn -> stop_quietly(main) end)

      {:ok, review} =
        Worker.start(
          task_id: id,
          registry_key: id <> "#review",
          repo: "r",
          meta: %{role: :reviewer},
          allow_concurrent_task_worker: true
        )

      on_exit(fn -> stop_quietly(review) end)

      mine = fn -> ap |> status_for(id) |> Enum.map(& &1.kind) |> Enum.sort() end
      assert mine.() == [:dispatch, :review_pass]

      # :idle → :completed is not a legal transition; run one step first.
      :ok = Worker.advance(main, :work)
      :ok = Worker.complete(main)
      assert mine.() == [:review_pass]
    end
  end

  describe "non-scheduler workers while paused (acceptance 4 + 7)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "drain-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)

      for args <- [
            ["init", "-q", "-b", "main", repo],
            ["-C", repo, "config", "user.email", "t@e.com"],
            ["-C", repo, "config", "user.name", "T"],
            ["-C", repo, "config", "commit.gpgsign", "false"]
          ] do
        {_, 0} = System.cmd("git", args)
      end

      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "drain-ws-#{System.unique_integer([:positive])}",
          prefix: "drn#{System.unique_integer([:positive])}"
        })

      {:ok, task} = Ash.create(Issue, %{title: "drain me", workspace_id: ws.id})
      {_, 0} = System.cmd("git", ["-C", repo, "branch", BranchNamer.derive(task)])

      ap = start_autopilot!(paused: true)
      %{ws: ws, task: task, repo: repo, ap: ap}
    end

    test "a CI fix_pass still dispatches while paused, and the state is NOT quiescent",
         %{ws: ws, task: task, repo: repo, ap: ap} do
      assert Autopilot.paused?(ap)

      assert {:ok, %{worker_pid: pid}} =
               FixPassDispatcher.dispatch(%{
                 task_id: task.id,
                 workspace_id: ws.id,
                 repo_path: repo,
                 repo: "test/repo",
                 checks: [],
                 start_claude: false
               })

      on_exit(fn -> stop_quietly(pid) end)

      status = Drain.status(autopilot: ap)

      assert status.paused
      assert status.state == :draining
      refute status.safe_to_restart

      # bd-741sid: an ordinary run on the ticket, registered under its id and
      # classified by its role.
      assert [%{kind: :fix_pass, registry_key: key, pid: ^pid}] = status_for(ap, task.id)
      assert key == task.id
    end

    test "a MergeQueue conflict resolver still spawns while paused, and the state is NOT quiescent",
         %{ws: ws, task: task, repo: repo, ap: ap} do
      assert {:ok, %{worker_pid: pid}} =
               ConflictResolver.resolve(%{
                 task_id: task.id,
                 workspace_id: ws.id,
                 repo_path: repo,
                 repo: "test/repo",
                 start_claude: false
               })

      on_exit(fn -> stop_quietly(pid) end)

      status = Drain.status(autopilot: ap)

      assert status.state == :draining
      refute status.safe_to_restart
      assert [%{kind: :conflict_resolver, pid: ^pid}] = status_for(ap, task.id)
    end
  end

  # bd-asxw4e: `scheduler_status` reports the same slot count the board's
  # header does — the tickets In progress.
  describe "status/1 — slots" do
    test "counts the tickets In progress, the same rule as the board" do
      {:ok, ws} = Ash.create(Workspace, %{name: "drain-slots", prefix: "dsl"})

      tickets =
        for {title, state} <- [a: :active, b: :active, m: :merging, v: :verifying, q: :queued] do
          {:ok, issue} = Ash.create(Issue, %{title: "#{title}", workspace_id: ws.id})
          %{issue | state: state}
        end

      [a, b | _] = tickets
      ap = start_autopilot!(paused: true)

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!(), tickets: tickets)

      assert status.slots_used == 2
      assert status.slot_holders == [a.id, b.id]
      assert status.slots_used == Arbiter.Board.Snapshot.derive(%{issues: tickets}).slots_used

      assert %{slots_used: 2, slot_holders: [_, _]} = Drain.to_json(status)
    end

    test "reads the tickets In progress when not handed them" do
      {:ok, ws} = Ash.create(Workspace, %{name: "drain-slots-db", prefix: "dsd"})
      {:ok, issue} = Ash.create(Issue, %{title: "working", workspace_id: ws.id})
      {:ok, issue} = Issue.start_work(issue)
      ap = start_autopilot!(paused: true)

      status = Drain.status(autopilot: ap, supervisor: empty_supervisor!())

      assert issue.id in status.slot_holders
      assert status.slots_used == length(status.slot_holders)
    end
  end

  describe "to_json/1" do
    test "renders the state, the safe-to-restart verdict and each in-flight entry" do
      ap = start_autopilot!(paused: true)
      sup = empty_supervisor!()
      {:ok, _pid} = DynamicSupervisor.start_child(sup, {Agent, fn -> nil end})

      json = [autopilot: ap, supervisor: sup] |> Drain.status() |> Drain.to_json()

      assert %{
               state: "draining",
               paused: true,
               safe_to_restart: false,
               in_flight: [%{kind: "unclassified", task_id: nil, detail: nil}]
             } = json

      refute Map.has_key?(json, :parked)
      assert Jason.encode!(json)
    end

    # DC5 (bd-2c2a4g, design §9): the per-pool budgets ride the status, shadow-labelled.
    test "carries admission, budgets, machines, repos and fair_share" do
      ap = start_autopilot!(paused: false)
      sup = empty_supervisor!()

      view = %{
        admission: %{mode: "shadow", label: "shadow", decides: false, agreement: nil},
        pools: [%{account: "a1", pool: "claude", budget: 3, seats: 3, reason: "ceiling"}],
        machines: [%{id: "local", name: "local", cap: 6, live: 3, free: 3, state: "online"}],
        repos: [],
        fair_share: []
      }

      json =
        [autopilot: ap, supervisor: sup, capacity: view] |> Drain.status() |> Drain.to_json()

      assert json.admission == view.admission
      assert json.budgets == view.pools
      assert json.machines == view.machines
      assert json.repos == []
      assert json.fair_share == []
      assert Jason.encode!(json)
    end

    test "reads the live capacity view when not handed one" do
      ap = start_autopilot!(paused: false)

      json = [autopilot: ap, supervisor: empty_supervisor!()] |> Drain.status() |> Drain.to_json()

      assert %{label: label} = json.admission
      assert label in ~w(legacy shadow enforce)
      assert is_list(json.budgets)
      assert [%{id: "local"} | _] = json.machines
    end

    test "a capacity read that fails leaves the drain state intact" do
      ap = start_autopilot!(paused: false)

      json =
        [autopilot: ap, supervisor: empty_supervisor!(), capacity: fn -> raise "boom" end]
        |> Drain.status()
        |> Drain.to_json()

      assert json.state == "running"
      assert json.budgets == []
      assert json.admission == nil
    end

    # bd-1qjv3j: the board-wide hold rides the status in the account-qualified
    # wording, so `scheduler_status` and `arb prime` show which account is held.
    test "carries the account-qualified quota hold, nil when nothing is held" do
      ap = start_autopilot!(paused: false)
      sup = empty_supervisor!()
      reason = "claude:default 7d 20% ≥ paced 20% (20% elapsed)"

      held =
        [autopilot: ap, supervisor: sup, quota_hold: reason] |> Drain.status() |> Drain.to_json()

      free =
        [autopilot: ap, supervisor: sup, quota_hold: nil] |> Drain.status() |> Drain.to_json()

      assert held.quota_hold == reason
      assert free.quota_hold == nil
    end
  end

  defp status_for(ap, task_id) do
    Drain.status(autopilot: ap).in_flight |> Enum.filter(&(&1.task_id == task_id))
  end

  defp stop_quietly(pid),
    do: Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
end
