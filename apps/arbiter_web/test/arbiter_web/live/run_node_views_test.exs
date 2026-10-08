defmodule ArbiterWeb.RunNodeViewsTest do
  @moduledoc """
  bd-1b4k9r: every dashboard view that lists or shows a run says where it
  executes — the node's name (or `local`) where there is room, a node badge
  where space is tight.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  @async_timeout 5_000

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.registry_key)

    ws = Ash.create!(Workspace, %{name: "rnv-ws-#{System.unique_integer([:positive])}"})
    ticket = Ash.create!(Issue, %{title: "where it runs", workspace_id: ws.id})

    node =
      Ash.create!(
        Arbiter.Nodes.Node,
        %{
          name: "gpu-box",
          credential_hash: "h-#{System.unique_integer([:positive])}",
          credential_prefix: "p",
          enrolled_at: DateTime.utc_now()
        },
        action: :enroll
      )

    {:ok, ws: ws, ticket: ticket, node: node}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    _ = render_async(view, @async_timeout)
    view
  end

  defp history_run(ctx, attrs) do
    Ash.create!(
      Run,
      Map.merge(
        %{
          task_id: ctx.ticket.id,
          task_title: "where it runs",
          repo: "arbiter",
          workspace_id: ctx.ws.id,
          kind: :implement,
          state: :finished,
          outcome: :succeeded,
          role: "base",
          provider: "claude",
          started_at: DateTime.add(DateTime.utc_now(), -120, :second),
          completed_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp start_run(ctx, node_id) do
    {:ok, pid} = Worker.start(task_id: ctx.ticket.id, repo: "test/repo", workspace_id: ctx.ws.id)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(ctx.ticket.id, :normal) end)
    :ok = Worker.advance(pid, :implement)
    if node_id, do: :ok = Worker.report(pid, :node_id, node_id)
    pid
  end

  test "run history rows badge a remote run and leave a local one alone", %{conn: conn} = ctx do
    remote = history_run(ctx, %{node_id: ctx.node.id})
    local = history_run(ctx, %{})

    view = open(conn, ~p"/workers/history")
    html = render(view)

    assert html =~ ~s(href="/workers/history/#{remote.id}")
    assert html =~ ~s(href="/workers/history/#{local.id}")

    assert has_element?(
             view,
             ~s(a[href="/workers/history/#{remote.id}"] [data-node-badge="gpu-box"])
           )

    refute has_element?(view, ~s(a[href="/workers/history/#{local.id}"] [data-node-badge]))
  end

  test "run detail names the node, or says local", %{conn: conn} = ctx do
    local = history_run(ctx, %{})
    view = open(conn, ~p"/workers/history/#{local.id}")

    assert has_element?(view, ~s(#run-node-local [data-run-node="local"]))
  end

  test "workers list says where each live worker runs", %{conn: conn} = ctx do
    start_run(ctx, ctx.node.id)

    view = open(conn, ~p"/workers")

    assert has_element?(view, ~s(#workers [data-run-node="gpu-box"][data-remote="true"]))
  end

  test "workers list says local for a primary worker", %{conn: conn} = ctx do
    start_run(ctx, nil)

    view = open(conn, ~p"/workers")

    assert has_element?(view, ~s(#workers [data-run-node="local"][data-remote="false"]))
  end

  test "worker detail has a Runs on item", %{conn: conn} = ctx do
    start_run(ctx, ctx.node.id)

    view = open(conn, ~p"/workers/#{ctx.ticket.id}")

    assert has_element?(view, ~s(#worker-detail-where[data-run-node="gpu-box"]))
  end

  test "ticket page: run roster badge, expanded header and current run", %{conn: conn} = ctx do
    remote = history_run(ctx, %{node_id: ctx.node.id})

    view = open(conn, ~p"/tasks/#{ctx.ticket.id}")
    assert has_element?(view, ~s([data-node-badge="gpu-box"]))

    render_click(view, "toggle_run", %{"run" => remote.id})
    assert has_element?(view, ~s(#run-where-#{remote.id}[data-run-node="gpu-box"]))
  end

  test "ticket page: the current run panel says where it runs", %{conn: conn} = ctx do
    start_run(ctx, ctx.node.id)

    view = open(conn, ~p"/tasks/#{ctx.ticket.id}")

    assert has_element?(view, ~s(#worker-where[data-run-node="gpu-box"]))
  end
end
