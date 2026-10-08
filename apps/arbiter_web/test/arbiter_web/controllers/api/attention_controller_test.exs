defmodule ArbiterWeb.Api.AttentionControllerTest do
  @moduledoc "P-27: `GET /api/attention` over `Arbiter.Tasks.Attention.items/1`."
  use ArbiterWeb.ConnCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Tasks.{Attention, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "att-#{System.unique_integer([:positive])}", prefix: "att"})

    {:ok, ws2} =
      Ash.create(Workspace, %{name: "att2-#{System.unique_integer([:positive])}", prefix: "atw"})

    mine = open_with_attention(ws, "mine")
    handed = open_with_attention(ws, "handed")
    {:ok, _} = Attention.hand_off(handed.id, :operator, "yours")
    other = open_with_attention(ws2, "other")

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"),
     ws: ws,
     mine: mine,
     handed: handed,
     other: other}
  end

  defp open_with_attention(ws, title) do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    task = put_state!(task, :active)
    {:ok, _} = Attention.raise_cause(task.id, :run_crashed, "boom")
    task
  end

  defp ids(body), do: body["attention"] |> Enum.map(& &1["ticket_id"]) |> Enum.sort()

  test "lists the items of every workspace and both owners, echoing a null workspace", ctx do
    body = ctx.conn |> get(~p"/api/attention") |> json_response(200)

    assert body["workspace_id"] == nil
    assert body["attention_count"] == length(body["attention"])
    assert Enum.sort([ctx.mine.id, ctx.handed.id, ctx.other.id]) -- ids(body) == []

    item = Enum.find(body["attention"], &(&1["ticket_id"] == ctx.mine.id))
    assert item["owner"] == "coordinator"
    assert item["title"] == "mine"
    assert item["workspace_id"] == ctx.ws.id
  end

  test "owner= narrows to one owner", ctx do
    body = ctx.conn |> get(~p"/api/attention", %{owner: "operator"}) |> json_response(200)
    assert ctx.handed.id in ids(body)
    refute ctx.mine.id in ids(body)

    body = ctx.conn |> get(~p"/api/attention", %{owner: "coordinator"}) |> json_response(200)
    assert ctx.mine.id in ids(body)
    refute ctx.handed.id in ids(body)
  end

  test "workspace= scopes by id or name", ctx do
    for ref <- [ctx.ws.id, ctx.ws.name] do
      body = ctx.conn |> get(~p"/api/attention", %{workspace: ref}) |> json_response(200)
      assert body["workspace_id"] == ctx.ws.id
      assert ids(body) == Enum.sort([ctx.mine.id, ctx.handed.id])
    end
  end

  test "an unknown owner is a 422", ctx do
    conn = get(ctx.conn, ~p"/api/attention", %{owner: "nobody"})
    assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
  end

  test "an unknown workspace is a 404", ctx do
    conn = get(ctx.conn, ~p"/api/attention", %{workspace: "no-such-ws"})
    assert json_response(conn, 404)
  end
end
