defmodule Arbiter.Board.AdmissionShadowTest do
  @moduledoc """
  What `scheduler_admission: shadow` records (DC6, provider-dynamic-concurrency
  §10.2): beside every dispatch, the walk's decision as
  `routing_decision.admission_shadow`; on every hold change, one
  `admission_shadow_events` row with both decisions and every budget —
  throttled by change, not by tick.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.AdmissionShadow
  alias Arbiter.Board.AdmissionShadowEvent

  @claude {"acct-1", "claude"}
  @gpt {"acct-2", "antigravity:claude_and_gpt_models"}

  defp legacy_entry(id, state, opts \\ []) do
    %{
      id: id,
      state: state,
      reason: Keyword.get(opts, :reason, "next up — dispatching..."),
      hold: Keyword.get(opts, :hold),
      card: %{id: id}
    }
  end

  defp walk_entry(id, state, wait_cause, opts \\ []) do
    %{
      id: id,
      state: state,
      reason: Keyword.get(opts, :reason, "next up — dispatching..."),
      hold: nil,
      card: %{id: id},
      wait_cause: wait_cause,
      pair: Keyword.get(opts, :pair)
    }
  end

  @pools %{
    @claude => %{
      budget: 2,
      seats: 3,
      cap: 3,
      label: "claude:default",
      binding: {:window, "5h"},
      reason: "5h binds"
    },
    @gpt => %{
      budget: 4,
      seats: 0,
      cap: nil,
      label: "antigravity:default claude-gpt",
      reason: "5h room"
    }
  }

  # Today dispatches bd-a; the walk would hold bd-a (its pool is full) and place bd-b.
  defp board(overrides \\ %{}) do
    Map.merge(
      %{
        promote: "bd-a",
        ready: [
          legacy_entry("bd-a", :next),
          legacy_entry("bd-b", :queued, reason: "1 ahead in queue")
        ],
        walk: %{
          promote: "bd-b",
          placements: [%{id: "bd-b", pool: @gpt, node: "local"}],
          entries: [
            walk_entry("bd-a", :blocked, {:capacity, :provider},
              reason: "waiting for claude:default: 3 of 2 seats (5h binds)"
            ),
            walk_entry("bd-b", :next, nil, pair: %{pool: @gpt, node: "local"})
          ],
          pools: @pools,
          nodes: %{"local" => %{cap: 6, used: 3, label: "local"}}
        }
      },
      Map.new(overrides)
    )
  end

  describe "mode/0" do
    test "reads the installation setting; legacy by default" do
      on_exit(fn -> Arbiter.Settings.set_scheduler_admission(nil) end)
      assert AdmissionShadow.mode() == :legacy
      {:ok, _} = Arbiter.Settings.set_scheduler_admission("shadow")
      assert AdmissionShadow.mode() == :shadow
    end
  end

  describe "dispatch_record/3: beside every dispatch" do
    test "a disagreement names the walk's pick, its pair, and why it did not pick ours" do
      record = AdmissionShadow.dispatch_record(board(), :shadow, "bd-a")

      assert %{
               "policy" => "shadow",
               "dispatched" => "bd-a",
               "pick" => "bd-b",
               "account_id" => "acct-2",
               "pool" => "antigravity:claude_and_gpt_models",
               "pool_label" => "antigravity:default claude-gpt",
               "node" => "local",
               "agrees" => false,
               "comparable" => true,
               "cause" => "capacity:provider",
               "reason" => "waiting for claude:default: 3 of 2 seats (5h binds)",
               "placements" => 1
             } = record

      # JSON-safe: it is stored on the run as-is.
      assert record == record |> Jason.encode!() |> Jason.decode!()
    end

    test "an agreement carries no cause" do
      board =
        board(%{
          walk: %{
            promote: "bd-a",
            placements: [%{id: "bd-a", pool: @claude, node: "local"}],
            entries: [walk_entry("bd-a", :next, nil, pair: %{pool: @claude, node: "local"})],
            pools: @pools,
            nodes: %{}
          }
        })

      assert %{"agrees" => true, "comparable" => true, "cause" => nil, "reason" => nil} =
               AdmissionShadow.dispatch_record(board, :enforce, "bd-a")

      assert %{"policy" => "enforce"} = AdmissionShadow.dispatch_record(board, :enforce, "bd-a")
    end

    test "a walk with no candidate is not comparable" do
      board =
        board(%{
          walk: %{
            promote: nil,
            placements: [],
            entries: [
              walk_entry("bd-a", :blocked, {:capacity, :node},
                reason: "waiting for capacity — local 6 of 6"
              )
            ],
            pools: @pools,
            nodes: %{}
          }
        })

      assert %{
               "pick" => nil,
               "comparable" => false,
               "agrees" => false,
               "cause" => "capacity:node"
             } =
               AdmissionShadow.dispatch_record(board, :shadow, "bd-a")
    end

    test "a walk that places our card second blames today's hold on its first pick" do
      board =
        board(%{
          walk: %{
            promote: "bd-b",
            placements: [
              %{id: "bd-b", pool: @gpt, node: "local"},
              %{id: "bd-a", pool: @claude, node: "local"}
            ],
            entries: [
              walk_entry("bd-a", :starting, nil, pair: %{pool: @claude, node: "local"}),
              walk_entry("bd-b", :next, nil, pair: %{pool: @gpt, node: "local"})
            ],
            pools: @pools,
            nodes: %{}
          }
        })

      assert %{"agrees" => false, "cause" => "legacy_hold"} =
               AdmissionShadow.dispatch_record(board, :shadow, "bd-a")
    end

    test "nothing to record without a walk" do
      assert AdmissionShadow.dispatch_record(Map.delete(board(), :walk), :shadow, "bd-a") == nil
    end
  end

  describe "signature/1: what a hold change is" do
    test "the same decisions on both sides are the same signature, whatever the reasons say" do
      a = board()

      b =
        board(%{
          ready: [
            legacy_entry("bd-a", :next),
            legacy_entry("bd-b", :queued, reason: "different words")
          ]
        })

      assert AdmissionShadow.signature(a) == AdmissionShadow.signature(b)
    end

    test "either side's outcome changing is a change" do
      today_holds =
        board(%{
          promote: nil,
          ready: [
            legacy_entry("bd-a", :blocked,
              hold: :no_slot,
              reason: "blocked — no free worker slot"
            )
          ]
        })

      walk_moves =
        put_in(board().walk.placements, [%{id: "bd-b", pool: @claude, node: "local"}])

      sig = AdmissionShadow.signature(board())
      refute AdmissionShadow.signature(today_holds) == sig
      refute AdmissionShadow.signature(walk_moves) == sig
    end

    test "a pool's budget falling below today's cap is a change" do
      under =
        put_in(board().walk.pools[@gpt], %{budget: 1, seats: 0, cap: 2, label: "x", reason: "r"})

      refute AdmissionShadow.signature(under) == AdmissionShadow.signature(board())
    end
  end

  describe "event/3 and record_event/1: one row per hold change" do
    test "the row carries both decisions and every budget" do
      at = ~U[2026-10-10 12:00:00.000000Z]
      :ok = AdmissionShadow.record_event(AdmissionShadow.event(board(), :shadow, at))

      assert [row] = Ash.read!(AdmissionShadowEvent)

      assert %{
               at: ^at,
               policy: "shadow",
               legacy_pick: "bd-a",
               walk_pick: "bd-b",
               agrees: false,
               comparable: true,
               cause: "capacity:provider"
             } = row

      assert %{"pick" => "bd-a", "hold" => nil} = row.legacy
      assert %{"pick" => "bd-b", "node" => "local", "placements" => ["bd-b"]} = row.walk

      claude = Enum.find(row.budgets, &(&1["pool"] == "claude"))

      assert %{
               "account_id" => "acct-1",
               "label" => "claude:default",
               "budget" => 2,
               "seats" => 3,
               "free" => 0,
               "cap" => 3,
               "binding" => "window:5h",
               "reason" => "5h binds"
             } = claude
    end

    test "today holding names the head card and its hold" do
      board =
        board(%{
          promote: nil,
          ready: [
            legacy_entry("bd-a", :blocked,
              hold: {:quota, "5h ahead of pace"},
              reason: "blocked — 5h ahead of pace"
            ),
            legacy_entry("bd-b", :queued, reason: "1 ahead in queue")
          ]
        })

      event = AdmissionShadow.event(board, :shadow, DateTime.utc_now())

      assert %{legacy_pick: nil, walk_pick: "bd-b", comparable: false} = event

      assert %{"head" => "bd-a", "hold" => "quota", "reason" => "blocked — 5h ahead of pace"} =
               event.legacy
    end

    @tag capture_log: true
    test "a row that cannot be written is dropped, not raised" do
      assert :ok = AdmissionShadow.record_event(%{at: :not_a_time})
    end
  end
end
