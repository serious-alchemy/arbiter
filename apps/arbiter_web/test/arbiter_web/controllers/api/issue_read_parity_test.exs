defmodule ArbiterWeb.Api.IssueReadParityTest do
  @moduledoc """
  P-13: the REST read side agrees with MCP. `GET /api/issues` rows carry the
  lifecycle projection (`column`, `step`, `blocked_by`); `GET /api/issues/ready`
  is the one Ready set — a queued ticket whose run registered early is not in it,
  exactly as on `ticket_ready` — and a held card carries `hold_reason`; a
  hand-off and a rank return the record the MCP tools return.
  """
  use ArbiterWeb.ConnCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rd-par-#{System.unique_integer([:positive])}", prefix: "rdp"})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp ticket(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp queued(ws, attrs \\ %{}), do: ws |> ticket(attrs) |> put_state!(:queued)

  describe "GET /api/issues" do
    test "each row carries column, step and blocked_by", %{conn: conn, ws: ws} do
      backlog = ticket(ws)
      ready = queued(ws)

      body = conn |> get(~p"/api/issues?workspace_id=#{ws.id}") |> json_response(200)
      rows = Map.new(body["data"], &{&1["id"], &1})

      assert %{"column" => "backlog", "blocked_by" => []} = rows[backlog.id]
      assert %{"column" => "ready", "step" => nil, "blocked_by" => []} = rows[ready.id]
      # Still the full record.
      assert Map.has_key?(rows[ready.id], "description")
    end

    test "a Ready row carries the scheduler's hold_reason", %{conn: conn, ws: ws} do
      ready = queued(ws)

      body = conn |> get(~p"/api/issues?workspace_id=#{ws.id}") |> json_response(200)
      assert [%{"hold_reason" => reason}] = Enum.filter(body["data"], &(&1["id"] == ready.id))
      assert is_binary(reason)
    end
  end

  describe "GET /api/issues/ready" do
    test "a queued ticket with an early-registered run is Ready on neither surface",
         %{conn: conn, ws: ws} do
      early = queued(ws, %{priority: 2})
      other = queued(ws, %{priority: 1})

      {:ok, pid} = Worker.start(task_id: early.id, repo: "arbiter", workspace_id: ws.id)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert {:ok, %{state: :queued}} = Ash.get(Issue, early.id)

      body = conn |> get(~p"/api/issues/ready?workspace_id=#{ws.id}") |> json_response(200)
      assert Enum.map(body["data"], & &1["id"]) == [other.id]
      assert [%{"column" => "ready", "hold_reason" => _}] = body["data"]

      scope = %Scope{tier: :coordinator, workspace_id: ws.id}
      assert {:ok, %{tasks: tasks}} = Tools.task_ready(scope, %{})
      assert Enum.map(tasks, & &1.id) == [other.id]
    end
  end

  describe "PATCH /api/issues/:id/rank" do
    test "reports where the ticket landed in its priority band", %{conn: conn, ws: ws} do
      _a = ticket(ws, %{priority: 2})
      b = ticket(ws, %{priority: 2})

      body = conn |> patch(~p"/api/issues/#{b.id}/rank", %{top: true}) |> json_response(200)

      assert body["id"] == b.id
      assert body["priority_band_position"] == 0
      assert body["priority_band_size"] == 2
    end
  end

  describe "POST /api/issues/:id/handoff" do
    test "returns the ticket with its attention, as ticket_handoff does", %{conn: conn, ws: ws} do
      t = ws |> ticket() |> put_state!(:active)
      {:ok, _} = Attention.raise_cause(t.id, :run_crashed, "boom")

      body = conn |> post(~p"/api/issues/#{t.id}/handoff", %{note: "yours"}) |> json_response(200)

      assert body["id"] == t.id
      assert body["attention_owner"] == "operator"
      assert %{"owner" => "operator"} = body["attention"]
    end
  end
end
