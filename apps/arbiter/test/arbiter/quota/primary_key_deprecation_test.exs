defmodule Arbiter.Quota.PrimaryKeyDeprecationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.PrimaryKeyDeprecation

  defp claude(cfg), do: %ProviderAccount{provider: :claude, slug: "default", quota_config: cfg}
  defp ws(cfg), do: %{name: "ws1", config: cfg}

  describe "find/1" do
    test "reports primary-class keys on a Claude account and a workspace" do
      found =
        PrimaryKeyDeprecation.find(
          accounts: [claude(%{"throttle_threshold" => 0.8, "weekly_threshold" => 0.9})],
          workspaces: [ws(%{"quota" => %{"paced_floor" => 0.3}})],
          app_env: [throttle_threshold: 0.8]
        )

      assert {"account claude:default", "throttle_threshold"} in found
      assert {"workspace ws1", "paced_floor"} in found
      assert {"app env :quota", "throttle_threshold"} in found
      refute Enum.any?(found, fn {_, k} -> k == "weekly_threshold" end)
    end

    test "ignores non-Claude accounts and empty configs" do
      assert [] ==
               PrimaryKeyDeprecation.find(
                 accounts: [
                   %ProviderAccount{
                     provider: :codex,
                     slug: "x",
                     quota_config: %{"throttle_threshold" => 0.5}
                   }
                 ],
                 workspaces: [ws(%{}), ws(%{"quota" => %{"on_exhaustion" => "throttle"}})],
                 app_env: []
               )
    end
  end

  describe "warn_at_boot/1" do
    test "logs one warning naming the keys" do
      log =
        capture_log([level: :warning], fn ->
          assert :ok =
                   PrimaryKeyDeprecation.warn_at_boot(
                     accounts: [claude(%{"paced_floor" => 0.3})],
                     workspaces: [],
                     app_env: []
                   )
        end)

      assert log =~ "5h window"
      assert log =~ "paced_floor"
      assert length(String.split(log, "no longer has a 5h window")) == 2
    end

    test "is silent when nothing is set" do
      log =
        capture_log([level: :warning], fn ->
          PrimaryKeyDeprecation.warn_at_boot(accounts: [], workspaces: [], app_env: [])
        end)

      refute log =~ "5h"
    end
  end
end
