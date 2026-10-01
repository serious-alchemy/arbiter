defmodule ArbiterWeb.LiveHooksChromeQueriesTest do
  # bd-cixhhs: the page chrome (Layouts.app, the hooks, the dock) must not
  # re-query on every render, and must not read `workspaces` over and over.
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue

  @claude %{"agent" => %{"type" => ["claude"]}}

  # Every Repo query issued anywhere while `fun` runs, as `{source, sql}`.
  defp queries(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:arbiter, :repo, :query],
      fn _event, _m, meta, _c -> send(parent, {:query, ref, meta.source, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(ref)
    end

    Stream.repeatedly(fn ->
      receive do
        {:query, ^ref, source, sql} -> {source, sql}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  setup do
    ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default", config: @claude})

    {:ok, _} =
      Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
        provider: "claude"
      )

    %{ws: ws}
  end

  describe "Layouts.app render" do
    test "issues no DB queries when the chrome assigns are supplied" do
      {:ok, ws_id} = Arbiter.Quota.default_workspace_id()
      quota = Arbiter.Quota.list_latest_for_workspace(ws_id)

      assert quota != []

      found =
        queries(fn ->
          render_component(&ArbiterWeb.Layouts.app/1,
            flash: %{},
            quotas: quota,
            inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "x" end}],
            quota_on_exhaustion: :throttle,
            open_epic_count: 3
          )
        end)

      assert found == []
    end

    test "issues no DB queries even when the chrome assigns are omitted" do
      found =
        queries(fn ->
          render_component(&ArbiterWeb.Layouts.app/1,
            flash: %{},
            quotas: [],
            inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "x" end}]
          )
        end)

      assert found == []
    end
  end

  describe "chrome assigns on a live page" do
    test "the epic badge is refreshed on epic lifecycle events, not per render", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_async(view)

      found =
        queries(fn ->
          for _ <- 1..3, do: render(view)
        end)

      assert found == []
      refute has_element?(view, ~s(#nav-rail a[href="/epics"] [data-role="nav-badge"]))

      {:ok, _epic} = Ash.create(Issue, %{title: "badge", workspace_id: ws.id, issue_type: :epic})
      _ = render(view)

      assert has_element?(view, ~s(#nav-rail a[href="/epics"] [data-role="nav-badge"]), "1")
    end

    test "retyping an epic away from :epic drops the badge", %{conn: conn, ws: ws} do
      {:ok, epic} = Ash.create(Issue, %{title: "retype", workspace_id: ws.id, issue_type: :epic})
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_async(view)
      assert has_element?(view, ~s(#nav-rail a[href="/epics"] [data-role="nav-badge"]), "1")

      {:ok, _} = Ash.update(epic, %{issue_type: :task})
      _ = render(view)

      refute has_element?(view, ~s(#nav-rail a[href="/epics"] [data-role="nav-badge"]))
    end

    test "a connected mount reads workspaces at most twice", %{conn: conn} do
      # The first mount warms `QuotaCache`, whose cold fill legitimately reads
      # workspaces to decide which providers are in use. Before bd-cixhhs a
      # warm mount read `workspaces` 8 times on this page (10 cold).
      {:ok, warm, _html} = live(conn, ~p"/audit")
      render_async(warm)

      found =
        queries(fn ->
          {:ok, view, _html} = live(conn, ~p"/audit")
          render_async(view)
        end)

      workspace_reads = Enum.count(found, fn {source, _} -> source == "workspaces" end)
      assert workspace_reads <= 2, "workspaces read #{workspace_reads} times"
    end
  end

  describe "coordinator drawer" do
    test "mail not addressed to the coordinator triggers no refresh", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_async(view)

      found =
        queries(fn ->
          Phoenix.PubSub.broadcast(
            Arbiter.PubSub,
            Message.topic(ws.id),
            {:new_message, %{to_ref: "bd-someone-else", workspace_id: ws.id}}
          )

          _ = render(view)
        end)

      assert found == []
    end

    test "mail addressed to the coordinator still refreshes", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_async(view)

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          escalation_kind: :agent_raised,
          from_ref: "bd-x1",
          to_ref: Message.coordinator_ref(),
          body: "hello coordinator"
        })

      assert has_element?(view, "#coordinator-mailbox-list", "hello coordinator")
    end

    test "outstanding is a COUNT query, not a row read", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_async(view)

      found =
        queries(fn ->
          {:ok, _} =
            Message.send_mail(%{
              workspace_id: ws.id,
              kind: :escalation,
              escalation_kind: :agent_raised,
              from_ref: "bd-x2",
              to_ref: Message.coordinator_ref(),
              body: "count me"
            })

          _ = render(view)
        end)

      assert Enum.any?(found, fn {s, sql} -> s == "messages" and sql =~ "count(" end)
    end
  end
end
