defmodule Arbiter.Reports.CacheTest do
  use ExUnit.Case, async: false

  alias Arbiter.Reports.Cache

  setup do
    prior = Application.get_env(:arbiter, Cache)
    Application.put_env(:arbiter, Cache, enabled: true)
    Cache.invalidate()

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, Cache, prior),
        else: Application.delete_env(:arbiter, Cache)

      Cache.invalidate()
    end)
  end

  test "memoizes per key and returns a stable computed-at" do
    counter = :counters.new(1, [])

    compute = fn ->
      :counters.add(counter, 1, 1)
      :counters.get(counter, 1)
    end

    {v1, at1} = Cache.fetch({:r, %{a: 1}}, compute)
    {v2, at2} = Cache.fetch({:r, %{a: 1}}, compute)
    {v3, _} = Cache.fetch({:r, %{a: 2}}, compute)

    assert {v1, at1} == {v2, at2}
    assert v3 == 2
  end

  test "invalidate/0 drops entries" do
    {1, _} = Cache.fetch(:k, fn -> 1 end)
    Cache.invalidate()
    assert {2, _} = Cache.fetch(:k, fn -> 2 end)
  end

  test "disabled config computes every time" do
    Application.put_env(:arbiter, Cache, enabled: false)
    {1, _} = Cache.fetch(:d, fn -> 1 end)
    assert {2, _} = Cache.fetch(:d, fn -> 2 end)
  end
end
