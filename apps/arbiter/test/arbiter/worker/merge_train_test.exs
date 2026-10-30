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

  describe "a head that is green but not merging" do
    test "hands its place on after N ticks of :ready_to_merge with no merge", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

      ready = entry("a", status: :ready_to_merge, ready_ticks: 3)

      for _ <- 1..3, do: assert(:head = MergeTrain.tick(@key, ready, t))

      assert {:wait, "b"} = MergeTrain.tick(@key, ready, t)
      assert :head = MergeTrain.claim(@key, entry("b"), t)
    end

    test "the default bound applies when the entry names none", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

      ready = entry("a", status: :ready_to_merge)

      for _ <- 1..MergeHead.head_ready_ticks(),
          do: assert(:head = MergeTrain.tick(@key, ready, t))

      assert {:wait, "b"} = MergeTrain.tick(@key, ready, t)
    end

    test "a tick in CI in between resets the count", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

      ready = entry("a", status: :ready_to_merge, ready_ticks: 2)
      for _ <- 1..2, do: assert(:head = MergeTrain.tick(@key, ready, t))
      assert :head = MergeTrain.tick(@key, entry("a", status: :ci_running), t)
      for _ <- 1..2, do: assert(:head = MergeTrain.tick(@key, ready, t))
    end
  end

  describe "the CI-wait bound" do
    test "is configurable per entry and hands the place on past it", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

      running = entry("a", status: :ci_running, ci_phase: :running, ci_wait_ticks: 4)

      for _ <- 1..4, do: assert(:head = MergeTrain.tick(@key, running, t))
      assert {:wait, "b"} = MergeTrain.tick(@key, running, t)
    end

    test "counts only running ticks, not pending ones", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

      pending = entry("a", status: :ci_running, ci_phase: :pending, ci_wait_ticks: 2)
      running = %{pending | ci_phase: :running}

      # A long queue wait neither hands the place on nor resets the running count.
      for _ <- 1..20, do: assert(:head = MergeTrain.tick(@key, pending, t))
      for _ <- 1..2, do: assert(:head = MergeTrain.tick(@key, running, t))
      for _ <- 1..20, do: assert(:head = MergeTrain.tick(@key, pending, t))
      assert {:wait, "b"} = MergeTrain.tick(@key, running, t)
    end
  end

  describe "election order" do
    test "a green stale MR is elected ahead of a red one at equal priority", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)

      red = entry("red", opened_at: ~U[2026-10-29 08:00:00Z], red?: true)
      green = entry("green", opened_at: ~U[2026-10-29 09:00:00Z])
      assert {:wait, "a"} = MergeTrain.claim(@key, red, t)
      assert {:wait, "a"} = MergeTrain.claim(@key, green, t)

      :ok = MergeTrain.release(@key, "a", t)

      assert {:wait, "green"} = MergeTrain.claim(@key, red, t)
      assert :head = MergeTrain.claim(@key, green, t)
    end

    test "priority still beats the red flag", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("red", priority: 0, red?: true), t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("green", priority: 2), t)

      :ok = MergeTrain.release(@key, "a", t)

      assert :head = MergeTrain.claim(@key, entry("red", priority: 0, red?: true), t)
    end
  end

  describe "a head whose Watchdog crashed while its synced pipeline runs" do
    defp crash(agent) do
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, _}
    end

    test "keeps its place for the restarted Watchdog; nobody else becomes head", %{train: t} do
      {:ok, agent} = Agent.start(fn -> :ok end)
      running = entry("a", status: :ci_running, ci_phase: :running)

      assert :head = Agent.get(agent, fn _ -> MergeTrain.claim(@key, entry("a"), t) end)
      assert :head = Agent.get(agent, fn _ -> MergeTrain.tick(@key, running, t) end)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

      crash(agent)
      _ = :sys.get_state(t)

      # The pipeline is still running: b does not get to sync a second pipeline.
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

      # The restarted Watchdog takes its place back.
      assert :head = MergeTrain.resume(@key, running, t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)
    end

    test "the place lapses once the CI-wait bound has passed", %{train: t} do
      {:ok, agent} = Agent.start(fn -> :ok end)
      running = entry("a", status: :ci_running, ci_phase: :running, orphan_ms: 0)

      assert :head = Agent.get(agent, fn _ -> MergeTrain.claim(@key, running, t) end)
      assert :head = Agent.get(agent, fn _ -> MergeTrain.tick(@key, running, t) end)

      crash(agent)
      _ = :sys.get_state(t)

      assert :head = MergeTrain.claim(@key, entry("b"), t)
    end

    test "a deliberate stop (shutdown) still hands the place on", %{train: t} do
      {:ok, agent} = Agent.start(fn -> :ok end)
      running = entry("a", status: :ci_running, ci_phase: :running)

      assert :head = Agent.get(agent, fn _ -> MergeTrain.claim(@key, entry("a"), t) end)
      assert :head = Agent.get(agent, fn _ -> MergeTrain.tick(@key, running, t) end)

      ref = Process.monitor(agent)
      Process.exit(agent, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^agent, _}
      _ = :sys.get_state(t)

      assert :head = MergeTrain.claim(@key, entry("b"), t)
    end

    test "a head that was not under way (behind, nothing synced) is not held", %{train: t} do
      {:ok, agent} = Agent.start(fn -> :ok end)
      assert :head = Agent.get(agent, fn _ -> MergeTrain.claim(@key, entry("a"), t) end)

      crash(agent)
      _ = :sys.get_state(t)

      assert :head = MergeTrain.claim(@key, entry("b"), t)
    end

    test "a restarted train seats a resuming head even while forming" do
      t = start_supervised!({MergeTrain, name: nil, settle_ms: :infinity}, id: :resume)
      running = entry("a", status: :ci_running)

      assert :head = MergeTrain.resume(@key, running, t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b", priority: 0), t)
      :ok = MergeTrain.settle_now(t)
      assert {:wait, "a"} = MergeTrain.claim(@key, entry("b", priority: 0), t)
    end

    test "resume does not displace another head", %{train: t} do
      assert :head = MergeTrain.claim(@key, entry("a"), t)
      assert {:wait, "a"} = MergeTrain.resume(@key, entry("b", status: :ci_running), t)
    end
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

    test "the monitor follows the current holder pid", %{train: t} do
      {:ok, old} = Agent.start(fn -> :ok end)
      {:ok, current} = Agent.start(fn -> :ok end)

      assert :ok = Agent.get(old, fn _ -> MergeTrain.acquire_merge(@key, "a", t) end)
      # A replaced Watchdog re-enters under the same task id from a new pid.
      assert :ok = Agent.get(current, fn _ -> MergeTrain.acquire_merge(@key, "a", t) end)

      ref = Process.monitor(old)
      Agent.stop(old)
      assert_receive {:DOWN, ^ref, :process, ^old, _}
      _ = :sys.get_state(t)

      # The old pid dying must not free the slot the current pid holds.
      assert {:busy, "a"} = MergeTrain.acquire_merge(@key, "b", t)

      ref = Process.monitor(current)
      Agent.stop(current)
      assert_receive {:DOWN, ^ref, :process, ^current, _}
      _ = :sys.get_state(t)

      assert :ok = MergeTrain.acquire_merge(@key, "b", t)
    end

    test "a slot not renewed or released within the lease is freed for the next asker" do
      # A zero lease: any other asker finds the holder already silent past it.
      t = start_supervised!({MergeTrain, name: nil, settle_ms: 0, merge_lease_ms: 0}, id: :leased)

      assert :ok = MergeTrain.acquire_merge(@key, "a", t)
      # The holder itself renews by asking again.
      assert :ok = MergeTrain.acquire_merge(@key, "a", t)
      assert :ok = MergeTrain.acquire_merge(@key, "b", t)

      # "a" was evicted, so its late release must not free "b"'s slot.
      :ok = MergeTrain.release_merge(@key, "a", t)
      assert :ok = MergeTrain.acquire_merge(@key, "b", t)
    end

    test "within the lease a held slot stays held", %{train: t} do
      assert :ok = MergeTrain.acquire_merge(@key, "a", t)
      assert {:busy, "a"} = MergeTrain.acquire_merge(@key, "b", t)
    end
  end

  test "view/2 names the head and the waiting MRs", %{train: t} do
    assert :head = MergeTrain.claim(@key, entry("a"), t)
    assert {:wait, "a"} = MergeTrain.claim(@key, entry("b"), t)

    assert %{head: "a", waiting: ["b"]} = MergeTrain.view(@key, t)
    assert %{head: nil, waiting: []} = MergeTrain.view({"x", "y", "z"}, t)
  end
end
