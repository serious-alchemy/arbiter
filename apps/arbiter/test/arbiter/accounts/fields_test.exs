defmodule Arbiter.Accounts.FieldsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.Fields

  describe "registry" do
    test "every quota key the gate reads is editable" do
      assert Enum.sort(Fields.quota_keys()) ==
               Enum.sort(~w(threshold_mode throttle_threshold weekly_threshold paced_floor
                            weekly_paced_floor weekly_warning_policy window_seconds
                            pace_exempt_priority pace_exempt_threshold
                            weekly_pace_exempt_threshold spend_cap spend_window
                            spend_mode spend_metered))
    end

    test "identity is create-only, secrets are not in the registry" do
      assert "slug" in Fields.names(:create)
      refute "slug" in Fields.names(:update)
      refute "provider" in Fields.names(:update)
      assert Fields.identity_names() == ~w(provider slug)

      all = Enum.map(Fields.all(), & &1.name)
      refute Enum.any?(all, &(&1 =~ ~r/secret|credential|token|password/))
    end

    test "the MCP surface is the update set minus identity" do
      assert Enum.sort(Fields.names(:mcp)) ==
               Enum.sort(~w(label plan enabled max_concurrent quota_config))
    end
  end

  describe "cast/2 (:update)" do
    test "casts every attribute and drops nothing" do
      assert {:ok, changes} =
               Fields.cast(
                 %{
                   "label" => " Work ",
                   "plan" => "",
                   "enabled" => "false",
                   "max_concurrent" => "3",
                   "quota_config" => %{"weekly_threshold" => "0.8"}
                 },
                 :update
               )

      assert changes == %{
               label: "Work",
               plan: nil,
               enabled: false,
               max_concurrent: 3,
               quota_config: %{"weekly_threshold" => 0.8}
             }
    end

    test "max_concurrent null/blank clears, garbage is rejected" do
      assert {:ok, %{max_concurrent: nil}} = Fields.cast(%{"max_concurrent" => nil}, :update)
      assert {:ok, %{max_concurrent: nil}} = Fields.cast(%{"max_concurrent" => ""}, :update)

      assert {:error, {:invalid_account, "max_concurrent" <> _}} =
               Fields.cast(%{"max_concurrent" => "-1"}, :update)
    end

    test "identity and unknown keys are rejected by name" do
      assert {:error, {:invalid_account, "cannot set slug"}} =
               Fields.cast(%{"slug" => "x"}, :update)

      assert {:error, {:invalid_account, "cannot set bogus"}} =
               Fields.cast(%{"bogus" => 1}, :update)
    end

    test "a quota_config nil value is kept as a clear" do
      assert {:ok, %{quota_config: %{"paced_floor" => nil}}} =
               Fields.cast(%{"quota_config" => %{"paced_floor" => nil}}, :update)
    end

    test "quota_config must be an object" do
      assert {:error, {:invalid_account, "quota_config must be an object"}} =
               Fields.cast(%{"quota_config" => "x"}, :update)
    end
  end

  describe "cast/2 (:create)" do
    test "accepts provider_account_ref and drops nil quota values" do
      assert {:ok, changes} =
               Fields.cast(
                 %{
                   "provider_account_ref" => "uuid-1",
                   "quota_config" => %{"threshold_mode" => "paced", "paced_floor" => nil}
                 },
                 :create
               )

      assert changes.provider_account_ref == "uuid-1"
      assert changes.quota_config == %{"threshold_mode" => "paced"}
    end

    test "a bad quota_config is an invalid_quota_config error" do
      assert {:error, {:invalid_quota_config, _}} =
               Fields.cast(
                 %{"quota_config" => %{"threshold_mode" => "banana", "weekly_threshold" => 7}},
                 :create
               )
    end
  end

  describe "validate_quota_config/2" do
    test "throttle_threshold is a fraction in (0, 1]" do
      assert {:ok, %{"throttle_threshold" => 0.5}} =
               Fields.validate_quota_config(%{"throttle_threshold" => "0.5"})

      assert {:error, {:invalid_quota_config, "throttle_threshold" <> _}} =
               Fields.validate_quota_config(%{"throttle_threshold" => 1.5})
    end

    test "weekly_warning_policy is ignore | hold" do
      assert {:ok, %{"weekly_warning_policy" => "hold"}} =
               Fields.validate_quota_config(%{"weekly_warning_policy" => "hold"})

      assert {:error, {:invalid_quota_config, "weekly_warning_policy" <> _}} =
               Fields.validate_quota_config(%{"weekly_warning_policy" => "maybe"})
    end

    test "window_seconds is a label => positive seconds map" do
      assert {:ok, %{"window_seconds" => %{"5h" => 18_000, "7d" => 604_800}}} =
               Fields.validate_quota_config(%{
                 "window_seconds" => %{"5h" => "18000", "7d" => 604_800}
               })

      for bad <- [%{"5h" => 0}, %{"5h" => "abc"}, %{"" => 5}, "5h=1", [1]] do
        assert {:error, {:invalid_quota_config, "window_seconds" <> _}} =
                 Fields.validate_quota_config(%{"window_seconds" => bad})
      end
    end

    test "pace_exempt_priority accepts none as the off switch (D-A-22)" do
      assert {:ok, %{"pace_exempt_priority" => 2}} =
               Fields.validate_quota_config(%{"pace_exempt_priority" => "2"})

      assert {:ok, %{"pace_exempt_priority" => nil}} =
               Fields.validate_quota_config(%{"pace_exempt_priority" => "none"}, :patch)

      assert {:error, {:invalid_quota_config, _}} =
               Fields.validate_quota_config(%{"pace_exempt_priority" => 5})
    end

    test "an unknown key is rejected in both modes, nil or not" do
      assert {:error, {:invalid_quota_config, "unknown quota_config key(s): nope"}} =
               Fields.validate_quota_config(%{"nope" => 1})

      assert {:error, {:invalid_quota_config, "unknown quota_config key(s): nope"}} =
               Fields.validate_quota_config(%{"nope" => nil}, :patch)
    end

    test "a nil value is a clear in :patch mode only" do
      assert {:ok, %{"weekly_threshold" => nil}} =
               Fields.validate_quota_config(%{"weekly_threshold" => nil}, :patch)

      assert {:error, {:invalid_quota_config, _}} =
               Fields.validate_quota_config(%{"weekly_threshold" => nil})
    end
  end
end
