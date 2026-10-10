defmodule ArbiterWeb.BoardCapacityStripLiveTest do
  @moduledoc """
  DC5 (bd-2c2a4g; `docs/design/provider-dynamic-concurrency.md` §9): the board's
  capacity strip (`#board-capacity`: one chip per pool and per machine, each
  opening a popup that explains the budget) and the per-card layer reasons.
  Everything is labelled with the `scheduler_admission` mode: under `shadow`
  the budgets are shown but today's gate and caps still decide.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  @async_timeout 5_000
  @acct "acct-claude"
  @agy "acct-agy"

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Autopilot.resume(Autopilot)
    {:ok, _} = Settings.set_nodes_local_max_workers(nil)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "strip-#{System.unique_integer([:positive])}",
        prefix: "sp#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp mode!(mode), do: {:ok, _} = Settings.set_scheduler_admission(mode)

  defp window do
    %{
      window: "5h",
      side: "primary",
      status: "ok",
      used: 0.19,
      used_now: 0.195,
      line_now: 0.4015,
      line_at_h: 0.8015,
      reset_in_h: 2.99,
      rho: 0.0667,
      rho_source: "prior",
      rho_min: 0.0167,
      b: 0.0,
      horizon_h: 2.0,
      n: 4.55
    }
  end

  defp claude_pool(overrides \\ %{}) do
    Map.merge(
      %{
        account: @acct,
        account_name: "claude:default",
        pool: "claude",
        label: "claude:default",
        chip_label: "claude",
        budget: 3,
        raw: 4.55,
        seats: 3,
        free: 0,
        state: "full",
        binding: "ceiling",
        quota_binding: "5h",
        exempt_budget: 5,
        reason: "ceiling max_concurrent 3 (quota allows 4: 5h binds, 0.19 used)",
        windows: [window()],
        ceiling: %{max_concurrent: 3, share: nil},
        horizon_h: 2.0,
        pending_rise: %{raw: 4.6, since: ~U[2026-10-10 14:02:00Z]},
        holders: ["bd-aaa111", "bd-bbb222", "bd-ccc333"],
        recent_changes: [
          %{at: ~U[2026-10-10 13:00:00Z], from: 4, to: 3, reason: "5h line"}
        ],
        change_command: "arb account set claude:default --max-concurrent N"
      },
      overrides
    )
  end

  defp agy_pool do
    %{
      account: @agy,
      account_name: "antigravity:default",
      pool: "antigravity:gemini_models",
      label: "antigravity:default gemini",
      chip_label: "agy gemini",
      budget: 0,
      raw: 0.0,
      seats: 0,
      free: 0,
      state: "held_pace",
      binding: "window:weekly",
      quota_binding: "weekly",
      exempt_budget: nil,
      reason: "weekly 0.43 used ≥ line 0.42",
      windows: [],
      ceiling: %{max_concurrent: nil, share: nil},
      horizon_h: 2.0,
      pending_rise: nil,
      holders: [],
      recent_changes: [],
      change_command: "arb account set antigravity:default --max-concurrent N"
    }
  end

  defp view(mode, pools) do
    %{
      admission: %{
        mode: mode,
        label: mode,
        decides: mode == "enforce",
        agreement: nil
      },
      pools: pools,
      machines: [
        %{id: "local", name: "local", cap: 6, live: 3, free: 3, state: "online"},
        %{id: "n1", name: "box", cap: 4, live: 4, free: 0, state: "online"}
      ],
      repos: [],
      fair_share: []
    }
  end

  defp stub_view(view) do
    :ok = :meck.new(Arbiter.Board.CapacityView, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Arbiter.Board.CapacityView) end)
    :meck.expect(Arbiter.Board.CapacityView, :status, fn _opts -> view end)
  end

  defp mount_board(conn) do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    view
  end

  defp ready_ticket(ws, title) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- fixture"})

    {:ok, issue} = Ash.update(issue, %{}, action: :promote_to_ready)
    issue
  end

  describe "the strip" do
    test "one chip per pool and per machine, each with seats of budget", %{conn: conn} do
      mode!("shadow")
      stub_view(view("shadow", [claude_pool(), agy_pool()]))
      lv = mount_board(conn)

      assert has_element?(lv, "#board-capacity")
      assert lv |> element("#pool-chip-acct-claude-claude-trigger") |> render() =~ "claude 3/3"
      assert has_element?(lv, "#pool-chip-acct-claude-claude [data-chip-state='full']")

      assert lv
             |> element("#pool-chip-acct-agy-antigravity-gemini-models-trigger")
             |> render() =~ "agy gemini 0/0"

      assert has_element?(
               lv,
               "#pool-chip-acct-agy-antigravity-gemini-models [data-chip-state='held_pace']"
             )

      assert lv |> element("#node-chip-local-trigger") |> render() =~ "local 3/6"
      assert has_element?(lv, "#node-chip-box [data-chip-state='full']")
    end

    test "is labelled shadow, and says today's gate still decides", %{conn: conn} do
      mode!("shadow")
      stub_view(view("shadow", [claude_pool()]))
      lv = mount_board(conn)

      assert lv |> element("#board-capacity-mode") |> render() =~ "shadow"
      assert has_element?(lv, "#board-capacity[data-admission='shadow']")
      assert has_element?(lv, "#board-capacity-mode-note", "today's gate and caps still decide")
    end

    test "under enforce it is not labelled shadow", %{conn: conn} do
      mode!("enforce")
      stub_view(view("enforce", [claude_pool()]))
      lv = mount_board(conn)

      assert has_element?(lv, "#board-capacity[data-admission='enforce']")
      refute has_element?(lv, "#board-capacity-mode-note")
    end

    test "without a pool the machines still show", %{conn: conn} do
      stub_view(view("legacy", []))
      lv = mount_board(conn)

      assert has_element?(lv, "#node-chip-local")
      refute has_element?(lv, "[id^='pool-chip-']")
    end

    test "a capacity read that fails leaves the board as it was", %{conn: conn} do
      :ok = :meck.new(Arbiter.Board.CapacityView, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Arbiter.Board.CapacityView) end)
      :meck.expect(Arbiter.Board.CapacityView, :status, fn _opts -> raise "boom" end)

      lv = mount_board(conn)

      assert has_element?(lv, "#board-slots")
      refute has_element?(lv, "#board-capacity")
    end
  end

  describe "a pool's popup" do
    setup %{conn: conn} do
      mode!("shadow")
      stub_view(view("shadow", [claude_pool()]))
      %{lv: mount_board(conn)}
    end

    test "opens on a real button wired to its panel", %{lv: lv} do
      assert has_element?(
               lv,
               "#pool-chip-acct-claude-claude-trigger[type='button'][aria-controls='pool-chip-acct-claude-claude-panel']"
             )
    end

    test "gives the reason, labelled shadow", %{lv: lv} do
      panel = lv |> element("#pool-chip-acct-claude-claude-panel") |> render()
      assert panel =~ "ceiling max_concurrent 3"
      assert panel =~ "Shadow"
      assert has_element?(lv, "#pool-chip-acct-claude-claude-panel [data-budget-reason]")
    end

    test "shows the binding window with every number behind the budget", %{lv: lv} do
      assert has_element?(
               lv,
               "#pool-chip-acct-claude-claude-panel [data-window='5h'][data-binding='true']"
             )

      window = lv |> element("#pool-chip-acct-claude-claude-panel [data-window='5h']") |> render()
      assert window =~ "0.19"
      assert window =~ "0.40"
      assert window =~ "0.80"
      assert window =~ "6.7%"
      assert window =~ "prior"
      assert window =~ "4.55"
    end

    test "names the ceiling, the pending rise and the exempt budget", %{lv: lv} do
      panel = lv |> element("#pool-chip-acct-claude-claude-panel") |> render()

      assert has_element?(lv, "#pool-chip-acct-claude-claude-panel [data-ceiling]", "3")
      assert has_element?(lv, "#pool-chip-acct-claude-claude-panel [data-pending-rise]", "4.6")
      assert panel =~ "14:02Z"
      assert has_element?(lv, "#pool-chip-acct-claude-claude-panel [data-exempt-budget]", "5")
    end

    test "lists who holds the seats, recent changes and the command", %{lv: lv} do
      for id <- ~w(bd-aaa111 bd-bbb222 bd-ccc333) do
        assert has_element?(lv, "#pool-chip-acct-claude-claude-panel [data-seat-holder='#{id}']")
      end

      assert has_element?(
               lv,
               "#pool-chip-acct-claude-claude-panel [data-recent-change]",
               "5h line"
             )

      assert has_element?(
               lv,
               "#pool-chip-acct-claude-claude-panel [data-change-command]",
               "arb account set claude:default --max-concurrent"
             )
    end
  end

  describe "a machine's popup" do
    test "says how full the machine is and what changes its cap", %{conn: conn} do
      mode!("shadow")
      stub_view(view("shadow", []))
      lv = mount_board(conn)

      panel = lv |> element("#node-chip-box-panel") |> render()
      assert panel =~ "4 of 4"
      assert panel =~ "arb node set"
    end
  end

  describe "the cap popup's budget lines" do
    test "lists each pool, machine, repo and fair-share line, labelled shadow", %{conn: conn} do
      mode!("shadow")

      stub_view(
        view("shadow", [claude_pool(), agy_pool()])
        |> Map.put(:repos, [%{label: "vstim", cap: 2, used: 1}])
        |> Map.put(:fair_share, [%{text: "fair share: default holds 3 of claude's 4"}])
      )

      lv = mount_board(conn)

      assert has_element?(lv, "#board-slot-cap-budgets", "Shadow")

      assert has_element?(
               lv,
               "#board-slot-cap-budgets [data-budget-pool]",
               "claude:default: 3 of 3 seats"
             )

      assert has_element?(
               lv,
               "#board-slot-cap-budgets [data-budget-pool]",
               "antigravity:default gemini: 0 of 0 seats"
             )

      assert has_element?(lv, "#board-slot-cap-budgets [data-budget-machine]", "local: 3 of 6")
      assert has_element?(lv, "#board-slot-cap-budgets [data-budget-repo]", "repo vstim: 1 of 2")
      assert has_element?(lv, "#board-slot-cap-budgets [data-budget-fair-share]", "fair share")
    end

    test "has no budget section when there is nothing to show", %{conn: conn} do
      :ok = :meck.new(Arbiter.Board.CapacityView, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Arbiter.Board.CapacityView) end)
      :meck.expect(Arbiter.Board.CapacityView, :status, fn _opts -> raise "boom" end)

      lv = mount_board(conn)
      refute has_element?(lv, "#board-slot-cap-budgets")
    end
  end

  describe "per-card layer reasons" do
    test "a Ready card the walk would start beside the first reads starting, labelled shadow", %{
      conn: conn,
      ws: ws
    } do
      mode!("shadow")
      first = ready_ticket(ws, "first")
      second = ready_ticket(ws, "second")
      lv = mount_board(conn)

      starting =
        Enum.find([first, second], fn t ->
          has_element?(lv, "[data-layer-reason='#{t.id}'][data-layer-state='starting']")
        end)

      assert starting

      assert lv |> element("[data-layer-reason='#{starting.id}']") |> render() =~ "Shadow walk"
      assert lv |> element("[data-layer-reason='#{starting.id}']") |> render() =~ "Starting"
    end

    test "the hold badge's popup carries the layer too", %{conn: conn, ws: ws} do
      mode!("shadow")
      {:ok, _} = Settings.set_nodes_local_max_workers(0)
      ticket = ready_ticket(ws, "no slot at all")
      lv = mount_board(conn)

      assert has_element?(lv, "#hold-#{ticket.id}-panel [data-hold-layer]", "Shadow walk")
      assert has_element?(lv, "#hold-#{ticket.id}-panel [data-hold-layer]", "no machine")
    end

    test "legacy shows no layer", %{conn: conn, ws: ws} do
      mode!(nil)
      ticket = ready_ticket(ws, "legacy card")
      lv = mount_board(conn)

      refute has_element?(lv, "[data-layer-reason='#{ticket.id}']")
    end
  end
end
