defmodule Arbiter.Settings.RegistryTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Settings
  alias Arbiter.Settings.Registry

  @keys ~w(credential_watchdog_adapters
           credential_watchdog_interval_ms credential_watchdog_recovery_interval_ms
           quota_providers_shown quota_providers_hidden output_offload_enabled
           scheduling_epic_floors_enabled scheduling_max_lifted_in_flight
           scheduling_finish_first scheduling_finish_first_max_wait_hours
           scheduler_admission
           nodes.public_url nodes.allow_public_endpoint nodes.join_token_ttl_minutes
           nodes.fence_after_s nodes.lost_after_s nodes.registry nodes.registry_username
           nodes.registry_password nodes.registry_insecure)

  test "keys/0 lists every installation setting" do
    assert Registry.keys() == @keys
    assert Enum.map(Registry.schema(), & &1.key) == @keys
  end

  describe "cast/2" do
    test "positive integers, null, and stringified JSON" do
      assert {:ok, 3} = Registry.cast("credential_watchdog_interval_ms", 3)
      assert {:ok, 3} = Registry.cast("credential_watchdog_interval_ms", "3")
      assert {:ok, nil} = Registry.cast("credential_watchdog_interval_ms", nil)
      assert {:error, msg} = Registry.cast("credential_watchdog_interval_ms", 0)
      assert msg =~ "positive integer"
    end

    test "the deleted conductor_system_max_concurrent is not a key any more (DC1)" do
      refute "conductor_system_max_concurrent" in Registry.keys()
      assert Registry.describe("conductor_system_max_concurrent") == nil

      assert {:error, {:invalid, "unknown installation setting: conductor_system_max_concurrent"}} =
               Registry.put("conductor_system_max_concurrent", 4)
    end

    test "adapter lists keep [] distinct from nil" do
      assert {:ok, []} = Registry.cast("credential_watchdog_adapters", [])
      assert {:ok, ["claude"]} = Registry.cast("credential_watchdog_adapters", "[\"claude\"]")
      assert {:ok, nil} = Registry.cast("credential_watchdog_adapters", nil)
      assert {:error, _} = Registry.cast("credential_watchdog_adapters", ["bogus"])
    end
  end

  describe "nodes.registry settings (K8)" do
    test "the registry reference is a bare host[:port]/path, no scheme or credentials" do
      assert {:ok, "registry.example.com/arbiter"} =
               Registry.cast("nodes.registry", "registry.example.com/arbiter")

      assert {:ok, "localhost:5000"} = Registry.cast("nodes.registry", "localhost:5000")
      assert {:ok, nil} = Registry.cast("nodes.registry", nil)

      for bad <- ["https://registry.example.com", "user:pw@registry.example.com", "a b", "-x/y"] do
        assert {:error, msg} = Registry.cast("nodes.registry", bad)
        assert msg =~ "registry"
      end
    end

    test "all four keys are operator-only" do
      for key <- ~w(nodes.registry nodes.registry_username nodes.registry_password
                    nodes.registry_insecure) do
        assert key in Registry.operator_only_keys()

        assert {:error, {:unauthorized, _}} = Registry.put(key, "x", authority: :coordinator)
      end
    end

    test "the password is stored encrypted and no read surface ever returns it" do
      assert {:ok, stored} = Registry.put("nodes.registry_password", "s3cret-pw-value")
      refute inspect(stored) =~ "s3cret-pw-value"

      assert Settings.nodes_registry_password() == "s3cret-pw-value"

      raw =
        Arbiter.Settings.Installation
        |> Ash.read!()
        |> hd()
        |> Map.fetch!(:nodes_registry_password)

      assert is_binary(raw)
      refute raw =~ "s3cret-pw-value"

      described = Registry.describe("nodes.registry_password")
      assert described.overridden
      refute inspect(described) =~ "s3cret-pw-value"
      refute inspect(Registry.all()) =~ "s3cret-pw-value"
      refute inspect(Registry.overrides()) =~ "s3cret-pw-value"

      assert {:ok, nil} = Registry.put("nodes.registry_password", nil)
      assert Settings.nodes_registry_password() == nil
      refute Registry.describe("nodes.registry_password").overridden
    end

    test "username, registry and insecure round-trip" do
      assert {:ok, "reg.example.com:5000/arb"} =
               Registry.put("nodes.registry", "reg.example.com:5000/arb")

      assert {:ok, "bot"} = Registry.put("nodes.registry_username", "bot")
      assert {:ok, true} = Registry.put("nodes.registry_insecure", true)
      assert Settings.nodes_registry() == "reg.example.com:5000/arb"
      assert Settings.nodes_registry_username() == "bot"
      assert Settings.nodes_registry_insecure?()
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

  describe "scheduler_admission (DC6, provider-dynamic-concurrency §10.1)" do
    setup do
      on_exit(fn -> Settings.set_scheduler_admission(nil) end)
    end

    test "defaults to legacy, with the three modes allowed" do
      assert %{
               value: "legacy",
               default: "legacy",
               overridden: false,
               allowed: ["legacy", "shadow", "enforce"],
               operator_only: false
             } = Registry.describe("scheduler_admission")

      assert Settings.scheduler_admission() == :legacy
    end

    test "takes the three modes or null, and nothing else" do
      for mode <- ~w(legacy shadow enforce) do
        assert {:ok, ^mode} = Registry.cast("scheduler_admission", mode)
      end

      assert {:ok, nil} = Registry.cast("scheduler_admission", nil)

      for bad <- ["on", "Shadow", 1, true, ["shadow"]] do
        assert {:error, msg} = Registry.cast("scheduler_admission", bad)
        assert msg =~ "legacy, shadow or enforce"
      end
    end

    test "set, read back as the mode in force, and clear" do
      assert {:ok, "shadow"} = Registry.put("scheduler_admission", "shadow")
      assert Settings.scheduler_admission() == :shadow
      assert %{value: "shadow", overridden: true} = Registry.describe("scheduler_admission")

      assert {:ok, "enforce"} = Registry.put("scheduler_admission", "enforce")
      assert Settings.scheduler_admission() == :enforce

      assert {:ok, nil} = Registry.put("scheduler_admission", nil)
      assert Settings.scheduler_admission() == :legacy
    end

    test "the coordinator may set legacy or shadow (the kill switch); enforce is the operator's" do
      for authority <- [:coordinator, :restricted] do
        assert {:ok, "shadow"} =
                 Registry.put("scheduler_admission", "shadow", authority: authority)

        assert {:ok, "legacy"} =
                 Registry.put("scheduler_admission", "legacy", authority: authority)

        assert {:ok, nil} = Registry.put("scheduler_admission", nil, authority: authority)

        assert {:error, {:unauthorized, msg}} =
                 Registry.put("scheduler_admission", "enforce", authority: authority)

        assert msg =~ "enforce"
        assert msg =~ "operator"
        assert Settings.scheduler_admission() == :legacy
      end

      assert {:ok, "enforce"} =
               Registry.put("scheduler_admission", "enforce", authority: :operator)
    end

    test "the Settings setter refuses anything but a mode or nil" do
      assert {:error, :invalid_value} = Settings.set_scheduler_admission("on")
      assert {:error, :invalid_value} = Settings.set_scheduler_admission(:sideways)
      assert {:ok, "shadow"} = Settings.set_scheduler_admission(:shadow)
      assert Settings.scheduler_admission() == :shadow
    end
  end

  describe "nodes.* settings (RW3)" do
    test "nodes.public_url takes an http(s) origin and normalises the trailing slash" do
      assert {:ok, "https://box.tail1234.ts.net"} =
               Registry.put("nodes.public_url", "https://box.tail1234.ts.net/")

      assert Settings.nodes_public_url() == "https://box.tail1234.ts.net"
      assert Registry.describe("nodes.public_url").override == "https://box.tail1234.ts.net"
      assert {:ok, nil} = Registry.put("nodes.public_url", nil)
      assert Settings.nodes_public_url() == nil
    end

    test "nodes.public_url refuses anything that is not a bare http(s) URL" do
      for bad <- [
            "ftp://box",
            "box.ts.net",
            "https://",
            "https://u:p@box",
            "https://box/?x=1",
            "https://box#frag",
            "javascript:alert(1)",
            5,
            ""
          ] do
        assert {:error, {:invalid, _}} = Registry.put("nodes.public_url", bad), inspect(bad)
      end

      assert Settings.nodes_public_url() == nil
    end

    test "nodes.allow_public_endpoint defaults off" do
      assert Registry.describe("nodes.allow_public_endpoint").value == false
      assert {:ok, true} = Registry.put("nodes.allow_public_endpoint", true)
      assert Settings.nodes_allow_public_endpoint?()
      assert {:ok, nil} = Registry.put("nodes.allow_public_endpoint", nil)
      refute Settings.nodes_allow_public_endpoint?()
    end

    test "nodes.join_token_ttl_minutes defaults to 15 and is capped at 24 hours" do
      assert Registry.describe("nodes.join_token_ttl_minutes").value == 15
      assert Settings.nodes_join_token_ttl_minutes() == 15

      assert {:ok, 60} = Registry.put("nodes.join_token_ttl_minutes", 60)
      assert Settings.nodes_join_token_ttl_minutes() == 60

      assert {:error, {:invalid, _}} = Registry.put("nodes.join_token_ttl_minutes", 1441)
      assert {:error, {:invalid, _}} = Registry.put("nodes.join_token_ttl_minutes", 0)
      assert {:ok, nil} = Registry.put("nodes.join_token_ttl_minutes", nil)
      assert Settings.nodes_join_token_ttl_minutes() == 15
    end

    test "overrides/0 reports them under their dotted names" do
      assert %{"nodes.public_url": nil, "nodes.allow_public_endpoint": nil} =
               Registry.overrides()
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
      {:ok, 4} = Registry.put("credential_watchdog_interval_ms", 4)
      assert {:error, {:invalid, _}} = Registry.put("credential_watchdog_interval_ms", -1)
      assert Settings.credential_watchdog_interval_ms() == 4
    end

    test "unknown key" do
      assert {:error, {:invalid, "unknown installation setting: nope"}} = Registry.put("nope", 1)
      assert Registry.describe("nope") == nil
    end

    test "all/0 describes every key" do
      assert Enum.map(Registry.all(), & &1.key) == @keys
    end
  end

  describe "put/3 authority (P-20, D-C-3)" do
    @operator_only ~w(scheduling_epic_floors_enabled scheduling_max_lifted_in_flight
                      nodes.public_url nodes.allow_public_endpoint nodes.join_token_ttl_minutes
                      nodes.fence_after_s nodes.lost_after_s nodes.registry nodes.registry_username
                      nodes.registry_password nodes.registry_insecure)

    test "operator_only_keys/0 is the schema's operator-only set" do
      assert Enum.sort(Registry.operator_only_keys()) == Enum.sort(@operator_only)

      for entry <- Registry.schema() do
        assert entry.operator_only == entry.key in @operator_only
      end
    end

    test "a coordinator or restricted authority is refused every operator-only key" do
      for authority <- [:coordinator, :restricted], key <- @operator_only do
        assert {:error, {:unauthorized, msg}} =
                 Registry.put(key, 1, authority: authority)

        assert msg =~ "operator-only"
        assert Registry.override(key) == nil
      end
    end

    test "a refusal comes before validation, so an invalid value is still unauthorized" do
      assert {:error, {:unauthorized, _}} =
               Registry.put("nodes.public_url", "not a url", authority: :coordinator)
    end

    test "a coordinator may still write the ordinary keys" do
      assert {:ok, true} = Registry.put("scheduling_finish_first", true, authority: :coordinator)
      assert {:ok, nil} = Registry.put("scheduling_finish_first", nil, authority: :coordinator)
    end

    test "operator authority, and in-process callers with no option, may write them" do
      assert {:ok, 1} = Registry.put("scheduling_max_lifted_in_flight", 1, authority: :operator)
      assert {:ok, 2} = Registry.put("scheduling_max_lifted_in_flight", 2)
      assert {:ok, nil} = Registry.put("scheduling_max_lifted_in_flight", nil)
    end
  end
end
