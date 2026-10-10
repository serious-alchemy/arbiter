defmodule Arbiter.Worker.NodeLostTest do
  @moduledoc """
  RW12 (`docs/design/remote-workers.md` §10.3): a Worker whose node was lost ends its
  run `interrupted` with the `:node_lost` classification, consumes no resume
  attempt, asks for the automatic resume, and is not escalated as a failure.

  The remote session is simulated: a local agent port stands in for the handle and
  the node's `outcome{node_lost?: true}` is stamped on its session, which is the
  message `Arbiter.Nodes.Session` sends the owner when it ends
  (`apps/arbiter_web/test/arbiter_web/remote_node_lost_test.exs` drives the real one).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Workers.Run

  require Ash.Query

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:arbiter, :node_lost_resume)
    grace = Application.fetch_env(:arbiter, :worker_exit_grace_ms)
    test = self()

    Application.put_env(:arbiter, :node_lost_resume,
      enabled: true,
      resume_fun: fn task_id ->
        send(test, {:resumed, task_id})
        {:ok, :stub}
      end
    )

    Application.put_env(:arbiter, :worker_exit_grace_ms, 20)

    on_exit(fn ->
      restore(:node_lost_resume, previous)
      restore(:worker_exit_grace_ms, grace)
    end)

    task_id = "bd-lost-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "r")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    %{pid: pid, task_id: task_id, dir: dir}
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  defp lose_node(pid, dir, outcome) do
    # `sleep` itself, not `sh -c "sleep 30"`: a shell that forks rather than
    # execs its last command (dash on Ubuntu CI) leaves `sleep` holding the
    # port's pipe after the kill, so the exit is never reported.
    {:ok, port} = ClaudeSession.start(owner: pid, worktree_path: dir, command: ["sleep", "30"])

    :sys.replace_state(pid, fn st ->
      update_in(st.claude_sessions[port], &Map.put(&1, :remote_outcome, outcome))
    end)

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  defp wait_finished(pid) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case Worker.state(pid) do
        %{state: :finished} = snap ->
          {:halt, snap}

        _ ->
          Process.sleep(25)
          {:cont, nil}
      end
    end)
  end

  test "ends the run interrupted, classified node_lost, with no resume attempt consumed",
       %{pid: pid, task_id: task_id, dir: dir} do
    lose_node(pid, dir, %{oom?: false, exit_code: 255, cancelled?: false, node_lost?: true})

    snap = wait_finished(pid)
    assert %{state: :finished, outcome: :interrupted} = snap
    assert snap.meta.stop_reason.category == :node_lost
    assert snap.meta.failure_reason =~ "node lost"
    assert Map.get(snap.meta, :resume_attempts, 0) == 0

    run = Ash.get!(Run, snap.run_id)
    assert run.state == :finished
    assert run.outcome == :interrupted
    assert run.stop_category == "node_lost"
    assert run.failure_reason =~ "node lost"

    # the automatic resume was asked for, once
    assert_receive {:resumed, ^task_id}, 2_000
    refute_receive {:resumed, _}, 100

    # an interruption is not a failure to page the coordinator about
    assert [] =
             Message
             |> Ash.Query.filter(task_ref == ^task_id and kind == :escalation)
             |> Ash.read!()
  end

  test "the session's subscribers are told the node was lost, not that it exited",
       %{pid: pid, task_id: task_id, dir: dir} do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> task_id)
    lose_node(pid, dir, %{oom?: false, exit_code: 255, cancelled?: false, node_lost?: true})

    assert_receive {:worker_node_lost, ^task_id}, 2_000
    refute_receive {:worker_exited, ^task_id, _}, 200
  end

  test "an ordinary exit still reaches the session's subscribers as an exit",
       %{pid: pid, task_id: task_id, dir: dir} do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> task_id)
    lose_node(pid, dir, %{oom?: false, exit_code: 137, cancelled?: false, node_lost?: false})

    assert_receive {:worker_exited, ^task_id, _}, 2_000
    refute_receive {:worker_node_lost, _}, 100
  end

  # bd-cgdhlu: a ReviewGate pass (`<task>#review`) is not a ticket to resume; its
  # gate re-dispatches it from `{:worker_node_lost, id}`.
  test "a ReviewGate pass losing its node asks for no automatic resume", %{dir: dir} do
    task_id = "bd-lostgate-#{System.unique_integer([:positive])}#review"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "r")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    lose_node(pid, dir, %{oom?: false, exit_code: 255, cancelled?: false, node_lost?: true})

    assert %{state: :finished, outcome: :interrupted} = wait_finished(pid)
    refute_receive {:resumed, _}, 300
  end

  # K12 (A5): a pod evicted, preempted or deleted from outside is handled like a lost node.
  test "a pod_disrupted exit ends the run interrupted with no resume attempt consumed",
       %{pid: pid, task_id: task_id, dir: dir} do
    lose_node(pid, dir, %{
      oom?: false,
      exit_code: 137,
      cancelled?: false,
      node_lost?: false,
      pod_disrupted?: true
    })

    snap = wait_finished(pid)
    assert %{state: :finished, outcome: :interrupted} = snap
    assert snap.meta.stop_reason.category == :pod_disrupted
    assert snap.meta.failure_reason =~ "pod disrupted"
    assert Map.get(snap.meta, :resume_attempts, 0) == 0

    run = Ash.get!(Run, snap.run_id)
    assert run.outcome == :interrupted
    assert run.stop_category == "pod_disrupted"

    # re-dispatched through Placement exactly like a lost node, and not paged as a failure
    assert_receive {:resumed, ^task_id}, 2_000
    refute_receive {:resumed, _}, 100

    assert [] =
             Message
             |> Ash.Query.filter(task_ref == ^task_id and kind == :escalation)
             |> Ash.read!()
  end

  test "a pod_disrupted: false outcome (any machine exit) is unchanged", %{pid: pid, dir: dir} do
    lose_node(pid, dir, %{
      oom?: false,
      exit_code: 137,
      cancelled?: false,
      node_lost?: false,
      pod_disrupted?: false
    })

    snap = wait_finished(pid)
    refute snap.outcome == :interrupted
    refute_receive {:resumed, _}, 200
  end

  test "an ordinary exit without the node_lost outcome is unchanged (still not interrupted)",
       %{pid: pid, dir: dir} do
    lose_node(pid, dir, %{oom?: false, exit_code: 137, cancelled?: false, node_lost?: false})

    snap = wait_finished(pid)
    refute snap.outcome == :interrupted
    refute_receive {:resumed, _}, 200
  end
end
