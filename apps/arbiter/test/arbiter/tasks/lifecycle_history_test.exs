defmodule Arbiter.Tasks.Lifecycle.HistoryTest do
  @moduledoc """
  bd-d8fi92 (reports design v2 §3.2): the pure replay of a ticket's paper
  trail into lifecycle transitions, across the three eras — A (legacy
  `status` only), B (`status` and `state`), C (`state` only) — and the
  per-install `refined` cutover seed.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Lifecycle.History

  # The live install's cutovers (design §3.1–3.2); fixtures straddle them.
  @refined_cutover ~U[2026-08-24 17:16:09.000000Z]
  @state_cutover ~U[2026-09-27 19:41:30.000000Z]
  @opts [refined_cutover: @refined_cutover, state_cutover: @state_cutover]

  @pre_cutover ~U[2026-07-01 10:00:00.000000Z]
  @post_cutover ~U[2026-09-01 10:00:00.000000Z]

  defp v(action, at, changes), do: %{action: action, at: at, changes: changes}

  defp later(at, seconds), do: DateTime.add(at, seconds, :second)

  # A legacy ticket: a create version carrying `status: open` (and whatever
  # else), created at `at`, then the given versions.
  defp legacy(at, create_extra \\ %{}, versions \\ []) do
    [v("create", at, Map.merge(%{"status" => "open", "title" => "t"}, create_extra)) | versions]
  end

  defp replay(versions, created_at, opts \\ @opts),
    do: History.replay(versions, Keyword.put(opts, :created_at, created_at))

  defp pairs(%{transitions: ts}), do: Enum.map(ts, &{&1.from_state, &1.to_state})

  describe "era A — the derivation (legacy status × refined seed × pr_ref / pending_merge)" do
    test "open before the refined cutover is queued: the seed says created was ready" do
      result = replay(legacy(@pre_cutover), @pre_cutover)

      assert pairs(result) == [{nil, :queued}]
      assert result.state == :queued
      assert [%{transition: "create", at: @pre_cutover, close_reason: nil}] = result.transitions
    end

    test "open after the cutover with refined absent is backlog" do
      assert pairs(replay(legacy(@post_cutover), @post_cutover)) == [{nil, :backlog}]
    end

    test "open after the cutover with refined true or false follows refined" do
      assert pairs(replay(legacy(@post_cutover, %{"refined" => true}), @post_cutover)) ==
               [{nil, :queued}]

      assert pairs(replay(legacy(@post_cutover, %{"refined" => false}), @post_cutover)) ==
               [{nil, :backlog}]
    end

    test "an install with no cutover (nil) never seeds" do
      assert pairs(replay(legacy(@pre_cutover), @pre_cutover, refined_cutover: nil)) ==
               [{nil, :backlog}]
    end

    test "promote_to_ready (refined → true) moves backlog to queued" do
      versions =
        legacy(@post_cutover, %{}, [
          v("promote_to_ready", later(@post_cutover, 60), %{"refined" => true})
        ])

      result = replay(versions, @post_cutover)
      assert pairs(result) == [{nil, :backlog}, {:backlog, :queued}]
      assert List.last(result.transitions).transition == "legacy:promote_to_ready"
    end

    for {label, extra, expected} <- [
          {"no pr_ref or pending_merge", %{}, :active},
          {"a blank pr_ref", %{"pr_ref" => ""}, :active},
          {"a nil pr_ref", %{"pr_ref" => nil}, :active},
          {"a pr_ref", %{"pr_ref" => "#12"}, :merging},
          {"a nil pending_merge", %{"pending_merge" => nil}, :active},
          {"an empty pending_merge", %{"pending_merge" => %{}}, :active},
          {"a pending_merge", %{"pending_merge" => %{"detail" => "running"}}, :merging}
        ] do
      test "in_progress with #{label} is #{expected}" do
        versions =
          legacy(@pre_cutover, %{}, [
            v(
              "update",
              later(@pre_cutover, 60),
              Map.put(unquote(Macro.escape(extra)), "status", "in_progress")
            )
          ])

        assert pairs(replay(versions, @pre_cutover)) == [
                 {nil, :queued},
                 {:queued, unquote(expected)}
               ]
      end
    end

    test "a pr_ref landing on an in_progress ticket moves active to merging; clearing it moves back" do
      t = @pre_cutover

      versions =
        legacy(t, %{}, [
          v("update", later(t, 60), %{"status" => "in_progress"}),
          v("record_pr", later(t, 120), %{"pr_ref" => "#7"}),
          v("update", later(t, 180), %{"pr_ref" => nil})
        ])

      result = replay(versions, t)

      assert pairs(result) == [
               {nil, :queued},
               {:queued, :active},
               {:active, :merging},
               {:merging, :active}
             ]

      assert Enum.map(result.transitions, & &1.at) == [
               t,
               later(t, 60),
               later(t, 120),
               later(t, 180)
             ]
    end

    test "awaiting_verification is verifying; closed is closed with close_reason completed" do
      t = @pre_cutover

      versions =
        legacy(t, %{}, [
          v("update", later(t, 60), %{"status" => "in_progress", "pr_ref" => "#1"}),
          v("await_verification", later(t, 120), %{"status" => "awaiting_verification"}),
          v("close", later(t, 180), %{"status" => "closed"})
        ])

      result = replay(versions, t)

      assert pairs(result) == [
               {nil, :queued},
               {:queued, :merging},
               {:merging, :verifying},
               {:verifying, :closed}
             ]

      assert %{transition: "legacy:close", close_reason: :completed} =
               List.last(result.transitions)

      assert result.state == :closed
    end

    test "a version that changes nothing state-bearing emits nothing" do
      versions =
        legacy(@pre_cutover, %{}, [v("update", later(@pre_cutover, 5), %{"notes" => "x"})])

      assert pairs(replay(versions, @pre_cutover)) == [{nil, :queued}]
    end

    test "a status already in force emits nothing (no self-transition)" do
      versions =
        legacy(@pre_cutover, %{}, [v("update", later(@pre_cutover, 5), %{"status" => "open"})])

      assert pairs(replay(versions, @pre_cutover)) == [{nil, :queued}]
    end
  end

  describe "era A — reopens" do
    test "a legacy reopen keeps refined: closed → queued" do
      t = @post_cutover

      versions =
        legacy(t, %{"refined" => true}, [
          v("close", later(t, 60), %{"status" => "closed"}),
          v("reopen", later(t, 120), %{"status" => "open"})
        ])

      assert pairs(replay(versions, t)) == [
               {nil, :queued},
               {:queued, :closed},
               {:closed, :queued}
             ]
    end

    test "a legacy reopen of a ticket whose refined was still false lands in backlog" do
      t = @post_cutover

      versions =
        legacy(t, %{}, [
          v("close", later(t, 60), %{"status" => "closed"}),
          v("reopen", later(t, 120), %{"status" => "open"})
        ])

      assert pairs(replay(versions, t)) == [
               {nil, :backlog},
               {:backlog, :closed},
               {:closed, :backlog}
             ]
    end

    test "a reopen from verifying lands in queued" do
      t = @pre_cutover

      versions =
        legacy(t, %{}, [
          v("update", later(t, 60), %{"status" => "awaiting_verification"}),
          v("reopen", later(t, 120), %{"status" => "open"})
        ])

      assert pairs(replay(versions, t)) == [
               {nil, :queued},
               {:queued, :verifying},
               {:verifying, :queued}
             ]
    end

    test "a reopen clears the close_reason the next close would otherwise inherit" do
      t = @post_cutover

      versions =
        legacy(t, %{"refined" => true}, [
          v("close", later(t, 60), %{"state" => "closed", "close_reason" => "wont_do"}),
          v("reopen", later(t, 120), %{"state" => "queued", "close_reason" => nil}),
          v("close", later(t, 180), %{"state" => "closed"})
        ])

      assert [_, %{close_reason: :wont_do}, %{close_reason: nil}, %{close_reason: :completed}] =
               replay(versions, t).transitions
    end
  end

  describe "eras B and C — state is authoritative" do
    test "a dual-write version (status and state) takes state, not the derivation" do
      t = @pre_cutover

      versions =
        legacy(t, %{}, [
          v("start", later(t, 60), %{
            "status" => "in_progress",
            "pr_ref" => "#3",
            "state" => "active"
          })
        ])

      result = replay(versions, t)
      assert pairs(result) == [{nil, :queued}, {:queued, :active}]
      assert List.last(result.transitions).transition == "start"
    end

    test "transitions carrying state are named by their (from, to) pair, like the live trigger" do
      t = @post_cutover

      versions = [
        v("create", t, %{"state" => "backlog"}),
        v("promote_to_ready", later(t, 10), %{"state" => "queued", "refined" => true}),
        v("start", later(t, 20), %{"state" => "active"}),
        v("open_pr", later(t, 30), %{"state" => "merging", "pr_ref" => "#1"}),
        v("pr_closed", later(t, 40), %{"state" => "active"}),
        v("close", later(t, 50), %{"state" => "closed", "close_reason" => "duplicate"})
      ]

      result = replay(versions, t)

      assert Enum.map(result.transitions, & &1.transition) ==
               ~w(create promote start open_pr return_to_work close)

      assert List.last(result.transitions).close_reason == :duplicate
      assert result.illegal == []
    end

    test "once a ticket has shown state, a legacy-only version does not move it" do
      t = @post_cutover

      versions = [
        v("create", t, %{"state" => "backlog", "status" => "open"}),
        v("start", later(t, 10), %{"state" => "active", "status" => "in_progress"}),
        v("record_pr", later(t, 20), %{"pr_ref" => "#9"})
      ]

      assert pairs(replay(versions, t)) == [{nil, :backlog}, {:backlog, :active}]
    end

    test "after the state cutover a version without state never derives one" do
      t = @pre_cutover

      versions =
        legacy(t, %{}, [
          v("update", later(t, 60), %{"status" => "in_progress"}),
          # Era B: the state column is the truth, and record_pr did not touch it.
          v("record_pr", later(@state_cutover, 60), %{"pr_ref" => "#4"}),
          v("open_pr", later(@state_cutover, 120), %{"state" => "merging"})
        ])

      result = replay(versions, t)
      assert pairs(result) == [{nil, :queued}, {:queued, :active}, {:active, :merging}]
      assert List.last(result.transitions).transition == "open_pr"
    end

    test "a ticket whose first state-bearing version is a close" do
      t = @pre_cutover

      versions =
        legacy(t, %{}, [
          v("update", later(t, 60), %{"status" => "in_progress", "pr_ref" => "#2"}),
          v("close", later(@state_cutover, 3600), %{
            "state" => "closed",
            "close_reason" => "completed"
          })
        ])

      result = replay(versions, t)
      assert pairs(result) == [{nil, :queued}, {:queued, :merging}, {:merging, :closed}]
      assert %{transition: "close", close_reason: :completed} = List.last(result.transitions)
      assert result.illegal == []
    end

    test "a version re-writing the state already in force emits nothing" do
      t = @post_cutover

      versions = [
        v("create", t, %{"state" => "backlog"}),
        v("promote_to_ready", later(t, 10), %{"state" => "queued"}),
        v("promote_to_ready", later(t, 20), %{"state" => "queued"})
      ]

      assert pairs(replay(versions, t)) == [{nil, :backlog}, {:backlog, :queued}]
    end

    test "a state-carrying pair outside the lifecycle table is reported illegal (and still replayed)" do
      t = @post_cutover

      versions = [
        v("create", t, %{"state" => "backlog"}),
        v("update", later(t, 10), %{"state" => "merging"})
      ]

      result = replay(versions, t)
      assert pairs(result) == [{nil, :backlog}, {:backlog, :merging}]
      assert [%{from_state: :backlog, to_state: :merging, transition: "unnamed"}] = result.illegal
    end

    test "era-A derived pairs are never reported illegal: the legacy model had no table" do
      t = @post_cutover

      versions =
        legacy(t, %{"refined" => true}, [
          v("update", later(t, 10), %{"status" => "in_progress", "pr_ref" => "#1"})
        ])

      result = replay(versions, t)
      assert pairs(result) == [{nil, :queued}, {:queued, :merging}]
      assert result.illegal == []
    end
  end

  describe "unmapped values" do
    test "an unknown legacy status is reported and moves nothing" do
      t = @pre_cutover

      versions = legacy(t, %{}, [v("update", later(t, 10), %{"status" => "blocked"})])
      result = replay(versions, t)

      assert pairs(result) == [{nil, :queued}]
      assert result.unmapped == [%{at: later(t, 10), key: "status", value: "blocked"}]
    end

    test "an unknown state is reported and moves nothing" do
      t = @post_cutover

      versions = [
        v("create", t, %{"state" => "backlog"}),
        v("x", later(t, 10), %{"state" => "limbo"})
      ]

      result = replay(versions, t)

      assert pairs(result) == [{nil, :backlog}]
      assert result.unmapped == [%{at: later(t, 10), key: "state", value: "limbo"}]
    end
  end

  describe "ordering and the creation row" do
    test "versions are replayed in time order whatever order they arrive in" do
      t = @pre_cutover
      [create, start] = legacy(t, %{}, [v("update", later(t, 60), %{"status" => "in_progress"})])

      assert pairs(replay([start, create], t)) == [{nil, :queued}, {:queued, :active}]
    end

    test "the first row is stamped no later than the ticket's created_at" do
      created_at = @pre_cutover
      versions = legacy(later(created_at, 1))

      assert [%{at: ^created_at}] = replay(versions, created_at).transitions
    end

    test "no versions: no transitions, no state" do
      assert %{transitions: [], state: nil, unmapped: [], illegal: []} = replay([], @pre_cutover)
    end
  end

  describe "seed_refined?/2" do
    test "true only for a ticket created before the install's cutover" do
      assert History.seed_refined?(@pre_cutover, @refined_cutover)
      refute History.seed_refined?(@post_cutover, @refined_cutover)
      refute History.seed_refined?(@pre_cutover, nil)
      refute History.seed_refined?(nil, @refined_cutover)
    end
  end

  describe "name/2" do
    test "names a pair the way the ticket_transitions trigger does" do
      assert History.name(nil, :backlog) == "create"
      assert History.name(:backlog, :queued) == "promote"
      assert History.name(:active, :queued) == "requeue"
      assert History.name(:verifying, :queued) == "reopen"
      assert History.name(:merging, :backlog) == "demote"
      assert History.name(:queued, :active) == "start"
      assert History.name(:merging, :active) == "return_to_work"
      assert History.name(:active, :merging) == "open_pr"
      assert History.name(:merging, :verifying) == "await_verification"
      assert History.name(:verifying, :closed) == "close"
      assert History.name(:backlog, :merging) == "unnamed"
    end
  end
end
