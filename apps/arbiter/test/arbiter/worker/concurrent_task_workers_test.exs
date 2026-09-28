defmodule Arbiter.Worker.ConcurrentTaskWorkersTest do
  # bd-8tjcms / #1511 — a task must never have two *actively working* workers.
  #
  # `Arbiter.Worker` registers under a `:registry_key` that defaults to the
  # task_id, but the merge queue's subordinate passes deliberately take
  # `<task_id>:fixpass` / `<task_id>:conflict` so they can run alongside the
  # primary worker (then parked on its open MR, bd-8lq2g7). Every "is a worker
  # already running for this task?" guard in `Arbiter.Worker.Dispatch` looks up
  # the *exact* task_id key via `Worker.whereis/1`, so it cannot see a
  # subordinate — and `FixPassDispatcher` / `ConflictResolver` only guard their
  # own key. The two families are therefore mutually invisible, which is how
  # vs-ehjarz ended up with two live agent sessions on one task and one branch.
  #
  # The rule enforced here: at most one worker per task may be in an *active*
  # (agent-bearing) run state. A run waiting on the review gate and a
  # `:finished` run (any outcome) still allow a new pass to start — that
  # coexistence is the documented merge-queue design and must not regress.
  #
  # async: false — the Worker registry and DynamicSupervisor are global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "concurrent-worker-ws", prefix: "cw"})
    {:ok, task} = Ash.create(Issue, %{title: "ship the thing", workspace_id: ws.id})
    {:ok, ws: ws, task: task}
  end

  defp start_worker!(ws, task, opts) do
    opts = Keyword.merge([task_id: task.id, repo: "test/repo", workspace_id: ws.id], opts)
    {:ok, pid} = Worker.start(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  defp start_worker(ws, task, opts) do
    opts = Keyword.merge([task_id: task.id, repo: "test/repo", workspace_id: ws.id], opts)

    case Worker.start(opts) do
      {:ok, pid} = ok ->
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
        ok

      other ->
        other
    end
  end

  describe "active?/1" do
    test "classifies the agent-bearing run states as active" do
      for snap <- [
            %{state: :starting, waiting_on: nil},
            %{state: :starting, waiting_on: nil, meta: %{resume: true}},
            %{state: :working, waiting_on: nil},
            %{state: :waiting, waiting_on: :question}
          ] do
        assert Worker.active?(snap), "expected #{inspect(snap)} to be active"
      end
    end

    test "a run waiting on the review gate, or finished, is not active" do
      for snap <- [
            %{state: :waiting, waiting_on: :review_gate},
            %{state: :finished, outcome: :succeeded, waiting_on: nil},
            %{state: :finished, outcome: :failed, waiting_on: nil},
            %{state: :finished, outcome: :interrupted, waiting_on: nil},
            %{state: :finished, outcome: :handed_off, waiting_on: nil}
          ] do
        refute Worker.active?(snap), "expected #{inspect(snap)} to be inactive"
      end
    end

    test "anything without a run state is not active" do
      refute Worker.active?(%{})
      refute Worker.active?(nil)
    end
  end

  describe "a second live worker for one task" do
    test "a subordinate pass is refused while the primary is running", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      assert {:error, {:task_worker_live, info}} =
               start_worker(ws, task, registry_key: task.id <> ":fixpass")

      assert info.task_id == task.id
      assert info.registry_key == task.id
      assert info.state == :working
      assert info.pid == primary
      assert info.requested_key == task.id <> ":fixpass"
    end

    test "a primary dispatch is refused while a subordinate pass is running", %{
      ws: ws,
      task: task
    } do
      fixpass = start_worker!(ws, task, registry_key: task.id <> ":fixpass")
      :ok = Worker.advance(fixpass, :claude)

      assert {:error, {:task_worker_live, info}} = start_worker(ws, task, [])
      assert info.registry_key == task.id <> ":fixpass"
      assert info.state == :working
    end

    test "the same key still reports :already_started, not the new error", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      assert {:error, {:already_started, ^primary}} = start_worker(ws, task, [])
    end
  end

  describe "Dispatch refuses rather than co-existing" do
    # Acceptance 1: the vs-ehjarz shape — a merge-queue subordinate pass holds
    # the task while the Watchdog's auto-resume dispatches a fresh primary.
    test "dispatch/2 is refused while a subordinate pass is running", %{ws: ws, task: task} do
      fixpass = start_worker!(ws, task, registry_key: task.id <> ":fixpass")
      :ok = Worker.advance(fixpass, :claude)

      assert {:error, {:worker_start_failed, {:task_worker_live, info}}} =
               Arbiter.Worker.Dispatch.dispatch(task.id,
                 force: true,
                 repo: "r",
                 start_driver: false
               )

      assert info.registry_key == task.id <> ":fixpass"
      assert Worker.whereis(task.id) == nil
    end

    # The blind spot itself, pinned: every guard in `Dispatch` resolves the
    # EXACT task_id key via `Worker.whereis/1`, so a live subordinate is
    # invisible to it and `resumable_status/1` still says "go". That is why the
    # rule is enforced in `Worker.start/1` — the one call every dispatcher makes
    # — and not by adding another check to `Dispatch`.
    test "Dispatch's own guards cannot see a live subordinate", %{ws: ws, task: task} do
      fixpass = start_worker!(ws, task, registry_key: task.id <> ":fixpass")
      :ok = Worker.advance(fixpass, :claude)

      assert Worker.whereis(task.id) == nil
      assert {true, nil} = Arbiter.Worker.Dispatch.resumable_status(task.id)

      # ...and `Worker.start/1` is what actually stops the second agent.
      assert {:error, {:task_worker_live, _}} = start_worker(ws, task, [])
    end
  end

  describe "coexistence that must keep working" do
    test "a subordinate pass starts alongside a terminal primary", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)
      :ok = Worker.fail(primary, :some_failure)

      assert {:ok, pid} = start_worker(ws, task, registry_key: task.id <> ":fixpass")
      assert is_pid(pid)
    end

    test "a ReviewGate synthetic worker (# key) is never blocked", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      opts = [task_id: task.id <> "#review", repo: "test/repo", workspace_id: nil]
      assert {:ok, pid} = Worker.start(opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    end

    # bd-2y0gd5's trap, re-armed by this guard: `Arbiter.Worker.Registry` also
    # holds NON-worker entries under `:`-separated keys for the same task — the
    # `Arbiter.Worker.Watchdog` at `<task_id>:watchdog` most of all. Probing one
    # with `:snapshot` kills it. The scan must only ever touch `Arbiter.Worker`
    # children of `Arbiter.Worker.Supervisor`.
    test "a non-worker registry entry neither blocks a start nor is probed", %{
      ws: ws,
      task: task
    } do
      test_pid = self()

      squatter =
        spawn(fn ->
          {:ok, _} = Registry.register(Arbiter.Worker.Registry, task.id <> ":watchdog", nil)
          send(test_pid, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered, 1_000

      assert {:ok, pid} = start_worker(ws, task, [])
      assert is_pid(pid)
      assert Process.alive?(squatter), "the non-worker registry entry was probed to death"

      send(squatter, :stop)
    end

    test "an explicit opt-out still starts a second worker", %{ws: ws, task: task} do
      primary = start_worker!(ws, task, [])
      :ok = Worker.advance(primary, :claude)

      assert {:ok, pid} =
               start_worker(ws, task,
                 registry_key: task.id <> ":conflict",
                 allow_concurrent_task_worker: true
               )

      assert is_pid(pid)
    end
  end
end
