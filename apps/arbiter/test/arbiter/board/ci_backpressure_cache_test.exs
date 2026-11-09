defmodule Arbiter.Board.CiBackpressure.CacheTest do
  @moduledoc """
  The forge-poll memo: a board read never polls by itself, never waits on a slow
  forge, and never starts a second poll for a key that is already being asked.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Board.CiBackpressure.Cache

  @signal %{pending: 5, oldest_at: nil}

  setup do
    Cache.reset()
    %{key: {"ws-#{System.unique_integer([:positive])}", "vstim"}}
  end

  test "an async miss returns :unknown at once and the poll's result lands for the next read",
       %{key: key} do
    test = self()

    poll = fn ->
      send(test, {:polling, self()})

      receive do
        :go -> {:ok, @signal}
      end
    end

    assert Cache.fetch(key, 60_000, poll, async: true) == :unknown
    assert_receive {:polling, task}

    # Still in flight: a second reader neither polls again nor blocks.
    assert Cache.fetch(key, 60_000, poll, async: true) == :unknown
    refute_receive {:polling, _}, 50

    ref = Process.monitor(task)
    send(task, :go)
    assert_receive {:DOWN, ^ref, :process, ^task, _}

    assert {:ok, @signal, %DateTime{}} = Cache.fetch(key, 60_000, poll, async: true)
    refute_receive {:polling, _}, 50
  end

  test "a stale entry is served while one refresh runs", %{key: key} do
    test = self()
    assert {:ok, @signal, _} = Cache.fetch(key, 60_000, fn -> {:ok, @signal} end, async: false)

    fresher = %{pending: 1, oldest_at: nil}

    poll = fn ->
      send(test, {:polling, self()})

      receive do
        :go -> {:ok, fresher}
      end
    end

    # interval 0: everything is stale, so the old value comes back while the refresh runs.
    assert {:ok, @signal, _} = Cache.fetch(key, 0, poll, async: true)
    assert_receive {:polling, task}
    ref = Process.monitor(task)
    send(task, :go)
    assert_receive {:DOWN, ^ref, :process, ^task, _}

    assert {:ok, ^fresher, _} = Cache.fetch(key, 60_000, poll, async: true)
  end

  test "a poll that crashes or answers nonsense releases the key and reads as a failed poll",
       %{key: key} do
    ExUnit.CaptureLog.capture_log(fn ->
      assert Cache.fetch(key, 0, fn -> :nonsense end, async: false) == {:error, 1}
      assert Cache.fetch(key, 0, fn -> raise "boom" end, async: false) == {:error, 2}
      assert Cache.fetch(key, 0, fn -> {:error, :timeout} end, async: false) == {:error, 3}
    end)

    # The claim was released each time, so a good poll still runs, and clears the count.
    assert {:ok, @signal, _} = Cache.fetch(key, 0, fn -> {:ok, @signal} end, async: false)

    ExUnit.CaptureLog.capture_log(fn ->
      assert Cache.fetch(key, 0, fn -> :bad end, async: false) == {:error, 1}
    end)
  end

  test "consecutive failures are counted, and the last one logs that it is failing open",
       %{key: key} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for n <- 1..Cache.max_failures() do
          assert Cache.fetch(key, 0, fn -> {:error, :timeout} end, async: false) == {:error, n}
        end
      end)

    assert log =~ "failing open"
    assert length(String.split(log, "failing open")) == 2
  end

  test "a failed poll is retried sooner than the full interval", %{key: key} do
    test = self()

    poll = fn ->
      send(test, :polled)
      {:error, :timeout}
    end

    ExUnit.CaptureLog.capture_log(fn ->
      assert Cache.fetch(key, 60_000, poll, async: false, retry_ms: 0) == {:error, 1}
      assert Cache.fetch(key, 60_000, poll, async: false, retry_ms: 0) == {:error, 2}
    end)

    assert_received :polled
    assert_received :polled
  end

  test "a reading older than max_stale_ms is not served while it refreshes", %{key: key} do
    assert {:ok, @signal, _} = Cache.fetch(key, 60_000, fn -> {:ok, @signal} end, async: false)

    # Stale beyond the bound: the reader is told there is no usable reading yet.
    assert Cache.fetch(key, 0, fn -> {:ok, @signal} end, async: true, max_stale_ms: 0) ==
             :unknown
  end

  test "note_state/2 reports a change once", %{key: key} do
    assert Cache.note_state(key, :held) == {:changed, nil}
    assert Cache.note_state(key, :held) == :same
    assert Cache.note_state(key, :clear) == {:changed, :held}
    assert Cache.note_state(key, :clear) == :same
  end
end
