defmodule Arbiter.Board.AutopilotRefusedDispatchTest do
  @moduledoc """
  bd-1ggu6v: a dispatch refused for a reason that is the card's, not the
  scheduler's — a sandbox backend that cannot run the routed provider, a
  migrations check that could not reach the database — is held with a backoff
  instead of being retried on every pass, and a promotion that never returns is
  reaped at a deadline instead of pinning the one-promotion slot forever.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  @sandbox_refusal {:sandbox_backend, :grok,
                    "held — grok: not supported by sandbox.backend podman"}
  @migrations_refusal {:migrations_check_failed, :unreachable}

  defp board(promote) do
    %{
      ready: [%{id: "bd-1", state: :next, reason: "next up", card: %{id: "bd-1"}}],
      backlog: [],
      blocked: [],
      in_progress: [],
      merging: [],
      verifying: [],
      closed_today: [],
      attention: [],
      promote: promote,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: false,
      now: DateTime.utc_now()
    }
  end

  defp start(opts) do
    test = self()
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)

    defaults = [
      name: nil,
      interval_ms: :never,
      debounce_ms: 60_000,
      topics: [],
      follow_up: false,
      paused: false,
      registry_settled?: fn -> true end,
      now: fn -> Agent.get(clock, & &1) end,
      escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end,
      snapshot: fn _ -> board("bd-1") end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    {pid, clock}
  end

  defp advance(clock, seconds),
    do: Agent.update(clock, fn now -> DateTime.add(now, seconds, :second) end)

  defp refusing(refusal) do
    test = self()

    fn id ->
      send(test, {:dispatch_attempt, id})
      {:error, refusal}
    end
  end

  # A tick that actually attempts a dispatch, moving the clock past any hold. A
  # refusal queues an immediate pass; let it run at the old clock (it finds the
  # card held) before the clock moves, or it would dispatch at the new one.
  defp attempt(pid, clock, refusal) do
    _ = :sys.get_state(pid)
    advance(clock, 3_600)
    assert {:error, ^refusal} = Autopilot.tick(pid)
    assert_receive {:dispatch_attempt, "bd-1"}
  end

  describe "a sandbox_backend refusal" do
    test "is held with a backoff, not retried on the next pass" do
      {pid, clock} = start(dispatch: refusing(@sandbox_refusal))

      assert {:error, @sandbox_refusal} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
      # The refusal does not pin the promotion slot.
      assert %{dispatching: nil} = Autopilot.status(pid)

      assert {:held, "bd-1", until} = Autopilot.tick(pid)
      assert DateTime.diff(until, Agent.get(clock, & &1), :second) in 1..600
      refute_receive {:dispatch_attempt, _}, 50

      # Past the window it is attempted again.
      _ = :sys.get_state(pid)
      advance(clock, 3_600)
      assert {:error, @sandbox_refusal} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
    end

    test "backs off further on each repeat, up to a cap" do
      {pid, clock} = start(dispatch: refusing(@sandbox_refusal))

      holds =
        for _ <- 1..8 do
          attempt(pid, clock, @sandbox_refusal)
          assert {:held, "bd-1", until} = Autopilot.tick(pid)
          DateTime.diff(until, Agent.get(clock, & &1), :second)
        end

      assert holds == Enum.sort(holds)
      assert List.last(holds) == 600
    end

    test "still escalates as dispatch_stuck after 3 attempts" do
      {pid, clock} = start(dispatch: refusing(@sandbox_refusal))

      attempt(pid, clock, @sandbox_refusal)
      attempt(pid, clock, @sandbox_refusal)
      refute_receive {:escalated, _, _, _}, 50

      attempt(pid, clock, @sandbox_refusal)
      assert_receive {:escalated, "bd-1", @sandbox_refusal, 3}
    end

    test "is logged as a hold, not a failure" do
      {pid, _clock} = start(dispatch: refusing(@sandbox_refusal))

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert {:error, @sandbox_refusal} = Autopilot.tick(pid)
        end)

      refute log =~ "failed"
    end
  end

  describe "a migrations_check_failed refusal (a transient count_pending error)" do
    test "is held briefly and retried" do
      {pid, clock} = start(dispatch: refusing(@migrations_refusal))

      assert {:error, @migrations_refusal} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}

      assert {:held, "bd-1", until} = Autopilot.tick(pid)
      assert DateTime.diff(until, Agent.get(clock, & &1), :second) in 1..60
      refute_receive {:dispatch_attempt, _}, 50

      _ = :sys.get_state(pid)
      advance(clock, 60)
      assert {:error, @migrations_refusal} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
    end

    test "never counts toward dispatch stuck, however often it repeats" do
      {pid, clock} = start(dispatch: refusing(@migrations_refusal))

      for _ <- 1..6, do: attempt(pid, clock, @migrations_refusal)

      refute_receive {:escalated, _, _, _}, 50
    end
  end

  describe "a promotion that never returns" do
    test "is reaped at the dispatch deadline and its slot released" do
      test = self()

      {pid, clock} =
        start(
          dispatch_timeout_ms: 1_000,
          dispatch: fn id ->
            send(test, {:dispatched, id, self()})

            receive do
              :never -> {:ok, %{task_id: id}}
            end
          end
        )

      ticker = Task.async(fn -> Autopilot.tick(pid) end)
      assert_receive {:dispatched, "bd-1", task}, 2_000
      ref = Process.monitor(task)
      assert %{dispatching: "bd-1"} = Autopilot.status(pid)

      # Within the deadline the promotion is left alone.
      assert {:busy, "bd-1"} = Autopilot.tick(pid)

      # Nothing left to promote once it is reaped.
      :sys.replace_state(pid, fn s -> %{s | snapshot: fn _ -> board(nil) end} end)
      advance(clock, 2)
      assert :idle = Autopilot.tick(pid)

      assert {:error, :dispatch_timeout} = Task.await(ticker)
      assert_receive {:DOWN, ^ref, :process, ^task, _}
      assert %{dispatching: nil} = Autopilot.status(pid)
    end
  end
end
