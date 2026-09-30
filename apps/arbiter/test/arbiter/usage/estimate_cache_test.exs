defmodule Arbiter.Usage.EstimateCacheTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.EstimateCache
  alias Arbiter.Usage.Event

  # config/test.exs turns the memo off for the rest of the suite (bd-jw7cb0).
  # This module is async: false, so nothing else runs while it is back on.
  setup do
    previous = Application.get_env(:arbiter, EstimateCache)
    Application.put_env(:arbiter, EstimateCache, enabled: true)
    EstimateCache.invalidate()

    on_exit(fn ->
      EstimateCache.invalidate()
      Application.put_env(:arbiter, EstimateCache, previous)
    end)

    :ok
  end

  defp query_count(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:arbiter, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {:query, ref}) end,
      nil
    )

    fun.()

    count =
      Stream.repeatedly(fn ->
        receive do
          {:query, ^ref} -> :hit
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> length()

    :telemetry.detach(ref)
    count
  end

  test "sample/1 memoizes the sample until invalidate/0" do
    now = DateTime.utc_now()
    # First call computes and caches
    sample1 = Estimate.sample(now: now)

    # Second call should hit the cache and execute 0 DB queries
    assert query_count(fn ->
             sample2 = Estimate.sample(now: now)
             assert sample2 == sample1
           end) == 0

    # Invalidation clears the cache
    EstimateCache.invalidate()

    # Next call executes queries again
    assert query_count(fn ->
             Estimate.sample(now: now)
           end) > 0
  end

  test "Event creation invalidates EstimateCache" do
    now = DateTime.utc_now()
    _sample1 = Estimate.sample(now: now)

    # Cache is warm
    assert query_count(fn -> Estimate.sample(now: now) end) == 0

    # Create an event
    {:ok, _} =
      Ash.create(Event, %{
        task_id: "task-cache-test",
        base_task_id: "task-cache-test",
        source: :task,
        step: :work,
        role: "base",
        workspace_id: "ws-cache",
        occurred_at: now,
        cost_usd: 1.0
      })

    # Cache must now be invalidated, so query count > 0
    assert query_count(fn -> Estimate.sample(now: now) end) > 0
  end

  test "enabled: false computes every call" do
    Application.put_env(:arbiter, EstimateCache, enabled: false)
    now = DateTime.utc_now()
    _ = Estimate.sample(now: now)

    assert query_count(fn -> Estimate.sample(now: now) end) > 0
  end
end
