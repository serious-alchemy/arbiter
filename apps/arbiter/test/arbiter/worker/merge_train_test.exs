defmodule Arbiter.Worker.MergeTrainTest do
  @moduledoc """
  bd-1754qj — the per-target merge head on the auto-merge lane: one sync (and the
  CI after it) in flight per (workspace, repo, target), the rest wait. The
  election itself is `Arbiter.Workflows.MergeHead`, shared with the MergeQueue.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.MergeTrain
  alias Arbiter.Workflows.MergeHead

  @key {"ws-1", "repo", "main"}

  setup do
    {:ok, train: start_supervised!({MergeTrain, name: nil, settle_ms: 0})}
  end

  defp entry(task_id, attrs \\ []) do
    Map.merge(
      %{
        task_id: task_id,
        status: :behind_base,
        priority: 2,
        opened_at: ~U[2026-10-29 10:00:00Z],
        last_head_sha: "sha-#{task_id}"
      },
      Map.new(attrs)
    )
  end

  test "the only stale MR on a target is its head", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
  end

  test "a second stale MR waits for the head and the head is named", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)
    assert :head = MergeTrain.claim(@key, entry("a"), t)
  end

  test "targets, repos and workspaces have independent heads", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert :head = MergeTrain.claim({"ws-1", "repo", "release"}, entry("b"), t)
    assert :head = MergeTrain.claim({"ws-1", "other-repo", "main"}, entry("c"), t)
    assert :head = MergeTrain.claim({"ws-2", "repo", "main"}, entry("d"), t)
  end

  test "when the head leaves, order is priority then merge-ready time", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)

    low_early = entry("b", priority: 2, opened_at: ~U[2026-10-29 09:00:00Z])
    high_late = entry("c", priority: 1, opened_at: ~U[2026-10-29 11:00:00Z])
    same_late = entry("d", priority: 1, opened_at: ~U[2026-10-29 12:00:00Z])

    for e <- [low_early, high_late, same_late],
        do: assert({:wait, "a"} = MergeTrain.claim(@key, e, t))

    :ok = MergeTrain.release(@key, "a", t)

    # The lower-priority MR asks first and still does not get the place.
    assert {:wait, "c"} = MergeTrain.claim(@key, low_early, t)
    assert :head = MergeTrain.claim(@key, high_late, t)
    assert {:wait, "c"} = MergeTrain.claim(@key, same_late, t)

    :ok = MergeTrain.release(@key, "c", t)
    assert {:wait, "d"} = MergeTrain.claim(@key, low_early, t)
    assert :head = MergeTrain.claim(@key, same_late, t)
  end

  test "the head keeps its place when a better-ordered MR joins", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a", priority: 3), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b", priority: 0), t)
    assert :head = MergeTrain.tick(@key, entry("a", priority: 3, status: :ci_running), t)
  end

  test "a head whose CI stays failed hands its place on after the grace ticks", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    red = entry("a", status: :ci_running, last_block_reason: :ci_failed)

    for _ <- 1..MergeHead.head_stall_grace_ticks(),
        do: assert(:head = MergeTrain.tick(@key, red, t))

    assert {:wait, "b"} = MergeTrain.tick(@key, red, t)
    assert :head = MergeTrain.claim(@key, entry("b"), t)
    # The red MR, still asking, does not take the place back.
    assert {:wait, "b"} =
             MergeTrain.claim(
               @key,
               entry("a", status: :ci_running, last_block_reason: :ci_failed),
               t
             )
  end

  test "a head stuck in CI on one SHA past the bound hands its place on", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    running = entry("a", status: :ci_running)

    for _ <- 1..MergeHead.head_ci_wait_ticks(),
        do: assert(:head = MergeTrain.tick(@key, running, t))

    assert {:wait, "b"} = MergeTrain.tick(@key, running, t)
  end

  test "a head whose sync is never applied hands its place on", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    :ok = MergeTrain.note_synced(@key, "a", "sha-a", t)
    unchanged = entry("a", status: :behind_base, last_head_sha: "sha-a")

    for _ <- 1..MergeHead.head_stall_grace_ticks(),
        do: assert(:head = MergeTrain.tick(@key, unchanged, t))

    assert {:wait, "b"} = MergeTrain.tick(@key, unchanged, t)
  end

  test "a head that polls fine and keeps progressing is never handed on", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    for n <- 1..(MergeHead.head_stall_grace_ticks() * 3) do
      running = entry("a", status: :ci_running, last_head_sha: "sha-#{n}")
      assert :head = MergeTrain.tick(@key, running, t)
    end
  end

  test "releasing the head (parked, closed) hands its place on at once", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    :ok = MergeTrain.release(@key, "a", t)

    assert :head = MergeTrain.claim(@key, entry("b"), t)
  end

  test "a head whose process dies hands its place on", %{train: t} do
    {:ok, agent} = Agent.start(fn -> :ok end)
    ref = Process.monitor(agent)

    assert :head = Agent.get(agent, fn _ -> MergeTrain.claim(@key, entry("a"), t) end)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    Agent.stop(agent)
    assert_receive {:DOWN, ^ref, :process, ^agent, _}
    _ = :sys.get_state(t)

    assert :head = MergeTrain.claim(@key, entry("b"), t)
  end

  test "no head is chosen while a restarted train is still forming" do
    t = start_supervised!({MergeTrain, name: nil, settle_ms: :infinity}, id: :forming)

    assert {:wait, :forming} = MergeTrain.claim(@key, entry("low", priority: 3), t)
    assert {:wait, :forming} = MergeTrain.claim(@key, entry("high", priority: 0), t)

    :ok = MergeTrain.settle_now(t)

    # Everyone has re-registered by now: the best-ordered one leads, whoever asks first.
    assert {:wait, "high"} = MergeTrain.claim(@key, entry("low", priority: 3), t)
    assert :head = MergeTrain.claim(@key, entry("high", priority: 0), t)
  end

  test "an MR that stopped asking drops out of the order", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("gone", priority: 0, ttl_ms: 0), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    :ok = MergeTrain.release(@key, "a", t)

    assert :head = MergeTrain.claim(@key, entry("b"), t)
  end

  describe "merge lock" do
    test "one merge at a time per target", %{train: t} do
      assert :ok = MergeTrain.acquire_merge(@key, "a", t)
      assert :ok = MergeTrain.acquire_merge(@key, "a", t)
      assert {:busy, "a"} = MergeTrain.acquire_merge(@key, "b", t)
      assert :ok = MergeTrain.acquire_merge({"ws-1", "repo", "other"}, "b", t)

      :ok = MergeTrain.release_merge(@key, "a", t)
      assert :ok = MergeTrain.acquire_merge(@key, "b", t)
    end

    test "a holder that dies releases it", %{train: t} do
      {:ok, agent} = Agent.start(fn -> :ok end)
      ref = Process.monitor(agent)
      assert :ok = Agent.get(agent, fn _ -> MergeTrain.acquire_merge(@key, "a", t) end)
      assert {:busy, "a"} = MergeTrain.acquire_merge(@key, "b", t)

      Agent.stop(agent)
      assert_receive {:DOWN, ^ref, :process, ^agent, _}
      _ = :sys.get_state(t)

      assert :ok = MergeTrain.acquire_merge(@key, "b", t)
    end
  end

  test "view/2 names the head and the waiting MRs", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    assert %{head: "a", waiting: ["b"]} = MergeTrain.view(@key, t)
    assert %{head: nil, waiting: []} = MergeTrain.view({"x", "y", "z"}, t)
  end
end
