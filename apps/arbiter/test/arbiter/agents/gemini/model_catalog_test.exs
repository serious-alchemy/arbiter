defmodule Arbiter.Agents.Gemini.ModelCatalogTest do
  # Process-global :persistent_term cache + app env probe.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Gemini.ModelCatalog

  @listing """
  Available models:
    gemini-3.8-flash-low
    gemini-3.8-flash-medium
    gemini-3.8-flash-high
  - claude-opus-5-5-high (default)
  * claude-sonnet-5-5-low
  gpt-oss-120b-medium
  """

  setup do
    ModelCatalog.reset()
    on_exit(&ModelCatalog.reset/0)
  end

  describe "parse/1" do
    test "extracts model ids from a plain listing, ignoring prose and bullets" do
      assert ModelCatalog.parse(@listing) == [
               "gemini-3.8-flash-low",
               "gemini-3.8-flash-medium",
               "gemini-3.8-flash-high",
               "claude-opus-5-5-high",
               "claude-sonnet-5-5-low",
               "gpt-oss-120b-medium"
             ]
    end

    test "empty or junk output parses to []" do
      assert ModelCatalog.parse("") == []
      assert ModelCatalog.parse("Error: not logged in\n") == []
    end
  end

  describe "list/1" do
    test "returns the probed models and caches them within the TTL" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      probe = fn ->
        Agent.update(counter, &(&1 + 1))
        {:ok, ["gemini-3.8-flash-low"]}
      end

      assert {:ok, ["gemini-3.8-flash-low"]} = ModelCatalog.list(probe: probe, now: 1_000)
      assert {:ok, ["gemini-3.8-flash-low"]} = ModelCatalog.list(probe: probe, now: 2_000)
      assert Agent.get(counter, & &1) == 1
    end

    test "re-probes after the TTL so a CLI auto-update is picked up" do
      first = fn -> {:ok, ["old-model-high"]} end
      second = fn -> {:ok, ["new-model-high"]} end

      assert {:ok, ["old-model-high"]} = ModelCatalog.list(probe: first, now: 0, ttl_ms: 100)
      assert {:ok, ["old-model-high"]} = ModelCatalog.list(probe: second, now: 50, ttl_ms: 100)
      assert {:ok, ["new-model-high"]} = ModelCatalog.list(probe: second, now: 200, ttl_ms: 100)
    end

    test "a failing probe is :unknown, and is retried only after the retry interval" do
      failing = fn -> {:error, :not_installed} end
      working = fn -> {:ok, ["gemini-3.8-flash-low"]} end

      assert ModelCatalog.list(probe: failing, now: 0, retry_ms: 100) == :unknown
      assert ModelCatalog.list(probe: working, now: 50, retry_ms: 100) == :unknown
      assert {:ok, _} = ModelCatalog.list(probe: working, now: 150, retry_ms: 100)
    end

    test "an empty listing is :unknown, not 'nothing is available'" do
      assert ModelCatalog.list(probe: fn -> {:ok, []} end, now: 0) == :unknown
    end

    test "refresh/1 ignores the TTL" do
      assert {:ok, ["a-1-high"]} = ModelCatalog.list(probe: fn -> {:ok, ["a-1-high"]} end, now: 0)

      assert {:ok, ["b-1-high"]} =
               ModelCatalog.refresh(probe: fn -> {:ok, ["b-1-high"]} end, now: 1)
    end
  end

  describe "available?/2" do
    test "true / false against the cached list" do
      opts = [probe: fn -> {:ok, ["gemini-3.8-flash-low"]} end, now: 0]
      assert ModelCatalog.available?("gemini-3.8-flash-low", opts)
      refute ModelCatalog.available?("gemini-3.1-pro-high", opts)
    end

    test "is true when the list is unknown (never block a spawn on a failed probe)" do
      assert ModelCatalog.available?("anything", probe: fn -> {:error, :timeout} end, now: 0)
    end

    test "a miss re-probes once the retry interval has passed, picking up a new model" do
      assert ModelCatalog.available?("old-1-high",
               probe: fn -> {:ok, ["old-1-high"]} end,
               now: 0,
               retry_ms: 100
             )

      # Inside the retry window a miss is a miss.
      refute ModelCatalog.available?("new-1-high",
               probe: fn -> {:ok, ["old-1-high", "new-1-high"]} end,
               now: 50,
               retry_ms: 100
             )

      # Past it, the miss forces a re-probe (agy auto-updated under us).
      assert ModelCatalog.available?("new-1-high",
               probe: fn -> {:ok, ["old-1-high", "new-1-high"]} end,
               now: 150,
               retry_ms: 100
             )
    end
  end

  describe "substitute/3" do
    @tiers %{
      "economy" => "gemini-3.8-flash-low",
      "standard" => "gemini-3.8-flash-medium",
      "premium" => "gemini-3.1-pro-high",
      "flagship" => "claude-opus-4-6-thinking"
    }

    test "the nearest tier whose model is available wins" do
      available = ["gemini-3.8-flash-low", "gemini-3.8-flash-medium", "claude-opus-5-5-high"]
      assert ModelCatalog.substitute("premium", @tiers, available) == "gemini-3.8-flash-medium"
    end

    test "ties between equally near tiers go to the higher tier" do
      # From `standard`, economy and premium are both one step away.
      available = ["gemini-3.8-flash-low", "gemini-3.8-flash-high"]
      tiers = Map.put(@tiers, "premium", "gemini-3.8-flash-high")
      assert ModelCatalog.substitute("standard", tiers, available) == "gemini-3.8-flash-high"
    end

    test "falls back to any available model when no tier model is available" do
      assert ModelCatalog.substitute("premium", @tiers, ["claude-sonnet-5-5-high"]) ==
               "claude-sonnet-5-5-high"
    end

    test "nil when nothing is available" do
      assert ModelCatalog.substitute("premium", @tiers, []) == nil
    end

    test "without a tier, falls back by walking from the middle of the ladder" do
      assert ModelCatalog.substitute(nil, @tiers, ["gemini-3.8-flash-medium"]) ==
               "gemini-3.8-flash-medium"
    end
  end

  describe "missing/2" do
    test "names each tier whose model is absent from the list" do
      tiers = %{"economy" => "gemini-3.8-flash-low", "premium" => "gemini-3.1-pro-high"}

      assert ModelCatalog.missing(tiers, ["gemini-3.8-flash-low"]) == [
               {"premium", "gemini-3.1-pro-high"}
             ]
    end
  end
end
