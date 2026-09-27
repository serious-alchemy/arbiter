defmodule Arbiter.Tasks.LifecycleTest do
  @moduledoc """
  bd-842qio: the stored-state table itself — states, transitions, the legacy
  dual-write mapping and the backfill rule — as pure functions. The resource
  tests (`Arbiter.Tasks.IssueLifecycleTest`) prove the actions obey it.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Lifecycle

  test "the six stored states, in lifecycle order" do
    assert Lifecycle.states() == [:backlog, :queued, :active, :merging, :verifying, :closed]
  end

  test "the three close reasons" do
    assert Lifecycle.close_reasons() == [:completed, :wont_do, :duplicate]
  end

  describe "the transition table" do
    test "names exactly the eight transitions" do
      assert Enum.sort(Lifecycle.transitions()) ==
               Enum.sort([
                 :promote,
                 :demote,
                 :start,
                 :open_pr,
                 :return_to_work,
                 :await_verification,
                 :close,
                 :reopen
               ])
    end

    test "each transition's sources and target" do
      assert Lifecycle.rule(:promote) == {[:backlog], :queued}
      assert Lifecycle.rule(:demote) == {[:queued], :backlog}
      assert Lifecycle.rule(:start) == {[:queued], :active}
      assert Lifecycle.rule(:open_pr) == {[:active], :merging}
      assert Lifecycle.rule(:return_to_work) == {[:merging], :active}
      assert Lifecycle.rule(:await_verification) == {[:active, :merging], :verifying}

      assert Lifecycle.rule(:close) ==
               {[:backlog, :queued, :active, :merging, :verifying], :closed}

      assert Lifecycle.rule(:reopen) == {[:closed, :verifying], :queued}
    end

    test "allowed?/2 answers from the table" do
      assert Lifecycle.allowed?(:start, :queued)
      refute Lifecycle.allowed?(:start, :backlog)
      refute Lifecycle.allowed?(:close, :closed)
      assert Lifecycle.allowed?(:reopen, :verifying)
      refute Lifecycle.allowed?(:no_such_transition, :queued)
    end
  end

  describe "legacy_fields/1 — the dual-write mapping" do
    test "maps every state onto status + refined" do
      assert Lifecycle.legacy_fields(:backlog) == %{status: :open, refined: false}
      assert Lifecycle.legacy_fields(:queued) == %{status: :open, refined: true}
      assert Lifecycle.legacy_fields(:active) == %{status: :in_progress, refined: true}
      assert Lifecycle.legacy_fields(:merging) == %{status: :in_progress, refined: true}

      assert Lifecycle.legacy_fields(:verifying) ==
               %{status: :awaiting_verification, refined: true}

      # `refined` is left alone on close.
      assert Lifecycle.legacy_fields(:closed) == %{status: :closed}
    end
  end

  describe "legacy_state/1 — the backfill rule" do
    test "open rows split on refined" do
      assert Lifecycle.legacy_state(%{status: :open, refined: false}) == :backlog
      assert Lifecycle.legacy_state(%{status: :open, refined: true}) == :queued
      # Absent reads as unrefined, the same safe direction Board.Snapshot takes.
      assert Lifecycle.legacy_state(%{status: :open}) == :backlog
    end

    test "in_progress rows split on whether a PR or a pending merge is on record" do
      assert Lifecycle.legacy_state(%{status: :in_progress, pr_ref: "#12"}) == :merging

      assert Lifecycle.legacy_state(%{status: :in_progress, pending_merge: %{"pr_ref" => "#1"}}) ==
               :merging

      assert Lifecycle.legacy_state(%{status: :in_progress, pr_ref: nil, pending_merge: nil}) ==
               :active

      # An empty ref or an empty stamp is no PR at all.
      assert Lifecycle.legacy_state(%{status: :in_progress, pr_ref: "", pending_merge: %{}}) ==
               :active
    end

    test "awaiting_verification and closed map one-to-one" do
      assert Lifecycle.legacy_state(%{status: :awaiting_verification}) == :verifying
      assert Lifecycle.legacy_state(%{status: :closed, refined: true}) == :closed
    end
  end
end
