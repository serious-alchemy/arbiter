defmodule ArbiterWeb.Api.WorkerCurrentRunTest do
  @moduledoc """
  bd-1uu19b (ticket lifecycle 5/13): `arb worker list` (`GET /api/workers`)
  and `arb worker show` (`GET /api/workers/:task_id`) read one source —
  `Arbiter.Workers.Current` — and speak one run vocabulary (kind / state /
  outcome, `Arbiter.Workers.RunState`).
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    for snap <- Worker.list_children(), do: Worker.stop(snap.registry_key)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "wcr-ws-#{System.unique_integer([:positive])}", prefix: "wc"})

    {:ok, ticket} = Ash.create(Issue, %{title: "one run vocabulary", workspace_id: ws.id})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws, ticket: ticket}
  end

  defp implement_run(ticket, ws, attrs \\ %{}) do
    earlier = DateTime.add(DateTime.utc_now(), -600, :second)

    Ash.create!(
      Run,
      Map.merge(
        %{
          task_id: ticket.id,
          repo: "arbiter",
          workspace_id: ws.id,
          kind: :implement,
          state: :finished,
          outcome: :succeeded,
          role: "base",
          started_at: earlier,
          completed_at: DateTime.add(earlier, 300, :second)
        },
        attrs
      )
    )
  end

  defp start_fix_pass(ticket, ws) do
    {:ok, pid} =
      Worker.start(
        task_id: ticket.id,
        repo: "arbiter",
        workspace_id: ws.id,
        meta: %{role: :fix_pass}
      )

    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(pid) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp list_entry(conn, ticket_id, params \\ []) do
    conn
    |> get(~p"/api/workers?#{params}")
    |> json_response(200)
    |> Map.fetch!("data")
    |> Enum.filter(&(&1["task_id"] == ticket_id))
  end

  defp run_fields(map), do: Map.take(map, ["kind", "state", "outcome"])

  describe "an implement run followed by a fix_pass run" do
    test "list and show report the same current run: the fix pass, working", %{
      conn: conn,
      ws: ws,
      ticket: ticket
    } do
      implement_run(ticket, ws)
      start_fix_pass(ticket, ws)

      assert [entry] = list_entry(conn, ticket.id)
      show = conn |> get(~p"/api/workers/#{ticket.id}") |> json_response(200)

      assert run_fields(entry) == %{"kind" => "fix_pass", "state" => "working", "outcome" => nil}
      assert run_fields(show) == run_fields(entry)
      refute Map.has_key?(entry, "status")
      refute Map.has_key?(show, "status")
    end

    test "they still agree once the fix pass has finished", %{
      conn: conn,
      ws: ws,
      ticket: ticket
    } do
      implement_run(ticket, ws)
      pid = start_fix_pass(ticket, ws)
      :ok = Worker.fail(pid, "tests still red")

      assert [entry] = list_entry(conn, ticket.id)
      show = conn |> get(~p"/api/workers/#{ticket.id}") |> json_response(200)

      assert run_fields(entry) ==
               %{"kind" => "fix_pass", "state" => "finished", "outcome" => "failed"}

      assert run_fields(show) == run_fields(entry)
    end

    test "show lists the current run and the recent runs, each labelled with its kind", %{
      conn: conn,
      ws: ws,
      ticket: ticket
    } do
      implement_run(ticket, ws)
      start_fix_pass(ticket, ws)

      show = conn |> get(~p"/api/workers/#{ticket.id}") |> json_response(200)

      assert [current, earlier] = show["runs"]

      assert run_fields(current) == %{
               "kind" => "fix_pass",
               "state" => "working",
               "outcome" => nil
             }

      assert run_fields(earlier) ==
               %{"kind" => "implement", "state" => "finished", "outcome" => "succeeded"}

      assert current["current"] == true
      assert earlier["current"] == false
    end
  end

  describe "a ticket with no live run" do
    test "show reports its latest run in the same vocabulary, and list leaves it out", %{
      conn: conn,
      ws: ws,
      ticket: ticket
    } do
      implement_run(ticket, ws, %{outcome: :failed, failure_reason: "tests failed"})

      show = conn |> get(~p"/api/workers/#{ticket.id}") |> json_response(200)

      assert run_fields(show) ==
               %{"kind" => "implement", "state" => "finished", "outcome" => "failed"}

      assert show["failure_reason"] == "tests failed"
      assert [only] = show["runs"]
      assert only["current"] == true
      assert list_entry(conn, ticket.id) == []
    end

    test "404 when the ticket never had a run", %{conn: conn, ticket: ticket} do
      assert conn |> get(~p"/api/workers/#{ticket.id}") |> json_response(404)
    end
  end

  describe "a ReviewGate reviewer run" do
    # Reviewer workers carry `workspace_id: nil` on their own state
    # (`ReviewGate.spawn_worker/5`); the ticket's run still belongs to the
    # ticket's workspace, so a workspace-scoped listing must include it.
    test "is the ticket's current run, in the ticket's workspace", %{
      conn: conn,
      ws: ws,
      ticket: ticket
    } do
      review_id = ticket.id <> "#review"

      {:ok, pid} =
        Worker.start(
          task_id: review_id,
          repo: "arbiter",
          workspace_id: nil,
          meta: %{role: :reviewer, reviews: ticket.id}
        )

      on_exit(fn -> if Process.alive?(pid), do: Worker.stop(pid) end)

      assert [entry] = list_entry(conn, ticket.id, workspace_id: ws.id)
      assert entry["workspace_id"] == ws.id
      assert entry["run_task_id"] == review_id
      assert run_fields(entry) == %{"kind" => "review", "state" => "starting", "outcome" => nil}

      show = conn |> get(~p"/api/workers/#{ticket.id}") |> json_response(200)
      assert run_fields(show) == run_fields(entry)
    end

    test "is left out of another workspace's listing", %{conn: conn, ticket: ticket} do
      {:ok, pid} =
        Worker.start(
          task_id: ticket.id <> "#review",
          repo: "arbiter",
          workspace_id: nil,
          meta: %{role: :reviewer, reviews: ticket.id}
        )

      on_exit(fn -> if Process.alive?(pid), do: Worker.stop(pid) end)

      assert list_entry(conn, ticket.id, workspace_id: Ecto.UUID.generate()) == []
    end
  end
end
