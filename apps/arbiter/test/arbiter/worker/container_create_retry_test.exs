defmodule Arbiter.Worker.ContainerCreateRetryTest do
  @moduledoc """
  bd-325sps: `podman run` exiting 126 with only a libpod creation error (the agent
  never started) is retried a bounded number of times with a backoff, then fails
  the run as `:container_create_failed` rather than `:crashed`. A stub command
  stands in for the podman client: it fails creation until a counter file says
  otherwise.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  @libpod_error "Error: container creation timeout: internal libpod error"

  setup do
    prev_backoff = Application.get_env(:arbiter, :container_create_retry_backoff_ms)
    prev_cap = Application.get_env(:arbiter, :container_create_retries)
    Application.put_env(:arbiter, :container_create_retry_backoff_ms, 10)
    Application.put_env(:arbiter, :container_create_retries, 2)

    on_exit(fn ->
      restore(:container_create_retry_backoff_ms, prev_backoff)
      restore(:container_create_retries, prev_cap)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ccr-ws-#{System.unique_integer([:positive])}",
        prefix: "cc"
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "container create", workspace_id: ws.id, issue_type: :research})

    task = put_state!(task, :active)

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "unknown",
        workspace_id: ws.id,
        meta: %{issue_type: :research, review_spawn: false, notes_nudge_cap: 1}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    %{
      pid: pid,
      counter: Path.join(System.tmp_dir!(), "ccr-#{System.unique_integer([:positive])}")
    }
  end

  defp restore(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore(key, value), do: Application.put_env(:arbiter, key, value)

  # Fails creation (exit 126) for the first `failures` invocations, then "runs the agent".
  defp stub(counter, failures) do
    script = """
    n=$(cat '#{counter}' 2>/dev/null || echo 0)
    n=$((n + 1))
    echo $n > '#{counter}'
    if [ $n -le #{failures} ]; then echo '#{@libpod_error}'; exit 126; fi
    echo 'agent ran'
    exit #{"${AGENT_EXIT:-0}"}
    """

    ["sh", "-c", script]
  end

  defp start_session!(pid, command) do
    {:ok, _port} =
      ClaudeSession.start(owner: pid, worktree_path: System.tmp_dir!(), command: command)

    :ok
  end

  defp attempts(counter), do: counter |> File.read!() |> String.trim() |> String.to_integer()

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(15) && :again
      end
    end)
    |> Enum.find(&(&1 != :again))
    |> case do
      :ok -> :ok
      :timeout -> flunk("condition not met within timeout")
    end
  end

  test "a creation failure is retried and a later success proceeds normally", %{
    pid: pid,
    counter: counter
  } do
    start_session!(pid, stub(counter, 1))

    # Attempt 1 fails creation, attempt 2 runs the agent, which exits 0 without `arb done`.
    wait_until(fn -> File.exists?(counter) and attempts(counter) >= 2 end)
    wait_until(fn -> match?(%{state: :finished}, Worker.state(pid)) end)

    snap = Worker.state(pid)
    assert snap.meta[:container_create_retries] == 1

    refute snap.meta[:stop_reason] &&
             snap.meta.stop_reason[:category] == "container_create_failed"

    # The agent that ran then exits 0 without `arb done`, so the notes gate may nudge-respawn
    # it; what matters is that creation was retried exactly once.
    assert attempts(counter) >= 2
  end

  test "persistent creation failure fails the run as an infra failure after the cap", %{
    pid: pid,
    counter: counter
  } do
    start_session!(pid, stub(counter, 100))

    wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

    snap = Worker.state(pid)
    # The original spawn plus two retries, then no more.
    assert attempts(counter) == 3
    assert snap.meta[:container_create_retries] == 2
    assert snap.meta.stop_reason.category == :container_create_failed
    assert snap.meta.failure_reason =~ "container creation failed"
    refute snap.meta.failure_reason =~ "crashed"
  end

  test "an agent exit after a successful start is not retried", %{pid: pid, counter: counter} do
    # Creation succeeds first time; the agent then exits 126 after writing real output.
    script = """
    echo 1 > '#{counter}'
    echo 'agent did some work'
    echo '#{@libpod_error}'
    exit 126
    """

    start_session!(pid, ["sh", "-c", script])

    wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

    snap = Worker.state(pid)
    assert attempts(counter) == 1
    refute Map.has_key?(snap.meta, :container_create_retries)
    assert snap.meta.stop_reason.category == :crashed
  end
end
