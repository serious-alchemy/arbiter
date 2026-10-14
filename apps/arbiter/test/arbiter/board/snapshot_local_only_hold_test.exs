defmodule Arbiter.Board.SnapshotLocalOnlyHoldTest do
  @moduledoc """
  bd-akp9ae: a Ready card that can only run on the primary — its workspace places
  runs on nodes, but this run is local-only (its repo is not sandboxed in podman, it
  has no checkout to hand a node, …) — while the primary's own cap is full is held
  on the board with the primary's own hold, `held — local capacity full (cap 2, 2
  running) (run is local-only: …)`: the phrase the dispatch-time gate
  (`Arbiter.Nodes.LocalCapacity`) refuses it with, and not a board-wide slot note
  that names an account budget. It is the card's own hold, so the card behind it,
  which a node can take, goes.

  A `local_only` workspace is unchanged: its board-wide slot count is the
  primary's, and its note already names the machine.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Nodes
  alias Arbiter.Nodes.Placement
  alias Arbiter.Tasks.{Issue, ReadyHolds, Workspace}

  @holders ["bd-holder-a", "bd-holder-b"]

  setup do
    {:ok, 2} = Nodes.set_local_max_workers(2, nil)
    on_exit(fn -> Nodes.set_local_max_workers(nil, nil) end)
    on_exit(fn -> Enum.each(@holders, &Placement.release/1) end)
    :ok
  end

  # The primary's two slots held by other tickets' runs.
  defp fill_primary!, do: Enum.each(@holders, &Placement.reserve(&1, "local"))

  defp workspace!(placement) do
    n = System.unique_integer([:positive])

    Ash.create!(Workspace, %{
      name: "slo-#{n}",
      prefix: "slo#{n}",
      config: %{
        "worker" => %{"placement" => placement},
        "agent" => %{
          "security" => %{
            "repos" => %{"pod-repo" => %{"sandbox" => %{"backend" => "podman"}}}
          }
        }
      }
    })
  end

  defp issue(id, ws, extra) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 1,
        issue_type: :feature,
        workspace_id: ws.id,
        repo: "bwrap-repo",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: now,
        updated_at: now,
        closed_at: nil
      },
      extra
    )
  end

  defp load_ready(ws, issues, opts \\ []) do
    board =
      Snapshot.load(
        Keyword.merge(
          [workspace_id: ws.id, issues: issues, workers: [], slots_total: 3, quota: :ok],
          opts
        )
      )

    Map.new(board.ready, &{&1.card.id, &1})
  end

  test "a local-only card waits on the primary's hold, and the card a node can take goes" do
    fill_primary!()
    ws = workspace!("prefer_remote")
    local = issue("t-local", ws, %{priority: 1})
    remote = issue("t-pod", ws, %{repo: "pod-repo", priority: 2})

    ready = load_ready(ws, [local, remote])

    assert %{state: :blocked, reason: reason, hold: {:local_capacity, _}} = ready["t-local"]
    assert reason =~ "held — local capacity full (cap 2, 2 running)"
    assert reason =~ "(run is local-only: sandbox is not podman"
    assert %{state: :next} = ready["t-pod"]
  end

  test "with no free worker slot either, the card names the primary, not the account" do
    fill_primary!()
    ws = workspace!("prefer_remote")
    note = "account claude:default at 2/4 live (bd-x implement, bd-y review)"

    ready = load_ready(ws, [issue("t-local", ws, %{})], slots_total: 0, slot_note: note)

    assert %{state: :blocked, reason: reason} = ready["t-local"]
    assert reason =~ "held — local capacity full (cap 2, 2 running) (run is local-only:"
    refute reason =~ "account"
    refute reason =~ "no free worker slot"
  end

  test "the primary with room holds nothing" do
    ws = workspace!("prefer_remote")
    assert %{"t-local" => %{state: :next}} = load_ready(ws, [issue("t-local", ws, %{})])
  end

  test "a card a node may take is not held by the primary's cap" do
    fill_primary!()
    ws = workspace!("prefer_remote")

    assert %{"t-pod" => %{state: :next}} =
             load_ready(ws, [issue("t-pod", ws, %{repo: "pod-repo"})])
  end

  test "a local_only workspace keeps its board-wide hold and queue positions" do
    fill_primary!()
    ws = workspace!("local_only")
    note = "held — no free slot on this machine or any node (worker.placement is local_only)"

    ready =
      load_ready(ws, [issue("t-1", ws, %{priority: 1}), issue("t-2", ws, %{})],
        slots_total: 0,
        slot_note: note
      )

    assert %{state: :blocked, hold: :no_slot, reason: reason} = ready["t-1"]
    assert reason =~ note
    assert %{state: :queued, reason: "1 ahead in queue"} = ready["t-2"]
  end

  # The Ready-card `hold_reason` (`arb prime`, `GET /api/issues/ready`, MCP
  # `ticket_ready`) reads the board's own plan, over the tickets the board reads
  # itself: the card's repo decides its sandbox, so the board must read it.
  test "the Ready card's hold_reason names the primary's cap and the local-only reason" do
    fill_primary!()
    ws = workspace!("prefer_remote")
    card = ready!(ws, "bwrap-repo", "local-only card")
    podman_card = ready!(ws, "pod-repo", "a card a node may take")

    holds = ReadyHolds.for_workspace(ws.id)

    reason = Map.get(holds, card.id)
    assert is_binary(reason)
    assert reason =~ "held — local capacity full (cap 2, 2 running)"
    assert reason =~ "run is local-only: sandbox is not podman"
    refute reason =~ "account"

    refute (Map.get(holds, podman_card.id) || "") =~ "local capacity"
  end

  defp ready!(ws, repo, title) do
    {:ok, created} =
      Ash.create(Issue, %{
        title: title,
        workspace_id: ws.id,
        repo: repo,
        acceptance: "- placement fixture"
      })

    {:ok, card} = Ash.update(created, %{}, action: :promote_to_ready)
    card
  end
end
