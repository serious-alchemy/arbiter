defmodule ArbiterWeb.Api.IssueBulkLifecycleTest do
  @moduledoc "bd-3cyf8j: `POST /api/issues/{promote,demote,rank}` take `ids` and answer per id."
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{BulkResult, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "bulk-api-#{System.unique_integer([:positive])}",
        prefix: "bka"
      })

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp issue!(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp by_id(body), do: Map.new(body["results"], &{&1["id"], &1})

  test "mixed promote batch: ok + refused + not_found", %{conn: conn, ws: ws} do
    good = issue!(ws)
    gated = issue!(ws, %{issue_type: :feature, acceptance: nil})

    body =
      conn
      |> post("/api/issues/promote", %{"ids" => [good.id, gated.id, "bka-nope"]})
      |> json_response(200)

    r = by_id(body)
    assert r[good.id]["status"] == "ok"
    assert r[good.id]["ticket"]["state"] == "queued"
    assert r[gated.id]["status"] == "refused"
    assert r[gated.id]["reason"] =~ "acceptance"
    assert r["bka-nope"]["status"] == "not_found"
    assert body["counts"] == %{"total" => 3, "ok" => 1, "refused" => 1, "not_found" => 1}
    assert Ash.get!(Issue, gated.id).state == :backlog
  end

  test "shared acceptance_waived promotes a gated ticket", %{conn: conn, ws: ws} do
    gated = issue!(ws, %{issue_type: :feature, acceptance: nil})

    body =
      conn
      |> post("/api/issues/promote", %{"ids" => [gated.id], "acceptance_waived" => "spike"})
      |> json_response(200)

    assert body["counts"]["ok"] == 1
  end

  test "demote batch with a missing id", %{conn: conn, ws: ws} do
    a = issue!(ws)
    post(conn, "/api/issues/promote", %{"ids" => [a.id]})

    body =
      conn |> post("/api/issues/demote", %{"ids" => [a.id, "bka-nope"]}) |> json_response(200)

    r = by_id(body)
    assert r[a.id]["status"] == "ok"
    assert r["bka-nope"]["status"] == "not_found"
    assert Ash.get!(Issue, a.id).state == :backlog
  end

  test "rank batch keeps list order and carries band fields", %{conn: conn, ws: ws} do
    [a, b, c] = for _ <- 1..3, do: issue!(ws)

    body =
      conn
      |> post("/api/issues/rank", %{"ids" => [c.id, a.id, "bka-nope"], "top" => true})
      |> json_response(200)

    r = by_id(body)
    assert r[c.id]["status"] == "ok"
    assert Map.has_key?(r[c.id]["ticket"], "priority_band_position")
    assert r["bka-nope"]["status"] == "not_found"
    assert Ash.get!(Issue, c.id).rank < Ash.get!(Issue, a.id).rank
    assert Ash.get!(Issue, a.id).rank < Ash.get!(Issue, b.id).rank
  end

  test "rank batch with no move refuses each id", %{conn: conn, ws: ws} do
    a = issue!(ws)
    body = conn |> post("/api/issues/rank", %{"ids" => [a.id]}) |> json_response(200)
    assert [%{"status" => "refused", "reason" => reason}] = body["results"]
    assert reason =~ "exactly one"
  end

  test "cap and malformed ids are 4xx with a clear error", %{conn: conn} do
    ids = Enum.map(1..(BulkResult.max_batch() + 1), &"bka-#{&1}")
    resp = conn |> post("/api/issues/promote", %{"ids" => ids}) |> json_response(400)
    assert inspect(resp) =~ "at most #{BulkResult.max_batch()}"
    assert conn |> post("/api/issues/demote", %{"ids" => []}) |> json_response(400)
  end

  test "single-id routes are unchanged", %{conn: conn, ws: ws} do
    a = issue!(ws)
    body = conn |> post("/api/issues/#{a.id}/promote", %{}) |> json_response(200)
    assert body["id"] == a.id
    refute Map.has_key?(body, "results")
  end
end
