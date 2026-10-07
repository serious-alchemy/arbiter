defmodule Arbiter.Quota.GatePolicyTest do
  @moduledoc """
  bd-c7ll4t: `Arbiter.Quota.Gate.validate_quota_config/1`,
  `Arbiter.Quota.Gate.binding_side/2`, and
  `Arbiter.Quota.Gate.account_policy_summary/1` — the API/CLI surface for
  editing and displaying an existing account's gate policy
  (`docs/provider-account-design.md` §4.2, P7).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Tasks.Workspace

  defp account!(quota_config \\ %{}) do
    n = System.unique_integer([:positive])

    Ash.create!(ProviderAccount, %{
      provider: :claude,
      slug: "gp-acct-#{n}",
      quota_config: quota_config
    })
  end

  defp workspace!(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, Map.merge(%{name: "gp-ws-#{n}", prefix: "gpw#{n}"}, attrs))
  end

  describe "validate_quota_config/1" do
    test "accepts a valid threshold_mode" do
      assert {:ok, %{"threshold_mode" => "paced"}} =
               Gate.validate_quota_config(%{"threshold_mode" => "paced"})
    end

    test "rejects an unknown threshold_mode" do
      assert {:error, {:invalid_quota_config, message}} =
               Gate.validate_quota_config(%{"threshold_mode" => "aggressive"})

      assert message =~ "threshold_mode"
    end

    test "accepts weekly_threshold, paced_floor, weekly_paced_floor as floats in 0..1" do
      assert {:ok, validated} =
               Gate.validate_quota_config(%{
                 "weekly_threshold" => 0.9,
                 "paced_floor" => 0.35,
                 "weekly_paced_floor" => 0.2
               })

      assert validated == %{
               "weekly_threshold" => 0.9,
               "paced_floor" => 0.35,
               "weekly_paced_floor" => 0.2
             }
    end

    test "coerces a numeric string to a float" do
      assert {:ok, %{"weekly_threshold" => 0.9}} =
               Gate.validate_quota_config(%{"weekly_threshold" => "0.9"})
    end

    test "rejects 0 and anything above 1" do
      assert {:error, {:invalid_quota_config, _}} =
               Gate.validate_quota_config(%{"weekly_threshold" => 0})

      assert {:error, {:invalid_quota_config, _}} =
               Gate.validate_quota_config(%{"weekly_threshold" => 1.5})
    end

    test "rejects a non-numeric value" do
      assert {:error, {:invalid_quota_config, _}} =
               Gate.validate_quota_config(%{"paced_floor" => "not-a-number"})
    end

    test "rejects an unknown key outright" do
      assert {:error, {:invalid_quota_config, message}} =
               Gate.validate_quota_config(%{"not_a_gate_key" => 0.5})

      assert message =~ "not_a_gate_key"
    end

    test "an empty map validates to an empty map" do
      assert {:ok, %{}} = Gate.validate_quota_config(%{})
    end
  end

  describe "binding_side/2" do
    test "the account binds when it is stricter than the workspace" do
      account = account!(%{"throttle_threshold" => 0.50})
      ws = workspace!(%{config: %{"quota" => %{"throttle_threshold" => 0.95}}})

      assert Gate.binding_side({account, ws}, :throttle_threshold) == :account
    end

    test "the workspace binds when it tightens the account" do
      account = account!(%{"throttle_threshold" => 0.90})
      ws = workspace!(%{config: %{"quota" => %{"throttle_threshold" => 0.50}}})

      assert Gate.binding_side({account, ws}, :throttle_threshold) == :workspace
    end

    test "the account binds when only it has a setting" do
      account = account!(%{"weekly_threshold" => 0.70})
      assert Gate.binding_side({account, workspace!()}, :weekly_threshold) == :account
    end

    test "the workspace binds when only it has a setting" do
      ws = workspace!(%{config: %{"quota" => %{"weekly_threshold" => 0.70}}})
      assert Gate.binding_side({nil, ws}, :weekly_threshold) == :workspace
    end

    test "neither side configured anything — the default applies" do
      assert Gate.binding_side({account!(), workspace!()}, :throttle_threshold) == :default
    end

    # bd-5ps98m: an account left at the default `quota_config: {}` with the
    # flag on binds every workspace at the global 0.90 weekly threshold —
    # this is what made that silent.
    test "an equal account/workspace value reads as the account binding" do
      account = account!(%{"weekly_threshold" => 0.90})
      ws = workspace!(%{config: %{"quota" => %{"weekly_threshold" => 0.90}}})

      assert Gate.binding_side({account, ws}, :weekly_threshold) == :account
    end

    # bd-c7ll4t (review finding 2): a paced side's flat key is not what the
    # real gate holds on — comparing raw keys can name the wrong side.
    test "a paced account binds against a flat workspace when the elapsed ceiling is tighter" do
      account = account!(%{"threshold_mode" => "paced"})
      ws = workspace!(%{config: %{"quota" => %{"weekly_threshold" => 0.95}}})

      assert Gate.binding_side({account, ws}, :weekly_threshold, elapsed: 0.5) == :account
    end

    test "with the elapsed fraction unknown, a paced side with no flat setting drops out" do
      account = account!(%{"threshold_mode" => "paced"})
      ws = workspace!(%{config: %{"quota" => %{"weekly_threshold" => 0.95}}})

      assert Gate.binding_side({account, ws}, :weekly_threshold) == :workspace
    end

    test "a paced side ignores its own stale flat key once the elapsed ceiling is known" do
      account =
        account!(%{"threshold_mode" => "paced", "weekly_threshold" => 0.5})

      ws =
        workspace!(%{
          config: %{"quota" => %{"threshold_mode" => "paced", "weekly_paced_floor" => 0.1}}
        })

      # Both sides are paced; at this elapsed the workspace's tighter floor
      # binds. The account's stale `weekly_threshold: 0.5` plays no part —
      # comparing it against nothing would have wrongly named `:account`.
      assert Gate.binding_side({account, ws}, :weekly_threshold, elapsed: 0.05) == :workspace
    end
  end

  describe "effective_threshold/3" do
    test "resolves a paced account's ceiling to max(floor, elapsed), not its stale flat key" do
      account = account!(%{"threshold_mode" => "paced", "weekly_threshold" => 0.5})

      assert Gate.effective_threshold({account, nil}, :weekly_threshold, elapsed: 0.6) == 0.6
      assert Gate.effective_threshold({account, nil}, :weekly_threshold, elapsed: 0.05) == 0.20
    end

    test "falls back to the global default when neither side configured anything" do
      assert Gate.effective_threshold({account!(), workspace!()}, :throttle_threshold) == 0.85
    end
  end

  describe "account_policy_summary/1" do
    test "reports the flat mode and thresholds with no workspace in play" do
      account =
        account!(%{
          "throttle_threshold" => 0.80,
          "weekly_threshold" => 0.92
        })

      assert Gate.account_policy_summary(account) == %{
               threshold_mode: "flat",
               throttle_threshold: 0.80,
               weekly_threshold: 0.92,
               paced_floor: 0.35,
               weekly_paced_floor: 0.20
             }
    end

    test "reports paced mode and its floors, and nils the flat keys it ignores" do
      account =
        account!(%{
          "threshold_mode" => "paced",
          # Stale — a paced side never reads its own flat key, so reporting
          # it as though it still applied would repeat bd-5ps98m's mistake.
          "weekly_threshold" => 0.5,
          "paced_floor" => 0.4,
          "weekly_paced_floor" => 0.25
        })

      summary = Gate.account_policy_summary(account)
      assert summary.threshold_mode == "paced"
      assert summary.paced_floor == 0.4
      assert summary.weekly_paced_floor == 0.25
      assert summary.throttle_threshold == nil
      assert summary.weekly_threshold == nil
    end

    test "a nil account reports the built-in defaults" do
      summary = Gate.account_policy_summary(nil)
      assert summary.threshold_mode == "flat"
      assert summary.throttle_threshold == 0.85
      assert summary.weekly_threshold == 0.90
    end
  end
end
