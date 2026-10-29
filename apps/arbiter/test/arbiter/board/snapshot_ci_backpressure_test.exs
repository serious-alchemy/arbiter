defmodule Arbiter.Board.SnapshotCiBackpressureTest do
  @moduledoc """
  #1126: a Ready card whose repo's forge CI queue is saturated
  (`worker.repos.<repo>.ci_backpressure`) is held on the board with
  `held — CI saturated (<n> pending, oldest <m>m)`. It is the card's own hold, so
  a card of another repo goes. Only fresh dispatches are ever held: follow-up
  work on a ticket that is already past Ready, and a P0 ticket, are not.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-10-29 12:00:00Z]

  defp workspace!(config) do
    n = System.unique_integer([:positive])

    Ash.create!(Workspace, %{
      name: "sci-#{n}",
      prefix: "sci#{n}",
      config: %{"worker" => %{"repos" => config}}
    })
  end

  defp issue(id, ws, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 1,
        issue_type: :feature,
        workspace_id: ws.id,
        repo: "vstim",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      extra
    )
  end

  # `n` pending MR pipelines on the stubbed forge, the oldest `age_min` old.
  defp forge(n, age_min) do
    fn _ws, _repo ->
      {:ok, %{pending: n, oldest_at: DateTime.add(@now, -age_min * 60, :second)}}
    end
  end

  defp load(ws, issues, poller, opts \\ []) do
    Snapshot.load(
      Keyword.merge(
        [
          workspace_id: ws.id,
          issues: issues,
          workers: [],
          slots_total: 3,
          quota: :ok,
          now: @now,
          ci_backpressure: [poller: poller, async: false, now: @now]
        ],
        opts
      )
    )
  end

  defp ready(board), do: Map.new(board.ready, &{&1.card.id, &1})

  @gated %{"vstim" => %{"ci_backpressure" => %{"max_pending" => 4}}}

  test "a Ready card of a saturated repo is held, naming the counts" do
    ws = workspace!(@gated)

    ready = ready(load(ws, [issue("t-1", ws)], forge(6, 42)))

    assert %{state: :blocked, reason: "held — CI saturated (6 pending, oldest 42m)"} =
             ready["t-1"]

    assert {:ci_saturated, "6 pending, oldest 42m"} = ready["t-1"].hold
  end

  test "the card of an ungated repo behind it goes" do
    ws = workspace!(@gated)
    issues = [issue("t-vstim", ws, %{priority: 1}), issue("t-other", ws, %{repo: "other"})]

    ready = ready(load(ws, issues, forge(6, 42)))

    assert %{state: :blocked} = ready["t-vstim"]
    assert %{state: :next} = ready["t-other"]
  end

  test "below the threshold, or with no config, dispatch is unchanged" do
    ws = workspace!(@gated)
    assert %{"t-1" => %{state: :next}} = ready(load(ws, [issue("t-1", ws)], forge(3, 42)))

    bare = workspace!(%{})
    assert %{"t-1" => %{state: :next}} = ready(load(bare, [issue("t-1", bare)], forge(30, 400)))
  end

  test "the oldest pending pipeline's age trips it on its own" do
    ws = workspace!(%{"vstim" => %{"ci_backpressure" => %{"max_oldest_pending_min" => 60}}})

    assert %{"t-1" => %{state: :blocked, reason: reason}} =
             ready(load(ws, [issue("t-1", ws)], forge(1, 130)))

    assert reason == "held — CI saturated (1 pending, oldest 130m)"
  end

  test "P0 is exempt" do
    ws = workspace!(@gated)
    ready = ready(load(ws, [issue("t-p0", ws, %{priority: 0})], forge(9, 200)))
    assert %{state: :next} = ready["t-p0"]
  end

  test "a ticket already In progress is not touched by the gate" do
    ws = workspace!(@gated)
    board = load(ws, [issue("t-run", ws, %{state: :active})], forge(9, 200))

    refute Enum.any?(board.ready, &(&1.card.id == "t-run"))
    assert Enum.any?(board.in_progress, &(&1.id == "t-run"))
  end

  test "a failed forge poll fails open: the card is dispatched" do
    ws = workspace!(@gated)
    poller = fn _ws, _repo -> {:error, :timeout} end

    ExUnit.CaptureLog.capture_log(fn ->
      assert %{"t-1" => %{state: :next}} = ready(load(ws, [issue("t-1", ws)], poller))
    end)
  end
end
