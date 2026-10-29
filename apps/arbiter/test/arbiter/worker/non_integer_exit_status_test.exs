defmodule Arbiter.Worker.NonIntegerExitStatusTest do
  @moduledoc """
  A remote run whose pod was preempted reports its exit with no integer status. The
  Worker must end the run `interrupted`, consume no resume attempt and auto-resume it,
  never crash `ClaudeSession.handle_exit/2` with a `FunctionClauseError`. Every provider
  (claude, codex, gemini, ...) shares that one exit path.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Workers.Run

  @moduletag :tmp_dir

  @providers ["claude", "codex", "gemini"]

  describe "ClaudeSession.handle_exit/2 with a non-integer status" do
    for provider <- @providers, status <- [nil, :preempted, :node_lost, "gone"] do
      test "#{provider}: #{inspect(status)} does not crash and is logged once" do
        session = %{
          task_id: "bd-x",
          provider: unquote(provider),
          topic: "worker:bd-x",
          exit_status: nil,
          exited_at: nil,
          line_buf: "",
          port: {:remote, {"n", "r", make_ref()}}
        }

        log =
          capture_log(fn ->
            send(self(), {:result, ClaudeSession.handle_exit(session, unquote(status))})
          end)

        assert_received {:result, updated}
        assert updated.unknown_exit_status == true
        assert is_integer(updated.exit_status)
        assert %DateTime{} = updated.exited_at
        assert length(String.split(log, "non-integer status")) == 2
      end
    end

    test "an integer status is unchanged" do
      session = %{
        task_id: "bd-x",
        topic: "worker:bd-x",
        exit_status: nil,
        exited_at: nil,
        line_buf: ""
      }

      updated = ClaudeSession.handle_exit(session, 0)
      assert updated.exit_status == 0
      refute Map.has_key?(updated, :unknown_exit_status)
    end
  end

  describe "Worker receiving a non-integer exit status" do
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

      task_id = "bd-nonint-#{System.unique_integer([:positive])}"
      {:ok, pid} = Worker.start(task_id: task_id, repo: "r")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      %{pid: pid, task_id: task_id, dir: dir}
    end

    defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
    defp restore(key, :error), do: Application.delete_env(:arbiter, key)

    defp exit_with(pid, dir, outcome, status) do
      {:ok, port} = ClaudeSession.start(owner: pid, worktree_path: dir, command: ["sleep", "30"])

      if outcome do
        :sys.replace_state(pid, fn st ->
          update_in(st.claude_sessions[port], &Map.put(&1, :remote_outcome, outcome))
        end)
      end

      send(pid, {port, {:exit_status, status}})
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

    @preempted %{
      oom?: false,
      exit_code: nil,
      cancelled?: false,
      node_lost?: false,
      pod_disrupted?: true,
      preempted?: true,
      disruption_detail: "preempted by pod ci/runner-abc on node mesanna"
    }

    test "a preempted run (nil status) ends interrupted/preempted and is auto-resumed",
         %{pid: pid, task_id: task_id, dir: dir} do
      exit_with(pid, dir, @preempted, nil)

      snap = wait_finished(pid)
      assert Process.alive?(pid)
      assert %{state: :finished, outcome: :interrupted} = snap
      assert snap.meta.stop_reason.category == :preempted
      assert Map.get(snap.meta, :resume_attempts, 0) == 0
      assert Ash.get!(Run, snap.run_id).stop_category == "preempted"

      assert_receive {:resumed, ^task_id}, 2_000
      refute_receive {:resumed, _}, 100
    end

    test "a preempted outcome without pod_disrupted? is still preempted",
         %{pid: pid, task_id: task_id, dir: dir} do
      exit_with(pid, dir, Map.delete(@preempted, :pod_disrupted?), :preempted)

      snap = wait_finished(pid)
      assert %{outcome: :interrupted} = snap
      assert snap.meta.stop_reason.category == :preempted
      assert_receive {:resumed, ^task_id}, 2_000
    end

    test "a node-lost run with a nil status ends interrupted/node_lost",
         %{pid: pid, task_id: task_id, dir: dir} do
      outcome = %{oom?: false, exit_code: 255, cancelled?: false, node_lost?: true}
      exit_with(pid, dir, outcome, nil)

      snap = wait_finished(pid)
      assert %{outcome: :interrupted} = snap
      assert snap.meta.stop_reason.category == :node_lost
      assert Map.get(snap.meta, :resume_attempts, 0) == 0
      assert_receive {:resumed, ^task_id}, 2_000
    end

    test "an unknown status with no outcome is logged and treated as interrupted",
         %{pid: pid, task_id: task_id, dir: dir} do
      log =
        capture_log(fn ->
          exit_with(pid, dir, nil, :weird)
          send(self(), {:snap, wait_finished(pid)})
        end)

      assert_received {:snap, snap}
      assert Process.alive?(pid)
      assert %{outcome: :interrupted} = snap
      assert Map.get(snap.meta, :resume_attempts, 0) == 0
      assert length(String.split(log, "non-integer status")) == 2
      assert_receive {:resumed, ^task_id}, 2_000
    end
  end
end
