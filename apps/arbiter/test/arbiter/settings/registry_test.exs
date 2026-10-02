defmodule Arbiter.Settings.RegistryTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Settings
  alias Arbiter.Settings.Registry

  @keys ~w(conductor_system_max_concurrent credential_watchdog_adapters
           credential_watchdog_interval_ms credential_watchdog_recovery_interval_ms
           quota_providers_shown quota_providers_hidden output_offload_enabled
           scheduling_epic_floors_enabled scheduling_max_lifted_in_flight
           scheduling_finish_first scheduling_finish_first_max_wait_hours)

  test "keys/0 lists every installation setting" do
    assert Registry.keys() == @keys
    assert Enum.map(Registry.schema(), & &1.key) == @keys
  end

  describe "cast/2" do
    test "positive integers, null, and stringified JSON" do
      assert {:ok, 3} = Registry.cast("conductor_system_max_concurrent", 3)
      assert {:ok, 3} = Registry.cast("conductor_system_max_concurrent", "3")
      assert {:ok, nil} = Registry.cast("conductor_system_max_concurrent", nil)
      assert {:error, msg} = Registry.cast("conductor_system_max_concurrent", 0)
      assert msg =~ "positive integer"
    end

    test "adapter lists keep [] distinct from nil" do
      assert {:ok, []} = Registry.cast("credential_watchdog_adapters", [])
      assert {:ok, ["claude"]} = Registry.cast("credential_watchdog_adapters", "[\"claude\"]")
      assert {:ok, nil} = Registry.cast("credential_watchdog_adapters", nil)
      assert {:error, _} = Registry.cast("credential_watchdog_adapters", ["bogus"])
    end
  end

  describe "output_offload_enabled" do
    test "is a boolean that defaults to off and is distinct from null" do
      assert {:ok, true} = Registry.cast("output_offload_enabled", true)
      assert {:ok, false} = Registry.cast("output_offload_enabled", "false")
      assert {:ok, nil} = Registry.cast("output_offload_enabled", nil)
      assert {:error, _} = Registry.cast("output_offload_enabled", "yes")

      assert Registry.describe("output_offload_enabled").value == false
      assert {:ok, true} = Registry.put("output_offload_enabled", true)
      assert Registry.describe("output_offload_enabled").value == true
      assert {:ok, nil} = Registry.put("output_offload_enabled", nil)
      assert Registry.describe("output_offload_enabled").overridden == false
    end
  end

  describe "scheduling keys (ES3, epic-aware-scheduling §6.6)" do
    test "defaults: floors on, derived lift cap, finish-first off, 24h aging" do
      assert %{value: true, overridden: false} =
               Registry.describe("scheduling_epic_floors_enabled")

      assert %{value: nil, overridden: false} =
               Registry.describe("scheduling_max_lifted_in_flight")

      assert %{value: false, overridden: false} = Registry.describe("scheduling_finish_first")

      assert %{value: 24, overridden: false} =
               Registry.describe("scheduling_finish_first_max_wait_hours")

      assert Settings.scheduling() == %{
               epic_floors_enabled: true,
               max_lifted_in_flight: nil,
               finish_first: false,
               finish_first_max_wait_hours: 24
             }
    end

    test "booleans reject anything but true, false or null" do
      for key <- ~w(scheduling_epic_floors_enabled scheduling_finish_first) do
        assert {:ok, true} = Registry.cast(key, true)
        assert {:ok, false} = Registry.cast(key, "false")
        assert {:ok, nil} = Registry.cast(key, nil)
        assert {:error, _} = Registry.cast(key, "yes")
        assert {:error, _} = Registry.cast(key, 1)
        assert {:error, {:invalid, _}} = Registry.put(key, "maybe")
      end
    end

    test "the lift cap and the aging threshold reject zero, negatives, fractions and text" do
      for key <- ~w(scheduling_max_lifted_in_flight scheduling_finish_first_max_wait_hours),
          bad <- [0, -1, 1.5, "two", true, [1]] do
        assert {:error, msg} = Registry.cast(key, bad)
        assert msg =~ "positive integer"
        assert {:error, {:invalid, _}} = Registry.put(key, bad)
        assert Registry.override(key) == nil
      end

      assert {:ok, 4} = Registry.cast("scheduling_max_lifted_in_flight", "4")
    end

    test "set, read back through scheduling/0, and clear" do
      assert {:ok, false} = Registry.put("scheduling_epic_floors_enabled", false)
      assert {:ok, 1} = Registry.put("scheduling_max_lifted_in_flight", 1)
      assert {:ok, true} = Registry.put("scheduling_finish_first", true)
      assert {:ok, 6} = Registry.put("scheduling_finish_first_max_wait_hours", 6)

      assert Settings.scheduling() == %{
               epic_floors_enabled: false,
               max_lifted_in_flight: 1,
               finish_first: true,
               finish_first_max_wait_hours: 6
             }

      for key <- ~w(scheduling_epic_floors_enabled scheduling_max_lifted_in_flight
                    scheduling_finish_first scheduling_finish_first_max_wait_hours) do
        assert {:ok, nil} = Registry.put(key, nil)
      end

      assert Settings.scheduling().epic_floors_enabled
      refute Settings.scheduling().finish_first
    end

    test "the Settings setters refuse bad values directly" do
      assert {:error, :invalid_value} = Settings.set_scheduling_max_lifted_in_flight(0)
      assert {:error, :invalid_value} = Settings.set_scheduling_finish_first_max_wait_hours(-3)
      assert {:error, :invalid_value} = Settings.set_scheduling_finish_first("yes")
      assert {:error, :invalid_value} = Settings.set_scheduling_epic_floors_enabled(0)
    end
  end

  describe "put/2 and describe/1" do
    test "set, describe and clear" do
      assert {:ok, []} = Registry.put("credential_watchdog_adapters", [])
      d = Registry.describe("credential_watchdog_adapters")
      assert d.overridden == true
      assert d.override == []
      assert d.value == []

      assert {:ok, nil} = Registry.put("credential_watchdog_adapters", nil)
      d = Registry.describe("credential_watchdog_adapters")
      assert d.overridden == false
      assert d.override == nil
      assert is_list(d.value)
      assert d.value == d.default
    end

    test "invalid value changes nothing" do
      {:ok, 4} = Registry.put("conductor_system_max_concurrent", 4)
      assert {:error, {:invalid, _}} = Registry.put("conductor_system_max_concurrent", -1)
      assert Settings.conductor_system_max_concurrent() == 4
    end

    test "unknown key" do
      assert {:error, {:invalid, "unknown installation setting: nope"}} = Registry.put("nope", 1)
      assert Registry.describe("nope") == nil
    end

    test "all/0 describes every key" do
      assert Enum.map(Registry.all(), & &1.key) == @keys
    end
  end
end
