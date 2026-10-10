defmodule Arbiter.Worker.DispatchResumePlacementTest do
  @moduledoc """
  bd-4ic681: a resume of a podman Claude implementer (`worker_resume` in briefing or
  session mode, the Reconciler's and `LostResume`'s automatic one) is a placement
  candidate like the first dispatch was (`Arbiter.Nodes.Placement.eligible/1`).

  Driven through the real `Dispatch.resume/2` and `resume_session/2` against a real
  git repo (`Arbiter.Test.ResumeSlotFixture`): ticket A was dispatched on a podman
  workspace (a private clone) and its worker parked `:failed`, so it is In progress
  with a preserved home clone. The node is a pool row (`:nodes`); the agent spawn is
  captured (`:claude_start`), so what is asserted is where the run was placed.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes.Placement
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.{ResumeSlotFixture, StubResumeDeferrer}
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  @repo ResumeSlotFixture.repo()
  @podman [security: %{"sandbox" => %{"backend" => "podman"}}]

  setup do
    ResumeSlotFixture.setup_repo!()
    StubResumeDeferrer.reset()

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_deps_cache: false
        ],
        do: put_app_env(:arbiter, key, value)

    :ok
  end

  defp workspace!(placement) do
    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-place-#{n}",
        prefix: "rp#{n}",
        config: %{"worker" => %{"placement" => placement}}
      })

    ws
  end

  # A dispatched under podman (its home clone is a private clone), then parked: In
  # progress, holding its slot, with a recorded Claude session to continue. Its
  # first run went wherever placement put it (a `remote_only` one needs a node).
  defp parked!(ws, title \\ "cut off") do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id})

    {:ok, first} =
      Dispatch.dispatch(
        task.id,
        [force: true, repo: @repo, start_driver: false, nodes: [row("n-first")]] ++ @podman
      )

    :ok = Worker.fail(first.worker_pid, :review_gate_rejected)

    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: task.id,
        workspace_id: ws.id,
        repo: @repo,
        step: :work,
        provider: "claude",
        session_id: "sess-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

    %{task: task, first: first}
  end

  defp row(id \\ "n-resume") do
    %{
      id: id,
      name: "resume-node",
      state: :online,
      health: :ready,
      max: 2,
      live: 0,
      workspace_ids: [],
      labels: [],
      caps: %{}
    }
  end

  # The agent spawn, captured: where the run was placed rides in its session opts.
  defp capture do
    test = self()

    fn session_opts ->
      send(test, {:spawned, Keyword.get(session_opts, :node)})
      {:ok, :captured}
    end
  end

  defp resume_opts(extra) do
    Keyword.merge(
      [start_driver: false, claude_start: capture(), nodes: [row()]] ++ @podman,
      extra
    )
  end

  defp registry_node(pid) do
    case Enum.find(Arbiter.Worker.Registry.live_dispatches(), &(&1.pid == pid)) do
      %{node_id: node_id} -> node_id
      nil -> :not_registered
    end
  end

  describe "worker.placement: prefer_remote" do
    test "a briefing resume is placed on a node" do
      %{task: task, first: first} = parked!(workspace!("prefer_remote"))

      assert {:ok, %{worker_pid: pid}} = Dispatch.resume(task.id, resume_opts([]))

      assert pid != first.worker_pid
      assert_receive {:spawned, %{id: "n-resume"}}
      assert registry_node(pid) == "n-resume"
      assert Placement.reservations() == []
    end

    test "a session resume is placed the same way" do
      %{task: task} = parked!(workspace!("prefer_remote"))

      assert {:ok, %{worker_pid: pid}} = Dispatch.resume_session(task.id, resume_opts([]))

      assert_receive {:spawned, %{id: "n-resume"}}
      assert registry_node(pid) == "n-resume"
    end

    # The primary's own cap is the gate only for a run that stays there: with it
    # full, a resume a node can take is placed rather than held or deferred.
    test "with the primary's cap full, a human resume goes to the node instead of being held" do
      ws = workspace!("prefer_remote")
      %{task: task} = parked!(ws)
      {:ok, other} = Ash.create(Issue, %{title: "fills the primary", workspace_id: ws.id})
      ResumeSlotFixture.admit!(ws, other)

      assert {:ok, %{worker_pid: pid}} = Dispatch.resume(task.id, resume_opts([]))

      assert_receive {:spawned, %{id: "n-resume"}}
      assert registry_node(pid) == "n-resume"
    end

    test "with the primary's cap full, an automatic resume is placed, not deferred" do
      ws = workspace!("prefer_remote")
      %{task: task} = parked!(ws)
      {:ok, other} = Ash.create(Issue, %{title: "fills the primary", workspace_id: ws.id})
      ResumeSlotFixture.admit!(ws, other)

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.resume_session(task.id, resume_opts(resume_origin: :automatic))

      assert is_pid(pid)
      assert_receive {:spawned, %{id: "n-resume"}}
      assert StubResumeDeferrer.deferrals() == []
    end

    test "with the primary's cap full and no node free, the resume is held as before" do
      ws = workspace!("prefer_remote")
      %{task: task, first: first} = parked!(ws)
      {:ok, other} = Ash.create(Issue, %{title: "fills the primary", workspace_id: ws.id})
      ResumeSlotFixture.admit!(ws, other)
      full = %{row() | live: 2}

      assert {:error, {:no_node_capacity, info}} =
               Dispatch.resume(task.id, resume_opts(nodes: [full]))

      assert info.node == "local"
      assert info.kind == :resume
      assert info.phrase =~ "(no node had a free slot)"
      refute_received {:spawned, _}
      # Nothing was stopped: the parked worker is still the task's.
      assert Worker.whereis(task.id) == first.worker_pid
    end

    # bd-373tce kept a dispatch whose home clone holds uncommitted work local, because
    # the seed carried commits only. A resume's clone is dirty by nature (the run was
    # cut off mid-task), and its seed now carries the work tree
    # (`Arbiter.Nodes.Checkout.seed_bundle/2`), so it is placed.
    test "a resume whose home clone holds uncommitted work is still placed" do
      %{task: task, first: first} = parked!(workspace!("prefer_remote"))
      File.write!(Path.join(first.worktree_path, "half-done.txt"), "work in progress\n")

      assert {:ok, %{worker_pid: pid}} = Dispatch.resume(task.id, resume_opts([]))

      assert_receive {:spawned, %{id: "n-resume"}}
      assert registry_node(pid) == "n-resume"
      assert File.read!(Path.join(first.worktree_path, "half-done.txt")) == "work in progress\n"
    end
  end

  describe "worker.placement: local_only (the default)" do
    test "a resume stays on the primary" do
      %{task: task} = parked!(workspace!("local_only"))

      assert {:ok, %{worker_pid: pid}} = Dispatch.resume(task.id, resume_opts([]))

      assert_receive {:spawned, nil}
      assert registry_node(pid) == nil
    end

    test "and the primary's cap still holds it when full" do
      ws = workspace!("local_only")
      %{task: task} = parked!(ws)
      {:ok, other} = Ash.create(Issue, %{title: "fills the primary", workspace_id: ws.id})
      ResumeSlotFixture.admit!(ws, other)

      assert {:error, {:no_node_capacity, info}} = Dispatch.resume(task.id, resume_opts([]))
      assert info.node == "local"
      assert info.phrase =~ "run is local-only: workspace worker.placement is local_only"
    end
  end

  describe "worker.placement: remote_only" do
    test "with no node free a human resume is held, and nothing is stopped" do
      %{task: task, first: first} = parked!(workspace!("remote_only"))

      assert {:error, {:no_node_capacity, info}} =
               Dispatch.resume(task.id, resume_opts(nodes: []))

      assert info.mode == :remote_only
      assert info.task_id == task.id
      refute_received {:spawned, _}
      assert Worker.whereis(task.id) == first.worker_pid
    end

    test "with no node free an automatic resume is deferred to the scheduler" do
      %{task: task, first: first} = parked!(workspace!("remote_only"))
      task_id = task.id

      assert {:ok, %{deferred: true, task_id: ^task_id}} =
               Dispatch.resume_session(
                 task.id,
                 resume_opts(nodes: [], resume_origin: :automatic)
               )

      assert [{^task_id, :resume_session, _opts}] = StubResumeDeferrer.deferrals()
      assert Worker.whereis(task.id) == first.worker_pid
    end

    test "with a node free the resume is placed there" do
      %{task: task} = parked!(workspace!("remote_only"))

      assert {:ok, %{worker_pid: pid}} = Dispatch.resume(task.id, resume_opts([]))
      assert_receive {:spawned, %{id: "n-resume"}}
      assert registry_node(pid) == "n-resume"
    end
  end

  # What the board scheduler asks before it replays a resume it deferred
  # `held_for: :local_capacity`: could it start now, wherever placement puts it?
  describe "resume_room?/2" do
    setup do
      ws = workspace!("prefer_remote")
      %{task: task} = parked!(ws)
      {:ok, other} = Ash.create(Issue, %{title: "fills the primary", workspace_id: ws.id})
      ResumeSlotFixture.admit!(ws, other)
      %{task: task}
    end

    test "a node with room is room, with the primary full", %{task: task} do
      assert Dispatch.resume_room?(task.id, Keyword.merge(@podman, nodes: [row()]))
      assert Placement.reservations() == []
    end

    test "with the primary full and no node free there is none", %{task: task} do
      refute Dispatch.resume_room?(task.id, Keyword.merge(@podman, nodes: [%{row() | live: 2}]))
    end

    test "a run that stays on the primary waits for the primary's cap", %{task: task} do
      refute Dispatch.resume_room?(task.id, nodes: [row()])

      ResumeSlotFixture.put_local_cap(2)
      assert Dispatch.resume_room?(task.id, nodes: [row()])
    end

    test "remote_only with no node free is no room, even with the primary idle" do
      %{task: task} = parked!(workspace!("remote_only"))
      ResumeSlotFixture.put_local_cap(4)

      refute Dispatch.resume_room?(task.id, Keyword.merge(@podman, nodes: []))
    end
  end

  # AC3 (§10.5): a resume must not provision from a home clone that lacks a node's
  # work, nor race a container that may still be running. While a node holds (the
  # `hold` verdict after a primary restart), lists, retains or is handing back a live
  # run of the ticket, the resume waits for Recovery to collect it.
  describe "a run a node still has" do
    alias Arbiter.Nodes
    alias Arbiter.Nodes.Recovery
    alias Arbiter.Workers.Run

    setup do
      {:ok, %{token: token}} = Nodes.mint_join_token([name: "held-node"], "operator:test")
      {:ok, %{node: node}} = Nodes.redeem_join_token(token)

      on_exit(fn ->
        for {pid, _} <- Nodes.Registry.list(),
            do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
      end)

      ws = workspace!("prefer_remote")
      %{task: task, first: first} = parked!(ws)
      %{node: Nodes.get_node(node.id), task: task, first: first}
    end

    # What a primary restart leaves behind: the row of the run that was live on the node.
    defp live_row!(task, node) do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: "cut off on a node",
          repo: @repo,
          state: :working,
          started_at: DateTime.utc_now(),
          node_id: node.id
        })

      run
    end

    defp connect!(node, hello) do
      base = %{"agent_version" => "1.0.0", "proto" => 1, "caps" => %{"run_hold" => true}}
      {:ok, %{pid: pid}} = Nodes.Registry.attach(node, self(), Map.merge(base, hello))
      pid
    end

    test "while the node holds it, a human resume is held and nothing is stopped", c do
      run = live_row!(c.task, c.node)
      connect!(c.node, %{"runs" => [%{"id" => run.id, "state" => "running"}]})

      assert {:error, {:no_node_capacity, info}} = Dispatch.resume(c.task.id, resume_opts([]))

      assert info.reason == :awaiting_collect
      assert [%{run: run_id, state: :held, node: "held-node"}] = info.runs
      assert run_id == run.id
      assert info.message =~ "collected"
      refute_received {:spawned, _}
      assert Worker.whereis(c.task.id) == c.first.worker_pid
    end

    test "an automatic resume is deferred until it is collected", c do
      run = live_row!(c.task, c.node)
      connect!(c.node, %{"runs" => [%{"id" => run.id, "state" => "running"}]})
      task_id = c.task.id

      assert {:ok, %{deferred: true}} =
               Dispatch.resume_session(task_id, resume_opts(resume_origin: :automatic))

      assert [{^task_id, :resume_session, _}] = StubResumeDeferrer.deferrals()
      refute Dispatch.resume_room?(task_id, Keyword.merge(@podman, nodes: [row()]))
    end

    test "a run the node quiesced and retained holds the resume the same way", c do
      run = live_row!(c.task, c.node)

      connect!(c.node, %{
        "inventory" => %{"retained" => [%{"run" => run.id, "task" => c.task.id}]}
      })

      assert {:error,
              {:no_node_capacity, %{reason: :awaiting_collect, runs: [%{state: :retained}]}}} =
               Dispatch.resume_session(c.task.id, resume_opts([]))
    end

    test "once the run is collected and settled, the resume goes ahead", c do
      run = live_row!(c.task, c.node)
      connect!(c.node, %{"runs" => [%{"id" => run.id, "state" => "running"}]})
      assert {:error, {:no_node_capacity, _}} = Dispatch.resume(c.task.id, resume_opts([]))

      # Recovery took its work; the Reconciler marked the row interrupted.
      Ash.update!(run, %{state: :finished, outcome: :interrupted}, action: :update)

      assert {:ok, %{worker_pid: pid}} = Dispatch.resume(c.task.id, resume_opts([]))
      assert_receive {:spawned, %{id: "n-resume"}}
      assert is_pid(pid)
    end

    test "another ticket's run on the node holds nothing back", c do
      {:ok, other} =
        Ash.create(Issue, %{title: "someone else's", workspace_id: c.task.workspace_id})

      run = live_row!(other, c.node)
      connect!(c.node, %{"runs" => [%{"id" => run.id, "state" => "running"}]})

      assert {:ok, _} = Dispatch.resume(c.task.id, resume_opts([]))
    end

    # The boot sweep holds the scheduler closed while Recovery waits for nodes to come
    # back; a live remote row is Recovery's until then, connected node or not.
    test "pending_collect/2: while the boot sweep runs, a live remote row is Recovery's", c do
      run = live_row!(c.task, c.node)

      assert [%{run: run_id, state: :awaiting_recovery}] =
               Recovery.pending_collect(c.task.id, gate_open?: false)

      assert run_id == run.id
      assert Recovery.pending_collect(c.task.id, gate_open?: true) == []
    end
  end

  # The scheduler's own replay check, not a seam: a resume deferred while the primary
  # was full and no node had room is replayed once a node does, primary still full.
  describe "the board scheduler's deferred-resume replay" do
    defp scheduler!(test) do
      {:ok, pid} =
        Arbiter.Board.Autopilot.start_link(
          name: nil,
          interval_ms: :never,
          debounce_ms: 60_000,
          topics: [],
          follow_up: false,
          paused: false,
          registry_settled?: fn -> true end,
          snapshot: fn _ -> %{slots_free: 0, ready: [], promote: nil, paused: false} end,
          dispatch: fn id -> {:ok, %{task_id: id}} end,
          resume: fn task_id, kind, opts ->
            send(test, {:replayed, task_id, kind, opts})
            {:ok, %{task_id: task_id}}
          end,
          priority: fn _ -> 2 end,
          escalate: fn _, _, _ -> :ok end
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      pid
    end

    test "waits while nothing has room, and replays once a node does" do
      ws = workspace!("prefer_remote")
      %{task: task} = parked!(ws)
      {:ok, other} = Ash.create(Issue, %{title: "fills the primary", workspace_id: ws.id})
      ResumeSlotFixture.admit!(ws, other)
      pid = scheduler!(self())
      task_id = task.id

      full = Keyword.merge(@podman, nodes: [%{row() | live: 2}], held_for: :local_capacity)
      :ok = Arbiter.Board.Autopilot.defer_resume(pid, task_id, :resume_session, full)
      Arbiter.Board.Autopilot.tick(pid)
      refute_received {:replayed, _, _, _}

      free = Keyword.merge(@podman, nodes: [row()], held_for: :local_capacity)
      :ok = Arbiter.Board.Autopilot.defer_resume(pid, task_id, :resume_session, free)
      Arbiter.Board.Autopilot.tick(pid)
      assert_receive {:replayed, ^task_id, :resume_session, opts}, 5_000
      assert opts[:slot_admitted] == true
    end
  end
end
