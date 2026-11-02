defmodule Arbiter.Worker.MergeTrainCarsTest do
  @moduledoc """
  bd-6dyva0 — the speculative merge train's seats: with `merge.train.depth` K > 1
  up to K approved MRs of one target ride at once, each in a car built on the
  car ahead of it (`Arbiter.Mergers.TrainCar`). The train only says who sits
  where and what each car stands on; the Watchdogs build, test and merge.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.MergeTrain

  @key {"ws-1", "repo", "main"}

  setup do
    {:ok, train: start_supervised!({MergeTrain, name: nil, settle_ms: 0})}
  end

  defp rider(task_id, attrs \\ []) do
    Map.merge(
      %{
        task_id: task_id,
        priority: 2,
        opened_at: ~U[2026-10-29 10:00:00Z],
        mr_head: "head-#{task_id}",
        depth: 3,
        car: nil,
        car_status: :none
      },
      Map.new(attrs)
    )
  end

  defp car(task_id, base_task \\ nil),
    do: %{sha: "car-#{task_id}", base: "base-of-#{task_id}", base_task: base_task}

  # Board as a separate process (a stand-in for that MR's Watchdog), so its exit
  # can be observed by the train like a Watchdog's.
  defp watchdog do
    {:ok, agent} = Agent.start(fn -> :ok end)
    agent
  end

  defp board_as(agent, entry, t),
    do: Agent.get(agent, fn _ -> MergeTrain.board(@key, entry, t) end)

  # `:normal` is a Watchdog stopping on purpose (its MR merged); anything else
  # (`:kill`) a crash.
  defp stop(agent, :normal) do
    ref = Process.monitor(agent)
    :ok = Agent.stop(agent, :normal)
    assert_receive {:DOWN, ^ref, :process, ^agent, :normal}
  end

  defp stop(agent, reason) do
    ref = Process.monitor(agent)
    Process.exit(agent, reason)
    assert_receive {:DOWN, ^ref, :process, ^agent, _}
  end

  describe "boarding" do
    test "up to depth MRs get a seat, in order; the rest wait", %{train: t} do
      assert {:seat, %{position: 1, front?: true, base: :target, ahead: []}} =
               MergeTrain.board(@key, rider("a"), t)

      # A has not built its car yet: B has nothing to stand on.
      assert {:seat, %{position: 2, front?: false, base: :pending, ahead: ["a"]}} =
               MergeTrain.board(@key, rider("b"), t)

      assert {:seat, %{position: 3, ahead: ["a", "b"]}} = MergeTrain.board(@key, rider("c"), t)
      assert {:wait, {:full, 3}} = MergeTrain.board(@key, rider("d"), t)

      assert MergeTrain.seats(@key, t) |> Enum.map(& &1.task_id) == ~w(a b c)
    end

    test "each car stands on the car ahead of it", %{train: t} do
      MergeTrain.board(@key, rider("a"), t)
      MergeTrain.board(@key, rider("b"), t)

      MergeTrain.board(@key, rider("a", car: car("a"), car_status: :running), t)

      assert {:seat, %{base: {:car, "a", "car-a"}}} = MergeTrain.board(@key, rider("b"), t)
    end

    test "depth is the configured one: a deeper train seats more", %{train: t} do
      for id <- ~w(a b c d e), do: MergeTrain.board(@key, rider(id, depth: 5), t)
      assert length(MergeTrain.seats(@key, t)) == 5
    end

    test "a freed seat goes to the best-ordered waiting MR, not whoever asks first", %{train: t} do
      for id <- ~w(a b), do: MergeTrain.board(@key, rider(id, depth: 2), t)

      low_early = rider("c", depth: 2, priority: 2, opened_at: ~U[2026-10-29 09:00:00Z])
      high_late = rider("d", depth: 2, priority: 1, opened_at: ~U[2026-10-29 11:00:00Z])
      assert {:wait, {:full, 2}} = MergeTrain.board(@key, low_early, t)
      assert {:wait, {:full, 2}} = MergeTrain.board(@key, high_late, t)

      :ok = MergeTrain.leave(@key, "a", t)

      assert {:wait, {:full, 2}} = MergeTrain.board(@key, low_early, t)
      assert {:seat, %{position: 2}} = MergeTrain.board(@key, high_late, t)
    end

    test "a seated MR keeps its seat when a better-ordered one arrives", %{train: t} do
      MergeTrain.board(@key, rider("a", priority: 3, depth: 1), t)
      assert {:wait, {:full, 1}} = MergeTrain.board(@key, rider("b", priority: 0, depth: 1), t)

      assert {:seat, %{position: 1}} =
               MergeTrain.board(@key, rider("a", priority: 3, depth: 1), t)
    end

    test "targets have independent trains", %{train: t} do
      MergeTrain.board(@key, rider("a", depth: 1), t)

      assert {:seat, %{position: 1}} =
               MergeTrain.board({"ws-1", "repo", "release"}, rider("b", depth: 1), t)
    end
  end

  describe "a red car" do
    test "is ejected only when every car ahead of it is green", %{train: t} do
      MergeTrain.board(@key, rider("a", car: car("a"), car_status: :running), t)
      MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :red), t)

      # A's verdict is not in: B's failure may be A's.
      assert {:seat, %{red: :hold}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :red), t)

      MergeTrain.board(@key, rider("a", car: car("a"), car_status: :green), t)

      assert {:seat, %{red: :eject}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :red), t)
    end

    test "behind another red car it holds: the car ahead goes first", %{train: t} do
      MergeTrain.board(@key, rider("a", car: car("a"), car_status: :red), t)

      assert {:seat, %{red: :hold}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :red), t)

      assert {:seat, %{red: :eject}} =
               MergeTrain.board(@key, rider("a", car: car("a"), car_status: :red), t)
    end

    test "leaving re-bases every car behind it", %{train: t} do
      MergeTrain.board(@key, rider("a", car: car("a"), car_status: :green), t)
      MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :red), t)
      MergeTrain.board(@key, rider("c", car: car("c", "b"), car_status: :running), t)

      :ok = MergeTrain.leave(@key, "b", t)

      assert {:seat, %{position: 2, base: {:car, "a", "car-a"}}} =
               MergeTrain.board(@key, rider("c", car: car("c", "b"), car_status: :running), t)
    end
  end

  describe "the front" do
    test "when the front car's MR merges, the next car is the front, on the target", %{train: t} do
      a = watchdog()
      board_as(a, rider("a", car: car("a"), car_status: :green), t)
      MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)

      # The merged MR's Watchdog stops normally.
      stop(a, :normal)
      _ = :sys.get_state(t)

      assert {:seat, %{position: 1, front?: true, base: :target}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)
    end
  end

  describe "crash and restart" do
    test "a crashed Watchdog's car keeps its seat for its restart", %{train: t} do
      a = watchdog()
      board_as(a, rider("a", car: car("a"), car_status: :running), t)
      MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)

      stop(a, :kill)
      _ = :sys.get_state(t)

      # B still stands on A's car and is not the front: A has not merged.
      assert {:seat, %{position: 2, base: {:car, "a", "car-a"}}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)

      # A's restarted Watchdog takes its seat back.
      assert {:seat, %{position: 1}} =
               MergeTrain.board(@key, rider("a", car: car("a"), car_status: :running), t)
    end

    test "a crashed car nobody resumes lapses after the resume grace", %{train: t} do
      a = watchdog()
      board_as(a, rider("a", car: car("a"), car_status: :running, resume_grace_ms: 0), t)
      MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)

      stop(a, :kill)
      _ = :sys.get_state(t)

      assert {:seat, %{position: 1, base: :target}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)
    end

    test "a restarted train rebuilds the order from the cars, before seating anyone new" do
      t = start_supervised!({MergeTrain, name: nil, settle_ms: :infinity}, id: :restart)

      # C polls first, then B; A (the front car) is slowest to come back. Each car
      # names the car it stands on, so a seat is kept for it until it comes back.
      assert {:seat, %{position: 2, base: :pending, ahead: ["b"]}} =
               MergeTrain.board(@key, rider("c", car: car("c", "b"), car_status: :running), t)

      assert {:seat, %{position: 2, base: :pending, ahead: ["a"]}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)

      assert {:seat, %{position: 3, ahead: ["a", "b"]}} =
               MergeTrain.board(@key, rider("c", car: car("c", "b"), car_status: :running), t)

      # A car-less MR waits while the train forms: it must not take A's place.
      assert {:wait, :forming} = MergeTrain.board(@key, rider("d", priority: 0), t)

      assert {:seat, %{position: 1, front?: true, base: :target}} =
               MergeTrain.board(@key, rider("a", car: car("a"), car_status: :running), t)

      assert {:seat, %{position: 2, base: {:car, "a", "car-a"}}} =
               MergeTrain.board(@key, rider("b", car: car("b", "a"), car_status: :green), t)

      :ok = MergeTrain.settle_now(t)
      assert {:wait, {:full, 3}} = MergeTrain.board(@key, rider("d", priority: 0), t)
      assert MergeTrain.seats(@key, t) |> Enum.map(& &1.task_id) == ~w(a b c)
    end

    test "a car whose car ahead never comes back moves up after the resume grace" do
      t = start_supervised!({MergeTrain, name: nil, settle_ms: :infinity}, id: :ghost)

      entry = rider("b", car: car("b", "a"), car_status: :green, ghost_grace_ms: 0)
      assert {:seat, %{position: 2}} = MergeTrain.board(@key, entry, t)
      assert {:seat, %{position: 1, base: :target}} = MergeTrain.board(@key, entry, t)
    end

    test "a seat not refreshed within its ttl is dropped", %{train: t} do
      MergeTrain.board(@key, rider("a", ttl_ms: 0, resume_grace_ms: 0), t)

      assert {:seat, %{position: 1}} = MergeTrain.board(@key, rider("b"), t)
    end
  end
end
