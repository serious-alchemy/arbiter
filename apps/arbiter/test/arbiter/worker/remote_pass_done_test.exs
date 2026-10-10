defmodule Arbiter.Worker.RemotePassDoneTest do
  @moduledoc """
  bd-bg87oz — a fix or conflict pass on a node prints `arb done` while its container
  is still running; the node's final checkout upload follows the exit. The pass's
  worker must not push or judge the home clone until that upload has landed, or it
  acts on the checkout as of the last periodic snapshot.

  The remote session is simulated, as in `Arbiter.Worker.NodeLostTest`: a `{:remote, _}`
  handle in the worker's sessions whose exit is controlled by the test. The real
  node agent is `ArbiterWeb.RemotePassTest`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker

  @handle {:remote, {"node-a", "run-1", :ref}}

  setup do
    task_id = "bd-rpd-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(
        task_id: task_id,
        repo: "r",
        meta: %{role: :fix_pass, fix_pass_branch: "feature/x", branch: nil}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    %{pid: pid, task_id: task_id}
  end

  defp put_session(pid, session) do
    :sys.replace_state(pid, fn st ->
      %{st | claude_sessions: Map.put(st.claude_sessions, @handle, session)}
    end)
  end

  defp signal_done(pid) do
    send(pid, {:__claude_session_done__, "arb done"})
    _ = :sys.get_state(pid)
    :ok
  end

  test "a pass whose node run is still live waits for the exit instead of finishing", %{pid: pid} do
    put_session(pid, %{exit_status: nil})

    signal_done(pid)

    refute match?(%{state: :finished}, Worker.state(pid))
    assert Worker.state(pid).meta.done_seen == true
  end

  test "once the node run has exited the same done signal finishes the pass", %{pid: pid} do
    put_session(pid, %{exit_status: nil})
    signal_done(pid)
    refute match?(%{state: :finished}, Worker.state(pid))

    put_session(pid, %{exit_status: 0, remote_outcome: %{checkout_failed?: false}})
    ref = Process.monitor(pid)
    signal_done(pid)

    # A delivered pass ends its run and stops.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "a final checkout the node could not upload fails the pass instead of pushing a stale clone",
       %{pid: pid} do
    put_session(pid, %{exit_status: 0, remote_outcome: %{checkout_failed?: true}})

    signal_done(pid)

    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    assert inspect(Worker.state(pid).meta.failure_reason) =~ "remote_checkout_failed"
  end

  test "a node run that outlives the grace after done is stopped, and the worker keeps waiting for the exit",
       %{pid: pid} do
    put_session(pid, %{exit_status: nil})
    signal_done(pid)

    # The stop goes to the node (there is none here: a no-op); what is pinned is that
    # the grace timer's message is handled, and the pass is still not finished without
    # the node's exit.
    send(pid, {:__remote_pass_exit_grace__, @handle})
    _ = :sys.get_state(pid)

    assert Process.alive?(pid)
    refute match?(%{state: :finished}, Worker.state(pid))
  end
end
