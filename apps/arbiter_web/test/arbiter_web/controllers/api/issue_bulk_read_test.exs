defmodule ArbiterWeb.Api.IssueBulkReadTest do
  @moduledoc "bd-7sxpln: `GET /api/issues` with `include=` and `ids=` — bulk ticket reads."
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "bulk-#{System.unique_integer([:positive])}", prefix: "bk"})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp ticket(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp count_queries(fun) do
    ref = make_ref()
    me = self()
    id = {__MODULE__, ref}

    :telemetry.attach(
      id,
      [:arbiter, :repo, :query],
      fn _, _, _, _ -> send(me, {:q, ref}) end,
      nil
    )

    try do
      fun.()
      drain(ref, 0)
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, n) do
    receive do
      {:q, ^ref} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  defp grow(ws, n) do
    epic = ticket(ws, %{issue_type: :epic})

    for _ <- 1..n do
      child = ticket(ws)
      other = ticket(ws)
      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      {:ok, _} = Dependencies.add(child.id, other.id, :depends_on)
    end

    epic
  end

  test "default rows carry no edge fields", %{conn: conn, ws: ws} do
    grow(ws, 1)
    body = conn |> get(~p"/api/issues?workspace_id=#{ws.id}") |> json_response(200)
    refute Enum.any?(body["data"], &Map.has_key?(&1, "parent_id"))
    refute Enum.any?(body["data"], &Map.has_key?(&1, "depends_on"))
  end

  test "include=parent,deps adds parent_id and gating edges", %{conn: conn, ws: ws} do
    epic = grow(ws, 1)

    body =
      conn |> get(~p"/api/issues?workspace_id=#{ws.id}&include=parent,deps") |> json_response(200)

    rows = Map.new(body["data"], &{&1["id"], &1})
    assert rows[epic.id]["parent_id"] == nil

    [child] = Enum.filter(Map.values(rows), &(&1["parent_id"] == epic.id))
    assert [dep] = child["depends_on"]
    assert rows[dep]["blocks"] == [child["id"]]
  end

  test "an unknown include value is a 4xx", %{conn: conn, ws: ws} do
    conn = get(conn, ~p"/api/issues?workspace_id=#{ws.id}&include=bogus")
    assert conn.status in 400..499
  end

  test "epic rows carry child_closed/child_total", %{conn: conn, ws: ws} do
    epic = grow(ws, 2)
    body = conn |> get(~p"/api/issues?workspace_id=#{ws.id}") |> json_response(200)
    row = Enum.find(body["data"], &(&1["id"] == epic.id))
    assert row["child_total"] == 2
    assert row["child_closed"] == 0
  end

  test "query count is constant in the number of tickets", %{conn: conn, ws: ws} do
    grow(ws, 2)
    url = ~p"/api/issues?workspace_id=#{ws.id}&include=parent,deps"
    get(conn, url)
    small = count_queries(fn -> get(conn, url) end)

    grow(ws, 10)
    large = count_queries(fn -> get(conn, url) end)
    assert small == large
  end

  test "ids= returns the named tickets and reports unknown ids per id", %{conn: conn, ws: ws} do
    a = ticket(ws)
    b = ticket(ws)
    _other = ticket(ws)

    body =
      conn
      |> get("/api/issues?workspace_id=#{ws.id}&ids=#{a.id},nope,#{b.id}")
      |> json_response(200)

    assert Enum.map(body["data"], & &1["id"]) == [a.id, b.id]
    assert body["not_found"] == ["nope"]
  end
end
