defmodule Arbiter.SandboxTeardownTest do
  @moduledoc """
  Regression test for bd-5scl0c.

  `Arbiter.DataCase`'s leaked-child sweep used to call
  `DynamicSupervisor.terminate_child/2` directly. `terminate_child/2` sends
  `Process.exit(child, :shutdown)`, which kills a child that does not trap
  exits *immediately* — including while it is parked inside a DB query or an
  `Ecto` transaction. DBConnection sees the holder ETS table transfer back to
  the pool, logs

      Exqlite.Connection (#PID<…>) disconnected:
        ** (DBConnection.ConnectionError) client #PID<…> exited

  disconnects the single (`pool_size: 1`) physical SQLite connection and stops
  the `DBConnection.Ownership.Proxy`. The test that owned that connection then
  loses it mid-run: every later query raises `DBConnection.OwnershipError`
  ("cannot find ownership process"), which call sites routinely swallow into a
  misleading `:not_found`, and in shared mode every other process in the VM
  loses DB access too.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.SandboxMonitor

  # A child that spends essentially all of its time inside a DB transaction,
  # i.e. holding a checkout on the sandbox connection. It does not trap exits,
  # so a bare `:shutdown` signal kills it mid-transaction.
  defmodule BusyDbChild do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(parent) do
      send(self(), :work)
      {:ok, parent}
    end

    @impl true
    def handle_info(:work, parent) do
      Arbiter.Repo.transaction(fn ->
        Arbiter.Repo.query!("SELECT 1")
        send(parent, :in_transaction)
        Process.sleep(20)
      end)

      send(self(), :work)
      {:noreply, parent}
    end
  end

  @sweep_supervisor Arbiter.Workflows.MachineSupervisor

  test "sweeping a leaked child that is mid-query leaves the sandbox connection intact" do
    {:ok, ws} = Ash.create(Workspace, %{name: "sandbox-teardown-ws", prefix: "stw"})

    {:ok, _child} =
      DynamicSupervisor.start_child(@sweep_supervisor, %{
        id: :sandbox_teardown_busy_child,
        start: {BusyDbChild, :start_link, [self()]},
        restart: :temporary
      })

    # Only sweep once the child is demonstrably inside a transaction, so the
    # sweep is guaranteed to land on a process holding the connection.
    assert_receive :in_transaction, 2_000

    log =
      capture_log(fn ->
        Arbiter.DataCase.stop_leaked_dynamic_children()
        # The disconnect is logged asynchronously by the connection process.
        Process.sleep(100)
      end)

    refute log =~ "client #PID",
           "the sweep killed a child that was holding the sandbox connection: #{log}"

    # The real damage: the owning test loses its sandbox connection entirely.
    assert {:ok, %Workspace{}} = Ash.get(Workspace, ws.id)
  end

  # Some clients cannot be quiesced, because they are not ours to quiesce: a
  # `Phoenix.LiveView.Channel` is killed by ExUnit's own test-supervisor
  # teardown, before the first `on_exit` callback runs. For those, the
  # disconnect is unavoidable — what matters is *when* it lands.
  #
  # Nothing orders the holder give-away against the client's `:DOWN`, so
  # without `settle_sandbox/1` that disconnect regularly landed a few hundred
  # microseconds into the next test (measured: 7 such incidents across 5
  # `apps/arbiter_web` runs, 0 with the barrier). This asserts the ordering
  # directly: once `settle_sandbox/1` has returned, the disconnect is already
  # history, so it cannot surface as some later test's `ConnectionError`.
  test "settle_sandbox/1 does not return until a dead client's disconnect has landed" do
    before = SandboxMonitor.incidents()
    test_pid = self()

    client =
      spawn(fn ->
        Arbiter.Repo.transaction(fn ->
          Arbiter.Repo.query!("SELECT 1")
          send(test_pid, :in_transaction)
          Process.sleep(:infinity)
        end)
      end)

    ref = Process.monitor(client)
    # Only kill once the client demonstrably holds the checkout.
    assert_receive :in_transaction, 2_000
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^ref, :process, ^client, :killed}, 2_000

    capture_log(fn -> Arbiter.DataCase.settle_sandbox(test_pid) end)

    recorded = SandboxMonitor.incidents() -- before

    # Do not leave the synthetic incidents behind: they would be counted in
    # the end-of-suite report as if they were real.
    on_exit(fn -> Enum.each(recorded, &SandboxMonitor.forget/1) end)

    assert recorded != [],
           "settle_sandbox/1 returned before the killed client's disconnect was processed"
  end

  # bd-2l0hzm: `stop_dynamic_supervisor_children/1` and `drain_task_supervisor/1`
  # look the supervisor up and *then* call it. A supervisor that shuts down in
  # between (e.g. it just exceeded its restart intensity) made the call exit
  # `:noproc` inside `on_exit`, failing an otherwise green test. The stand-in
  # below is registered under the name — so the lookup finds it — and dies the
  # moment it is called, which is exactly that window.
  defp register_dying_supervisor do
    name = :"dying_supervisor_#{System.unique_integer([:positive])}"
    test_pid = self()

    pid =
      spawn(fn ->
        Process.register(self(), name)
        send(test_pid, :registered)

        receive do
          {:"$gen_call", _from, _request} -> exit(:shutdown)
        end
      end)

    assert_receive :registered
    {name, pid}
  end

  test "the dynamic-children sweep tolerates a supervisor that exits when called" do
    {name, pid} = register_dying_supervisor()
    ref = Process.monitor(pid)

    assert Arbiter.DataCase.stop_dynamic_supervisor_children(name) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
  end

  test "the dynamic-children sweep tolerates a supervisor that has already exited" do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    name = :"exited_supervisor_#{System.unique_integer([:positive])}"
    Process.register(sup, name)
    Process.unlink(sup)
    ref = Process.monitor(sup)
    DynamicSupervisor.stop(sup)
    assert_receive {:DOWN, ^ref, :process, ^sup, :normal}

    assert Arbiter.DataCase.stop_dynamic_supervisor_children(name) == :ok
  end

  test "drain_task_supervisor/1 tolerates a supervisor that exits when called" do
    {name, pid} = register_dying_supervisor()
    ref = Process.monitor(pid)

    assert Arbiter.DataCase.drain_task_supervisor(name) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
  end
end
