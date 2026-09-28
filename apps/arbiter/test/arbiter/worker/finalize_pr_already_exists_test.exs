defmodule Arbiter.Worker.FinalizePRAlreadyExistsTest do
  @moduledoc """
  Regression tests for bd-c5zu16: a worker's finalize step must gracefully
  handle GitHub's 422 "a pull request already exists for <head>" instead of
  failing the run.

  `Arbiter.Mergers.Github.open/4` already resolves this at the adapter level
  (bd-8rrn9t / bd-8iad6a): look-before-create, plus a reactive 422 fallback
  that adopts the existing open PR. These tests prove the effect end-to-end
  through the worker's actual `arb done` finalize path — the run must
  complete (not fail), and the adopted PR ref must land on the task — while a
  genuinely unrelated 422 must still fail the run and escalate, exactly as
  before.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workers.Run

  @owner "octo"
  @repo "widget"
  @token "test-token-abc123"

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => @owner,
        "repo" => @repo,
        "credentials_ref" => @token
      }
    }
  }

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  defp new_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "finalize-pr-exists-ws-#{System.unique_integer([:positive])}",
        prefix: "fpe",
        config: @ws_github
      })

    ws
  end

  # In progress, as a dispatch leaves it — the PR moves it to Merging.
  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "finalize pr already exists",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  defp start_worker(task, ws, branch) do
    meta = %{branch: branch, target_branch: "main", merge_title: "Merge #{task.id}"}

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "widget", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    on_exit(fn -> stop_watchdog(task.id) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp stop_watchdog(task_id) do
    case Watchdog.whereis(task_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp run_for(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  test "422 'already exists' on the task's own branch is adopted — the run completes" do
    ws = new_workspace()
    task = new_task(ws)
    branch = "bugfix/931-already-open"
    pid = start_worker(task, ws, branch)

    {:ok, get_calls} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(get_calls), do: Agent.stop(get_calls) end)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/#{@owner}/#{@repo}/pulls"} ->
          # The look-before-create GET misses (an earlier run's create raced
          # this one's lookup); the reactive 422 fallback's own GET — the
          # second call — resolves the PR that create raced against.
          case Agent.get_and_update(get_calls, &{&1, &1 + 1}) do
            0 ->
              conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

            _ ->
              conn
              |> Plug.Conn.put_status(200)
              |> Req.Test.json([
                %{"number" => 68, "state" => "open", "head" => %{"ref" => branch}}
              ])
          end

        {"POST", "/repos/#{@owner}/#{@repo}/pulls"} ->
          conn
          |> Plug.Conn.put_status(422)
          |> Req.Test.json(%{
            "message" => "Validation Failed",
            "errors" => [
              %{
                "code" => "custom",
                "message" => "A pull request already exists for #{@owner}:#{branch}."
              }
            ]
          })

        _ ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    ref = Process.monitor(pid)
    send(pid, {:__claude_session_done__, "arb done"})

    # bd-741sid: the run ends with its PR open — finished and successful, not
    # failed — and the ticket carries the PR into Merging.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    run = run_for(task.id)
    assert run.status == :completed
    assert run.mr_ref

    {:ok, reloaded} = Ash.get(Issue, task.id)
    assert reloaded.pr_ref == run.mr_ref
    assert reloaded.state == :merging

    # No failure escalation was raised — this was a success, not a stranded run.
    escalations = Message.inbox("admiral", workspace_id: ws.id)
    refute Enum.any?(escalations, &(&1.directive_ref == task.id and &1.kind == :escalation))
  end

  test "an unrelated 422 on the task's own branch still fails the run" do
    ws = new_workspace()
    task = new_task(ws)
    branch = "bugfix/931-unrelated-422"
    pid = start_worker(task, ws, branch)

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/#{@owner}/#{@repo}/pulls"} ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        {"POST", "/repos/#{@owner}/#{@repo}/pulls"} ->
          conn
          |> Plug.Conn.put_status(422)
          |> Req.Test.json(%{"message" => "Validation Failed"})

        _ ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(fn -> Worker.state(pid).status == :failed end)

    snap = Worker.state(pid)
    assert {:merge_failed, _reason} = snap.meta.failure_reason

    {:ok, reloaded} = Ash.get(Issue, task.id)
    refute reloaded.status == :closed
    refute reloaded.pr_ref

    escalations = Message.inbox("admiral", workspace_id: ws.id)

    escalation =
      Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

    assert escalation
    assert escalation.body =~ branch
  end
end
