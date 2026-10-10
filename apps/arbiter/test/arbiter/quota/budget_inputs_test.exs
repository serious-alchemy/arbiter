defmodule Arbiter.Quota.Budget.InputsTest do
  @moduledoc """
  DC3 (bd-6c8g4t): the live reads behind `Budget.Server` -- accounts, pools,
  policy variants, seats and the calibration index (design §3.1-§3.6).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Inputs
  alias Arbiter.Tasks.Workspace

  defp account!(provider, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(%{provider: provider, slug: "dc3-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp workspace!(config) do
    Ash.create!(Workspace, %{name: "dc3-#{System.unique_integer([:positive])}", config: config})
  end

  defp link!(ws, account, attrs \\ %{}) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  defp for_account(inputs, account), do: Enum.filter(inputs, &(&1.account_id == account.id))

  describe "gather/1" do
    test "one input per pool; agy has two, each with a model that picks its bucket group" do
      claude = account!(:claude, %{max_concurrent: 3})
      agy = account!(:antigravity)

      inputs = Inputs.gather()

      assert [%{pool: "claude", model: nil, policy_workspace: nil, seats: 0}] =
               for_account(inputs, claude)

      assert agy_inputs = for_account(inputs, agy)

      assert agy_inputs |> Enum.map(& &1.pool) |> Enum.sort() == [
               "antigravity:claude_and_gpt_models",
               "antigravity:gemini_models"
             ]

      assert Enum.all?(agy_inputs, &is_binary(&1.model))
    end

    test "a linked workspace that sets its own quota policy is a variant, with its share" do
      claude = account!(:claude)
      plain = workspace!(%{})
      strict = workspace!(%{"quota" => %{"throttle_threshold" => 0.5}})
      link!(plain, claude)
      link!(strict, claude, %{share: 2})

      variants =
        Inputs.gather() |> for_account(claude) |> Enum.sort_by(&(&1.policy_workspace || ""))

      assert [%{policy_workspace: nil, share: nil}, %{policy_workspace: ws_id, share: 2}] =
               variants

      assert ws_id == strict.id
    end

    test "disabled accounts are not budgeted" do
      account = account!(:claude)
      Ash.update!(account, %{enabled: false}, action: :update)
      assert Inputs.gather() |> for_account(account) == []
    end

    test "every input feeds Budget.compute/1 without a quota row: no reading, never a crash" do
      account = account!(:claude, %{max_concurrent: 3})

      [input] = Inputs.gather() |> for_account(account)
      budget = Budget.compute(input)

      assert budget.binding in [:no_reading, :unavailable]
      assert is_integer(budget.budget)
      assert budget.budget <= 3
    end
  end

  describe "the server over the live inputs" do
    test "publishes a budget for every account in the database" do
      account = account!(:claude, %{max_concurrent: 3})

      start_supervised!(
        {Budget.Server,
         name: :budget_inputs_server,
         table: :budget_inputs_table,
         enabled: true,
         tick_ms: :never,
         calibration: :never}
      )

      assert :ok = Budget.Server.recompute(:budget_inputs_server)

      assert %Budget{account: id, pool: "claude", reason: reason} =
               Budget.Server.get(account.id, "claude", nil, :budget_inputs_table)

      assert id == account.id
      assert is_binary(reason) and reason != ""
    end
  end

  describe "index_calibration/1" do
    @resolution %{rung: 2, rho: 0.0667, raw_rho: 0.0667, floored?: false, passed_over: []}

    test "keys the ladder's rho by account, pool and window; H by pool" do
      results = [
        Map.merge(@resolution, %{
          account_id: "a",
          pool: "claude",
          window: "5h",
          horizon_hours: 3.0,
          fit: %{}
        })
      ]

      index = Inputs.index_calibration(results)
      assert index.rates[{"a", "claude", "5h"}].rho == 0.0667
      assert index.horizons == %{"claude" => 3.0}
      # a degenerate (rung 2) fit's background is not trusted
      assert index.background == %{}
    end

    test "background comes only from a fit that measured a seat (rung 0)" do
      results = [
        Map.merge(@resolution, %{
          rung: 0,
          account_id: "a",
          pool: "claude",
          window: "5h",
          horizon_hours: 2.0,
          fit: %{background_share_per_hour: 0.004}
        })
      ]

      assert Inputs.index_calibration(results).background[{"a", "claude", "5h"}] == 0.004
    end

    test "a window with no length has no rung and contributes nothing but H" do
      results = [
        %{account_id: "a", pool: "codex", window: "x", horizon_hours: 2.0, rung: nil, fit: %{}}
      ]

      index = Inputs.index_calibration(results)
      assert index.rates == %{}
    end
  end
end
