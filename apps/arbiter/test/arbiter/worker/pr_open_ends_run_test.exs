defmodule Arbiter.Worker.PrOpenEndsRunTest do
  @moduledoc """
  bd-741sid (ticket lifecycle 4/13), acceptance 1 and 2.

  Opening the PR is the end of the implementer's run. Everything the parked
  worker used to hold is on the ticket row instead — the ref, its URL, the
  Watchdog's lane and the reviewed-SHA baseline, the forge's last answer and
  when it was read, the ReviewGate round state — and no `Arbiter.Worker` stays
  registered for a `:merging` ticket.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog

  setup do
    StubMerger.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pr-open-ends-run-#{System.unique_integer([:positive])}",
        prefix: "po",
        config: %{"review" => %{"required" => true}, "merge" => %{"auto_merge" => false}}
      })

    {:ok, task} =
      Ash.create(Issue, %{
        title: "pr open ends the run",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})

    on_exit(fn ->
      case Watchdog.whereis(task.id) do
        nil -> :ok
        pid -> stop_quietly(pid)
      end
    end)

    %{ws: ws, task: task}
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  # An author that has finished its work and is waiting on the ReviewGate
  # (`review_spawn: false`, so the verdict is delivered by hand exactly as the
  # gate would deliver it).
  defp parked_author(ws, task) do
    meta = %{
      branch: "feature/po",
      target_branch: "main",
      review_required: true,
      review_spawn: false,
      merger_adapter_override: StubMerger,
      merger_workspace_override: ws,
      watchdog_interval_ms: 20,
      watchdog_initial_delay_ms: 0
    }

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "po/repo", workspace_id: ws.id, meta: meta)

    on_exit(fn -> stop_quietly(pid) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(pid)) end)
    pid
  end

  defp runs(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  test "an approved PR puts every piece of its state on the ticket row", %{ws: ws, task: task} do
    StubMerger.next_open_ref("!701")
    StubMerger.queue_get("!701", [%{status: :open, approved: false, head_sha: "sha-701"}])

    author = parked_author(ws, task)
    ref = Process.monitor(author)

    :ok = Worker.review_gate_verdict(author, {:approve, "VERDICT: APPROVE\nlgtm"})

    assert_receive {:DOWN, ^ref, :process, ^author, :normal}, 2_000
    wait_until(fn -> match?(%DateTime{}, Ash.get!(Issue, task.id).merger_checked_at) end)

    ticket = Ash.get!(Issue, task.id)

    assert ticket.state == :merging
    assert ticket.pr_ref == "!701"
    assert ticket.merger_url == "https://stub.example/mr/!701"

    assert %{status: :open, approved: false, head_sha: "sha-701"} =
             PullRequest.merger_status(ticket)

    # The Watchdog's lane: the adapter that opened the PR, how it was approved,
    # and the reviewed-SHA baseline it latched on its first approved poll.
    assert ticket.merge_watch["adapter"] == "Elixir.Arbiter.Test.StubMerger"
    assert ticket.merge_watch["via_review_gate"] == true
    wait_until(fn -> Ash.get!(Issue, task.id).merge_watch["reviewed_sha"] == "sha-701" end)

    # The ReviewGate round state.
    assert %{"branch" => "feature/po", "verdict" => "approve", "pr_ref" => "!701"} =
             ticket.review_gate_state
  end

  test "no worker stays registered once the PR is open, and the run is finished and successful",
       %{ws: ws, task: task} do
    StubMerger.next_open_ref("!702")

    author = parked_author(ws, task)
    ref = Process.monitor(author)

    :ok = Worker.review_gate_verdict(author, {:approve, "VERDICT: APPROVE\nlgtm"})

    assert_receive {:DOWN, ^ref, :process, ^author, :normal}, 2_000

    assert Worker.whereis(task.id) == nil
    assert Worker.list_children() |> Enum.filter(&(&1.task_id == task.id)) == []
    assert Ash.get!(Issue, task.id).state == :merging

    assert [run] = runs(task.id)
    assert run.outcome == :succeeded
    assert %DateTime{} = run.completed_at
    assert is_nil(run.failure_reason)
    assert run.mr_ref == "!702"

    # The ticket's Watchdog, keyed by the ticket id, watches the PR instead.
    assert is_pid(Watchdog.whereis(task.id))
  end
end
