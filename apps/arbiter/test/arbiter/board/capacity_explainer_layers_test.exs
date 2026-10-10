defmodule Arbiter.Board.CapacityExplainerLayersTest do
  @moduledoc """
  DC5 (bd-2c2a4g; `docs/design/provider-dynamic-concurrency.md` §9):
  `CapacityExplainer` gains the pool, node, repo and fair-share lines, and a
  Ready card's layer reason ("claude:default: 3 of 3 seats", "local 6 of 6"),
  both from the scheduler walk the board already planned. Presentation only:
  every string is the walk's own phrase or the `CapacityView` it was handed.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.CapacityExplainer

  @pool {"acct-1", "claude"}

  defp walk_entry(id, state, reason, cause, pair \\ nil) do
    %{id: id, state: state, reason: reason, wait_cause: cause, pair: pair, hold: nil, card: %{}}
  end

  defp board(entries, ready \\ []) do
    %{
      ready: ready,
      blocked: [],
      walk: %{
        entries: entries,
        placements: [],
        promote: nil,
        pools: %{@pool => %{label: "claude:default", budget: 3, seats: 3}},
        nodes: %{"local" => %{label: "local", cap: 6, used: 3}}
      }
    }
  end

  defp ready_card(id, hold \\ :no_slot) do
    %{id: id, hold: hold, reason: "no free worker slot", card: %{workspace_id: nil}}
  end

  describe "a card's layer" do
    test "a card the walk skips on the provider layer names the pool and its seats" do
      board =
        board(
          [
            walk_entry(
              "bd-a",
              :blocked,
              "waiting for claude:default: 3 of 3 seats (7d ahead of pace)",
              {:capacity, :provider}
            )
          ],
          [ready_card("bd-a")]
        )

      assert %{layers: %{"bd-a" => layer}} = CapacityExplainer.explain(board, mode: :shadow)
      assert layer.layer == :provider
      assert layer.state == :waiting
      assert layer.text == "Waiting for claude:default: 3 of 3 seats (7d ahead of pace)"
      assert layer.shadow? == true
    end

    test "the node, repo layers read the same way" do
      board =
        board([
          walk_entry(
            "bd-n",
            :blocked,
            "no machine slot for claude:default work: local 6 of 6",
            {:capacity, :node}
          ),
          walk_entry(
            "bd-r",
            :blocked,
            "repo vstim: 2 of 2 implementer runs",
            {:capacity, :repo}
          )
        ])

      %{layers: layers} = CapacityExplainer.explain(board, mode: :shadow)
      assert layers["bd-n"].layer == :node
      assert layers["bd-n"].text =~ "local 6 of 6"
      assert layers["bd-r"].layer == :repo
      assert layers["bd-r"].text == "Repo vstim: 2 of 2 implementer runs"
    end

    test "a planned card reads next, or starting, with its pair" do
      board =
        board([
          walk_entry("bd-1", :next, "next", nil, %{pool: @pool, node: "local"}),
          walk_entry(
            "bd-2",
            :starting,
            "starting — claude:default on local",
            nil,
            %{pool: @pool, node: "local"}
          )
        ])

      %{layers: layers} = CapacityExplainer.explain(board, mode: :shadow)
      assert %{state: :next, text: "Next — claude:default on local"} = layers["bd-1"]
      assert %{state: :starting, text: "Starting — claude:default on local"} = layers["bd-2"]
    end

    test "queued, own-hold and paused entries have no layer" do
      board =
        board([
          walk_entry("bd-q", :queued, "2 ahead in queue", :queued),
          walk_entry("bd-o", :blocked, "mutex", :own_hold),
          walk_entry("bd-p", :blocked, "paused", :paused)
        ])

      assert %{layers: layers} = CapacityExplainer.explain(board, mode: :shadow)
      assert layers == %{}
    end

    test "under enforce the layer is the decision, not a shadow" do
      board =
        board(
          [walk_entry("bd-a", :blocked, "waiting for x: 1 of 1 seats", {:capacity, :provider})],
          [ready_card("bd-a")]
        )

      assert %{layers: %{"bd-a" => %{shadow?: false}}} =
               CapacityExplainer.explain(board, mode: :enforce)
    end

    test "the hold the card already wears carries its layer" do
      board =
        board(
          [walk_entry("bd-a", :blocked, "waiting for x: 1 of 1 seats", {:capacity, :provider})],
          [ready_card("bd-a")]
        )

      assert %{holds: %{"bd-a" => hold}} = CapacityExplainer.explain(board, mode: :shadow)
      assert hold.layer.layer == :provider
      assert hold.layer.text =~ "x: 1 of 1 seats"
    end

    test "under legacy, or without a walk, there are no layers" do
      with_walk =
        board([walk_entry("bd-a", :blocked, "waiting", {:capacity, :provider})])

      assert %{layers: %{}} = legacy = CapacityExplainer.explain(with_walk, mode: :legacy)
      assert legacy.layers == %{}
      assert %{layers: %{}} = CapacityExplainer.explain(%{ready: [], blocked: []}, mode: :shadow)
    end
  end

  describe "budget lines" do
    @view %{
      admission: %{mode: "shadow", label: "shadow", decides: false, agreement: nil},
      pools: [
        %{
          account: "acct-1",
          pool: "claude",
          label: "claude:default",
          chip_label: "claude",
          budget: 3,
          seats: 3,
          free: 0,
          state: "full",
          reason: "ceiling max_concurrent 3 (quota allows 4: 5h binds)",
          change_command: "arb account set claude:default --max-concurrent N"
        },
        %{
          account: "acct-2",
          pool: "antigravity:gemini_models",
          label: "antigravity:default gemini",
          chip_label: "agy gemini",
          budget: 0,
          seats: 0,
          free: 0,
          state: "held_pace",
          reason: "weekly 0.43 used ≥ line 0.42",
          change_command: "arb account set antigravity:default --max-concurrent N"
        }
      ],
      machines: [
        %{id: "local", name: "local", cap: 6, live: 3, free: 3, state: "online"},
        %{id: "n1", name: "box", cap: nil, live: 1, free: nil, state: "online"}
      ],
      repos: [%{label: "vstim", cap: 2, used: 1}],
      fair_share: [%{text: "fair share: default holds 3 of claude's 4; vstim has a P1 waiting"}]
    }

    test "a line per pool: seats of budget, then the reason; labelled shadow" do
      assert %{budget: budget} =
               CapacityExplainer.explain(%{ready: [], blocked: []},
                 mode: :shadow,
                 capacity: @view
               )

      assert budget.label == "shadow"
      assert budget.shadow? == true

      assert [claude, agy] = budget.pools
      assert claude.text == "claude:default: 3 of 3 seats"
      assert claude.reason =~ "ceiling max_concurrent 3"
      assert claude.state == "full"
      assert claude.change == "arb account set claude:default --max-concurrent N"
      assert agy.text == "antigravity:default gemini: 0 of 0 seats"
    end

    test "a line per machine, per repo, and the fair-share lines" do
      %{budget: budget} =
        CapacityExplainer.explain(%{ready: [], blocked: []}, mode: :shadow, capacity: @view)

      assert [%{text: "local: 3 of 6 slots"}, %{text: "box: 1 running"}] = budget.machines
      assert [%{text: "repo vstim: 1 of 2 implementer runs"}] = budget.repos

      assert [%{text: "fair share: default holds 3 of claude's 4; vstim has a P1 waiting"}] =
               budget.fair_share
    end

    test "enforce is not labelled shadow" do
      %{budget: budget} =
        CapacityExplainer.explain(%{ready: [], blocked: []}, mode: :enforce, capacity: @view)

      assert budget.label == "enforce"
      assert budget.shadow? == false
    end

    test "no capacity view, no budget lines" do
      assert %{budget: nil} = CapacityExplainer.explain(%{ready: [], blocked: []}, mode: :shadow)
    end
  end
end
