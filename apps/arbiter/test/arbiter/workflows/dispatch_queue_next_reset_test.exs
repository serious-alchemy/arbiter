defmodule Arbiter.Workflows.DispatchQueueNextResetTest do
  @moduledoc """
  `DispatchQueue.next_reset_at/1` wake time for a long-only Claude (bd-5zwj09,
  5H C4): Anthropic retired the 5h window, so a held Claude snapshot may carry
  no primary `reset_at` at all — the long window's `secondary_reset_at` is then
  the only reset the queue can wake on.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Workflows.DispatchQueue
  alias Arbiter.Workflows.DispatchQueue.State

  defmodule Reader do
    @moduledoc false
    def latest_for_workspace(_ws, :claude), do: Process.get(:next_reset_snapshot)
  end

  defp state(snapshot) do
    Process.put(:next_reset_snapshot, snapshot)
    %State{workspace_id: "ws", quota_reader: Reader, items: [%{provider: :claude}]}
  end

  defp ahead(s), do: DateTime.utc_now() |> DateTime.add(s, :second) |> DateTime.truncate(:second)

  test "a long-only snapshot wakes the queue at its secondary_reset_at" do
    reset = ahead(3 * 3_600)
    snap = %Snapshot{provider: "claude", reset_at: nil, secondary_reset_at: reset}

    assert DispatchQueue.next_reset_at(state(snap)) == reset
  end

  test "the earlier of the primary and secondary resets wins" do
    primary = ahead(1_800)
    secondary = ahead(86_400)
    snap = %Snapshot{provider: "claude", reset_at: primary, secondary_reset_at: secondary}
    assert DispatchQueue.next_reset_at(state(snap)) == primary

    snap = %Snapshot{provider: "claude", reset_at: secondary, secondary_reset_at: primary}
    assert DispatchQueue.next_reset_at(state(snap)) == primary
  end

  test "a past secondary_reset_at is ignored" do
    snap = %Snapshot{provider: "claude", secondary_reset_at: ahead(-3_600)}
    assert DispatchQueue.next_reset_at(state(snap)) == nil
  end
end
