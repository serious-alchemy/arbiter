defmodule ArbiterWeb.Api.IssueBulkPatchTest do
  @moduledoc "bd-cvyx6j: bulk `PATCH /api/issues`, `POST /api/issues/{close,verify}`."
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{BulkResult, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "bp-api-#{System.unique_integer([:positive])}", prefix: "bpa"})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp issue!(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp verifying!(ws) do
    Enum.reduce([:promote, :start, :await_verification], issue!(ws), fn tr, acc ->
      {:ok, next} = Ash.update(acc, %{}, action: tr)
      next
    end)
  end

  defp by_id(body), do: Map.new(body["results"], &{&1["id"], &1})

  test "bulk update: one patch, mixed result", %{conn: conn, ws: ws} do
    a = issue!(ws)
    b = issue!(ws)

    body =
      conn
      |> patch("/api/issues", %{"ids" => [a.id, b.id, "bpa-nope"], "patch" => %{"priority" => 1}})
      |> json_response(200)

    r = by_id(body)
    assert r[a.id]["status"] == "ok"
    assert r["bpa-nope"]["status"] == "not_found"
    assert body["counts"] == %{"total" => 3, "ok" => 2, "refused" => 0, "not_found" => 1}
    assert Ash.get!(Issue, b.id).priority == 1
  end

  test "bulk update: invalid field refuses that id only", %{conn: conn, ws: ws} do
    a = issue!(ws)

    body =
      conn
      |> patch("/api/issues", %{"ids" => [a.id], "patch" => %{"bogus_field" => 1}})
      |> json_response(200)

    assert [%{"status" => "refused"}] = body["results"]
  end

  test "bulk notes replace needs confirmation; append_notes does not", %{conn: conn, ws: ws} do
    a = issue!(ws, %{notes: "old"})

    assert conn
           |> patch("/api/issues", %{"ids" => [a.id], "patch" => %{"notes" => "new"}})
           |> json_response(400)

    assert Ash.get!(Issue, a.id).notes == "old"

    body =
      conn
      |> patch("/api/issues", %{
        "ids" => [a.id],
        "patch" => %{"notes" => "new"},
        "confirm_replace_notes" => true
      })
      |> json_response(200)

    assert body["counts"]["ok"] == 1
    assert Ash.get!(Issue, a.id).notes == "new"

    conn
    |> patch("/api/issues", %{"ids" => [a.id], "patch" => %{"append_notes" => "more"}})
    |> json_response(200)

    assert Ash.get!(Issue, a.id).notes =~ "more"
  end

  test "bulk update needs a patch", %{conn: conn, ws: ws} do
    a = issue!(ws)
    assert conn |> patch("/api/issues", %{"ids" => [a.id]}) |> json_response(400)
  end

  test "bulk close: ok + not_found", %{conn: conn, ws: ws} do
    a = issue!(ws)

    body =
      conn
      |> post("/api/issues/close", %{"ids" => [a.id, "bpa-nope"], "reason" => "swept"})
      |> json_response(200)

    r = by_id(body)
    assert r[a.id]["status"] == "ok"
    assert r["bpa-nope"]["status"] == "not_found"
    assert Ash.get!(Issue, a.id).state == :closed
  end

  test "bulk verify: observed closes, failed reopens each, parked check per id",
       %{conn: conn, ws: ws} do
    a = verifying!(ws)
    b = verifying!(ws)
    c = verifying!(ws)
    idle = issue!(ws)

    body =
      conn
      |> post("/api/issues/verify", %{
        "ids" => [a.id, idle.id],
        "outcome" => "observed",
        "evidence" => "live"
      })
      |> json_response(200)

    r = by_id(body)
    assert r[a.id]["status"] == "ok"
    assert r[idle.id]["status"] == "refused"
    assert Ash.get!(Issue, a.id).state == :closed

    assert conn
           |> post("/api/issues/verify", %{
             "ids" => [b.id, c.id],
             "outcome" => "failed",
             "evidence" => "broken"
           })
           |> json_response(200)
           |> Map.get("counts")
           |> Map.get("ok") == 2

    single = verifying!(ws)

    conn
    |> post("/api/issues/#{single.id}/verify", %{"outcome" => "failed", "evidence" => "x"})
    |> json_response(200)

    expected = Ash.get!(Issue, single.id).state
    assert expected != :verifying
    assert Ash.get!(Issue, b.id).state == expected
    assert Ash.get!(Issue, c.id).state == expected
  end

  test "batch cap enforced", %{conn: conn} do
    ids = Enum.map(1..(BulkResult.max_batch() + 1), &"bpa-#{&1}")
    assert conn |> post("/api/issues/close", %{"ids" => ids}) |> json_response(400)
  end
end
