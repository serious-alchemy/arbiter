defmodule Arbiter.Accounts.SerializerSpendCapTest do
  @moduledoc """
  `arb account show` / REST `GET /api/accounts/:ref` / MCP `account_show` carry
  the dollar spend cap with the current metered spend for its window (bd-a6grlr).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Serializer
  alias Arbiter.Usage.Event

  defp account!(config) do
    Ash.create!(ProviderAccount, %{
      provider: :claude,
      slug: "ser-#{System.unique_integer([:positive])}",
      quota_config: config
    })
  end

  test "the detailed form shows the cap, its window and the metered spend so far" do
    account = account!(%{"spend_cap" => 20.0, "spend_mode" => "paced", "spend_metered" => true})

    Ash.create!(Event, %{
      task_id: "bd-ser-1",
      source: :task,
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      cost_usd: 4.5,
      occurred_at: DateTime.utc_now()
    })

    assert %{spend_cap: cap} = Serializer.data(account, detailed?: true)
    assert cap["cap_usd"] == 20.0
    assert cap["window"] == "week"
    assert cap["mode"] == "paced"
    assert cap["metered"] == true
    assert cap["spent_usd"] == 4.5
    assert is_binary(cap["resets_at"])
  end

  test "a cap on a non-metered account says there is no metered spend" do
    account = account!(%{"spend_cap" => 20.0, "spend_metered" => false})
    assert %{spend_cap: %{"state" => "no_metered_spend", "metered" => false}} =
             Serializer.data(account, detailed?: true)
  end

  test "no cap: nil, and the list form never reads the ledger" do
    account = account!(%{})
    assert %{spend_cap: nil} = Serializer.data(account, detailed?: true)
    refute Map.has_key?(Serializer.data(account), :spend_cap)
  end
end
