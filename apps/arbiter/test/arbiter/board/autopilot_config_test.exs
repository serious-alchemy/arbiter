defmodule Arbiter.Board.AutopilotConfigTest do
  use ExUnit.Case, async: false

  alias Arbiter.Board.Autopilot

  # A board with one promotable card, as `Snapshot.derive/1` would return it.
  defp board(promote, paused? \\ false) do
    %{
      ready: [
        %{id: "bd-1", state: :next, reason: "next up — dispatching...", card: %{id: "bd-1"}}
      ],
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
      paused: paused?,
      now: DateTime.utc_now()
    }
  end

  # Start an autopilot that never ticks on its own — every test drives it by
  # hand so there is no race between the timer and the assertion.
  defp start(opts) do
    test = self()

    # Check if the test wants to use the real default_dispatch (for testing with mocks)
    use_real_dispatch = Keyword.get(opts, :use_real_dispatch, false)
    opts = Keyword.delete(opts, :use_real_dispatch)

    defaults = [
      name: nil,
      interval_ms: :never,
      topics: [],
      snapshot: fn opts -> board("bd-1", opts[:paused]) end
    ]

    # Only include the mock dispatch if not using the real one
    defaults =
      if use_real_dispatch do
        defaults
      else
        defaults ++
          [dispatch: fn id -> send(test, {:dispatched, id}) && {:ok, %{task_id: id}} end]
      end

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "persisted pause state unreadable at boot (bd-c3b30g)" do
    import ExUnit.CaptureLog

    # A read that fails until the test releases it — Autopilot starts before
    # `Boot.Migrator`, so on a pending installation_settings migration the real
    # read errors until the migration lands.
    defp flaky_read(failures, status) do
      {:ok, counter} = Agent.start_link(fn -> failures end)

      fn ->
        case Agent.get_and_update(counter, fn n -> {n, max(n - 1, 0)} end) do
          0 -> {:ok, status}
          _ -> {:error, {:no_such_column, "board_autopilot_paused_at"}}
        end
      end
    end

    setup do
      saved = Application.get_env(:arbiter, :board_autopilot, :not_set)
      Application.delete_env(:arbiter, :board_autopilot)

      on_exit(fn ->
        if saved == :not_set,
          do: Application.delete_env(:arbiter, :board_autopilot),
          else: Application.put_env(:arbiter, :board_autopilot, saved)
      end)
    end

    test "warns, and adopts the persisted unpaused state once the read works" do
      status = %{paused: false, changed_at: ~U[2026-10-01 01:28:03Z], changed_by: "api"}
      test = self()

      log =
        capture_log(fn ->
          pid =
            start(
              read_status: flaky_read(1, status),
              state_retry_ms: 10,
              snapshot: fn opts -> board(nil, opts[:paused]) end
            )

          # Boot fell back to the safe default, which is what v0.2.7 shipped.
          send(test, {:booted, Autopilot.paused?(pid)})

          :ok = wait_until(fn -> Autopilot.paused?(pid) == false end)
          send(test, {:status, Autopilot.status(pid)})
        end)

      assert_received {:booted, true}
      assert_received {:status, %{paused?: false, changed_by: "api"}}
      assert log =~ "could not read the persisted paused state at boot"
    end

    test "an unreadable row raises a coordinator-visible notice after repeated failures" do
      test = self()

      capture_log(fn ->
        start(
          read_status: fn -> {:error, :boom} end,
          state_retry_ms: 5,
          notify_unreadable: fn reason -> send(test, {:notified, reason}) end
        )

        assert_receive {:notified, :boom}, 2_000
      end)
    end

    test "an explicit pause/resume during the retry window is not overridden" do
      status = %{paused: true, changed_at: nil, changed_by: nil}

      capture_log(fn ->
        pid = start(read_status: flaky_read(2, status), state_retry_ms: 60_000)
        :ok = Autopilot.resume(pid)
        assert false === Autopilot.paused?(pid)
        send(pid, :reload_paused_state)
        _ = :sys.get_state(pid)
        assert false === Autopilot.paused?(pid)
      end)
    end

    test "nothing persisted is not an error: config default, no retry" do
      pid = start(read_status: fn -> {:ok, %{paused: nil, changed_at: nil, changed_by: nil}} end)
      assert true === Autopilot.paused?(pid)
      assert %{state_load: :settled} = :sys.get_state(pid)
    end

    defp wait_until(fun, tries \\ 200) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition never held")
        true -> Process.sleep(10) && wait_until(fun, tries - 1)
      end
    end
  end

  describe "boot-time defaults from app config" do
    test "with no :board_autopilot config, autopilot starts paused" do
      # Save the current config
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)

      try do
        # Clear the config to simulate a fresh install with no config set
        Application.delete_env(:arbiter, :board_autopilot)

        # Start autopilot without explicit :paused option — should use the app config default
        pid = start(name: nil, interval_ms: :never, snapshot: fn _ -> board(nil) end)

        # With no config, it should start paused (safe default)
        assert true === Autopilot.paused?(pid)
        assert :paused = Autopilot.tick(pid)
      after
        # Restore the original config
        if saved_config == :not_set do
          Application.delete_env(:arbiter, :board_autopilot)
        else
          Application.put_env(:arbiter, :board_autopilot, saved_config)
        end
      end
    end

    test "with enabled: true in config, autopilot starts unpaused" do
      # Save the current config
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)

      try do
        # Set the config to enable autopilot
        Application.put_env(:arbiter, :board_autopilot, enabled: true)

        # Start autopilot without explicit :paused option — should use the app config default
        pid = start(name: nil, interval_ms: :never, snapshot: fn _ -> board("bd-1") end)

        # With enabled: true, it should start unpaused
        assert false === Autopilot.paused?(pid)
        assert {:ok, "bd-1"} = Autopilot.tick(pid)
      after
        # Restore the original config
        if saved_config == :not_set do
          Application.delete_env(:arbiter, :board_autopilot)
        else
          Application.put_env(:arbiter, :board_autopilot, saved_config)
        end
      end
    end

    test "with no :board_autopilot config, the fallback tick defaults to 60 seconds" do
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)

      try do
        Application.delete_env(:arbiter, :board_autopilot)

        {:ok, pid} =
          Autopilot.start_link(name: nil, paused: true, snapshot: fn _ -> board(nil) end)

        assert %{interval_ms: 60_000} = :sys.get_state(pid)
      after
        if saved_config == :not_set do
          Application.delete_env(:arbiter, :board_autopilot)
        else
          Application.put_env(:arbiter, :board_autopilot, saved_config)
        end
      end
    end

    test "interval_ms in config overrides the 60s default" do
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)

      try do
        Application.put_env(:arbiter, :board_autopilot, enabled: true, interval_ms: 30_000)

        {:ok, pid} =
          Autopilot.start_link(name: nil, paused: true, snapshot: fn _ -> board(nil) end)

        assert %{interval_ms: 30_000} = :sys.get_state(pid)
      after
        if saved_config == :not_set do
          Application.delete_env(:arbiter, :board_autopilot)
        else
          Application.put_env(:arbiter, :board_autopilot, saved_config)
        end
      end
    end
  end

  # bd-jw7cb0: `interval_ms: :never` only stops the fallback tick. Since the
  # reactive triggers (#1999), a resumed autopilot also runs a pass on every
  # "tasks" lifecycle broadcast and every worker_done/worker_failed event — so
  # the suite's VM-global autopilot, resumed by the board LiveView tests,
  # dispatched those tests' own Ready fixtures behind their backs and escalated
  # the failures from a DB connection whose owner had already exited.
  describe "reactive subscriptions from app config (bd-jw7cb0)" do
    # Moved here from `Arbiter.Board.AutopilotTest` (async): it now has to clear
    # the test env's own `topics: []` to reach the production default.
    test "with no :topics anywhere, a task closing runs a pass over the real default topics" do
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)
      test = self()

      try do
        Application.put_env(:arbiter, :board_autopilot, enabled: false, interval_ms: :never)

        {:ok, pid} =
          Autopilot.start_link(
            name: nil,
            interval_ms: :never,
            debounce_ms: 20,
            paused: false,
            follow_up: false,
            snapshot: fn opts -> board("bd-1", opts[:paused]) end,
            dispatch: fn id -> send(test, {:dispatched, id}) && {:ok, %{task_id: id}} end
          )

        assert Enum.sort(Registry.keys(Arbiter.PubSub, pid)) ==
                 Enum.sort(Autopilot.default_topics())

        Phoenix.PubSub.broadcast(
          Arbiter.PubSub,
          "tasks",
          {:task_lifecycle, :closed, %{id: "bd-2"}}
        )

        assert_receive {:dispatched, "bd-1"}, 500
      after
        restore_config(saved_config)
      end
    end

    test "topics in config replaces the default subscriptions" do
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)
      topic = "autopilot-config-#{System.unique_integer([:positive])}"
      test = self()

      try do
        Application.put_env(:arbiter, :board_autopilot, topics: [topic])

        {:ok, pid} =
          Autopilot.start_link(
            name: nil,
            paused: false,
            interval_ms: :never,
            debounce_ms: 0,
            snapshot: fn opts ->
              send(test, {:board_read, self()})
              board(nil, opts[:paused])
            end
          )

        assert Registry.keys(Arbiter.PubSub, pid) == [topic]

        Phoenix.PubSub.broadcast(Arbiter.PubSub, topic, {:task_lifecycle, :promoted, %{}})
        assert_receive {:board_read, ^pid}, 1_000
      after
        restore_config(saved_config)
      end
    end

    test "topics: [] means a resumed autopilot never runs a pass on its own" do
      saved_config = Application.get_env(:arbiter, :board_autopilot, :not_set)
      test = self()

      try do
        Application.put_env(:arbiter, :board_autopilot, topics: [])

        {:ok, pid} =
          Autopilot.start_link(
            name: nil,
            paused: false,
            interval_ms: :never,
            debounce_ms: 0,
            snapshot: fn opts ->
              send(test, {:board_read, self()})
              board(nil, opts[:paused])
            end
          )

        assert Registry.keys(Arbiter.PubSub, pid) == []
        send(pid, {:task_lifecycle, :promoted, %{}})
        _ = :sys.get_state(pid)
        # The trigger itself still works when it does arrive; there is just
        # nothing subscribed to deliver it.
        assert_receive {:board_read, ^pid}, 1_000
      after
        restore_config(saved_config)
      end
    end

    test "the suite's global autopilot subscribes to nothing" do
      # What every LiveView test that calls `Autopilot.resume(Autopilot)` relies
      # on: resumed, it still cannot react to that test's fixtures.
      assert Registry.keys(Arbiter.PubSub, Process.whereis(Autopilot)) == []
    end
  end

  defp restore_config(:not_set), do: Application.delete_env(:arbiter, :board_autopilot)
  defp restore_config(saved), do: Application.put_env(:arbiter, :board_autopilot, saved)
end
