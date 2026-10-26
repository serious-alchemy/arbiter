defmodule Arbiter.Worker.K8sDoneSignalTest do
  @moduledoc """
  A run placed on a node (a cluster pod's `{:remote, _}` handle) is classified by the
  same completion rules as a local one: the `arb done` its agent printed, however the
  node's stream and its exit were interleaved, makes the run done; a run that never
  printed it is `exited_without_done`.

  The node's end is simulated with the messages `Arbiter.Nodes.RunStreams` sends a
  Worker (`{handle, {:data, _}}`, then the outcome and the exit status).
  `Arbiter.NodeAgent.K8s.ControllerPrimaryDoneTest` drives the real controller and log
  follower into the same messages.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  @moduletag :tmp_dir

  @handle {:remote, {"k8s-node", "run-1", :ref}}

  setup do
    grace = Application.fetch_env(:arbiter, :worker_exit_grace_ms)
    Application.put_env(:arbiter, :worker_exit_grace_ms, 150)

    on_exit(fn ->
      case grace do
        {:ok, v} -> Application.put_env(:arbiter, :worker_exit_grace_ms, v)
        :error -> Application.delete_env(:arbiter, :worker_exit_grace_ms)
      end
    end)

    task_id = "bd-k8sdone-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "r")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    %{pid: pid, task_id: task_id}
  end

  defp open_remote_session(pid, task_id) do
    session =
      task_id
      |> ClaudeSession.build_session_config(nil, redact_values: [])
      |> Map.merge(%{
        output_lines: [],
        line_buf: "",
        exit_status: nil,
        exited_at: nil,
        started_at: DateTime.utc_now(),
        activity: "starting",
        activity_at: DateTime.utc_now(),
        stdout_offset: 0
      })

    :sys.replace_state(pid, fn st ->
      %{st | claude_sessions: Map.put(st.claude_sessions, @handle, session)}
    end)
  end

  defp assistant(text) do
    Jason.encode!(%{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp result_event do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "stop_reason" => "end_turn",
      "result" => "ok"
    })
  end

  defp line(pid, text), do: send(pid, {@handle, {:data, {:eol, text}}})

  defp exit_remote(pid, status \\ 0) do
    outcome = %{oom?: false, exit_code: status, cancelled?: false, node_lost?: false}
    send(pid, {@handle, {:outcome, outcome}})
    send(pid, {@handle, {:exit_status, status}})
  end

  # Past the exit grace, with everything sent so far handled.
  defp settled(pid) do
    Process.sleep(400)
    _ = :sys.get_state(pid)
    Worker.state(pid)
  end

  describe "a run on a node" do
    test "whose final message ends with `arb done` is done", %{pid: pid, task_id: task_id} do
      open_remote_session(pid, task_id)

      line(pid, assistant("All finished.\n\narb done"))
      line(pid, result_event())
      exit_remote(pid)

      snap = settled(pid)
      assert %{state: :finished, outcome: :succeeded} = snap
      assert snap.meta.done_seen == true
    end

    test "whose exit arrives before the stream's final line, within the exit grace, is done",
         %{pid: pid, task_id: task_id} do
      open_remote_session(pid, task_id)

      line(pid, assistant("working"))
      exit_remote(pid)
      line(pid, assistant("All finished.\n\narb done"))
      line(pid, result_event())

      snap = settled(pid)
      assert %{state: :finished, outcome: :succeeded} = snap
      assert snap.meta.done_seen == true
    end

    test "that never printed `arb done` is exited_without_done", %{pid: pid, task_id: task_id} do
      open_remote_session(pid, task_id)

      line(pid, assistant("All finished."))
      line(pid, result_event())
      exit_remote(pid)

      snap = settled(pid)
      assert %{state: :finished, outcome: :failed} = snap
      assert snap.meta.stop_reason.category == :exited_without_done
      refute Map.get(snap.meta, :done_seen)
    end

    test "that never printed `arb done` says what its stream carried, for the next diagnosis",
         %{pid: pid, task_id: task_id} do
      open_remote_session(pid, task_id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          line(pid, assistant("All finished."))
          line(pid, result_event())
          exit_remote(pid)
          _ = settled(pid)
        end)

      assert log =~ "exited without completing"
      assert log =~ "remote stdout"
      assert log =~ "stdout_bytes="
      assert log =~ "All finished."
    end

    test "that only mentions `arb done` in prose is not done", %{pid: pid, task_id: task_id} do
      open_remote_session(pid, task_id)

      line(pid, assistant("I will print `arb done` once the tests pass."))
      line(pid, result_event())
      exit_remote(pid)

      snap = settled(pid)
      assert %{state: :finished, outcome: :failed} = snap
      assert snap.meta.stop_reason.category == :exited_without_done
    end
  end

  describe "a local run (unchanged)" do
    test "whose final message ends with `arb done` is done", %{pid: pid, tmp_dir: dir} do
      assert {:ok, _port} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: dir,
                 command: ["printf", "%s\\n", assistant("All finished.\n\narb done")]
               )

      assert %{state: :finished, outcome: :succeeded} = wait_finished(pid)
    end

    test "that never printed `arb done` is exited_without_done", %{pid: pid, tmp_dir: dir} do
      assert {:ok, _port} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: dir,
                 command: ["printf", "%s\\n", assistant("All finished.")]
               )

      snap = wait_finished(pid)
      assert %{state: :finished, outcome: :failed} = snap
      assert snap.meta.stop_reason.category == :exited_without_done
    end
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
end
