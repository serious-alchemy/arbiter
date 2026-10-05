defmodule Arbiter.Agents.ProviderRoutingPaceExemptTest do
  @moduledoc """
  The P0 pace exemption through the router (bd-6bxv7h, design §4.2): the
  candidate's quota gate and headroom read the task's own priority, and the
  chosen decision records `pace_exempt: {window, used, paced, cap}` when the
  exemption is what let it through. Off, or for a priority that is not exempt,
  routing is exactly what it was (design §9).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.{Issue, Workspace}

  @most_quota %{"routing" => %{"provider_selection" => "most_quota"}}

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  defp workspace!(config \\ @most_quota) do
    Ash.create!(Workspace, %{name: "pe-#{System.unique_integer([:positive])}", config: config})
  end

  defp account!(provider, slug, quota_config) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      quota_config: quota_config
    })
  end

  defp allow!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: position
    })
  end

  defp task!(ws, priority),
    do: Ash.create!(Issue, %{title: "route me", workspace_id: ws.id, priority: priority})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  # 5h window reset 4.9h out: elapsed ≈ 0.02, so a paced account's line is the
  # 0.35 floor.
  defp quota(u5) do
    %AnthropicQuota{
      provider: "claude",
      utilization_5h: u5,
      reset_5h_at: ahead(17_640),
      status_5h: "allowed",
      utilization_7d: 0.0,
      reset_7d_at: ahead(302_400),
      status_7d: "allowed",
      captured_at: now()
    }
  end

  defp opts(pairs) do
    by_id = Map.new(pairs, fn {account, q} -> {account.id, q} end)
    [quota_fun: fn account -> Map.get(by_id, account.id) end, gemini_code: nil]
  end

  defp paced(extra \\ %{}), do: Map.merge(%{"threshold_mode" => "paced"}, extra)
  defp exempt(extra \\ %{}), do: paced(Map.merge(%{"pace_exempt_priority" => 0}, extra))

  # Two decisions, minus the clock.
  defp same_decision?(a, b), do: Map.delete(a, "evaluated_at") == Map.delete(b, "evaluated_at")

  defp route(ws, task, pairs) do
    ProviderRouting.select(ws, task, :main, opts(pairs) ++ [pin: false])
  end

  test "an exempt P0 is routed past the paced line, and the decision records it" do
    ws = workspace!()
    acct = account!(:claude, "p0", exempt(%{"pace_exempt_threshold" => 0.8}))
    allow!(ws, acct, 0)

    assert {:ok, %{decision: decision}} = route(ws, task!(ws, 0), [{acct, quota(0.4)}])

    assert decision["outcome"] == "selected"
    assert decision["account_id"] == acct.id

    assert %{"window" => "5h", "used" => 0.4, "paced" => paced, "cap" => 0.8} =
             decision["pace_exempt"]

    assert_in_delta paced, 0.35, 0.01
    # Headroom is against the lifted line: cap − used.
    assert_in_delta decision["headroom"], 0.4, 0.001
  end

  test "a P2 on the same account is held at the paced line (not exempt)" do
    ws = workspace!()
    acct = account!(:claude, "p2", exempt(%{"pace_exempt_threshold" => 0.8}))
    allow!(ws, acct, 0)

    assert {:legacy, decision} = route(ws, task!(ws, 2), [{acct, quota(0.4)}])
    assert Enum.any?(decision["dropped"], &(&1["reason"] == "quota_held"))
    refute Map.has_key?(decision, "pace_exempt")
  end

  test "an exempt P0 past the dedicated cap is still held" do
    ws = workspace!()
    acct = account!(:claude, "cap", exempt(%{"pace_exempt_threshold" => 0.8}))
    allow!(ws, acct, 0)

    assert {:legacy, decision} = route(ws, task!(ws, 0), [{acct, quota(0.8)}])

    assert [%{"reason" => "quota_held", "detail" => detail}] = decision["dropped"]
    assert detail =~ "P0 exempt"
  end

  test "an exempt P0 under the paced line records no exemption" do
    ws = workspace!()
    acct = account!(:claude, "under", exempt())
    allow!(ws, acct, 0)

    assert {:ok, %{decision: decision}} = route(ws, task!(ws, 0), [{acct, quota(0.2)}])
    refute Map.has_key?(decision, "pace_exempt")
  end

  describe "no regression (design §9)" do
    test "with no pace_exempt_priority a P0 routes exactly as a P2 does" do
      ws = workspace!()
      a = account!(:claude, "off-a", paced())
      b = account!(:codex, "off-b", %{})
      allow!(ws, a, 0)
      allow!(ws, b, 1)

      pairs = [{a, quota(0.2)}, {b, nil}]
      assert {:ok, %{decision: p0}} = route(ws, task!(ws, 0), pairs)
      assert {:ok, %{decision: p2}} = route(ws, task!(ws, 2), pairs)

      refute Map.has_key?(p0, "pace_exempt")
      assert same_decision?(p0, p2)
    end

    test "off, a P0 over the paced line is dropped exactly as before" do
      ws = workspace!()
      acct = account!(:claude, "off", paced(%{"pace_exempt_threshold" => 0.8}))
      allow!(ws, acct, 0)

      assert {:legacy, p0} = route(ws, task!(ws, 0), [{acct, quota(0.4)}])
      assert {:legacy, p2} = route(ws, task!(ws, 2), [{acct, quota(0.4)}])
      assert same_decision?(p0, p2)
    end

    test "with one eligible account the pick is the same exempt or not (only the headroom reading moves)" do
      ws = workspace!()
      acct = account!(:claude, "solo", exempt())
      allow!(ws, acct, 0)

      assert {:ok, %{decision: p0}} = route(ws, task!(ws, 0), [{acct, quota(0.1)}])
      assert {:ok, %{decision: p3}} = route(ws, task!(ws, 3), [{acct, quota(0.1)}])
      pick = &Map.take(&1, ["outcome", "account_id", "agent_type", "provider"])
      assert pick.(p0) == pick.(p3)
      refute Map.has_key?(p0, "pace_exempt")
    end

    test "a workspace that tightens to none switches the exemption off" do
      ws = workspace!(Map.put(@most_quota, "quota", %{"pace_exempt_priority" => "none"}))
      acct = account!(:claude, "none", exempt())
      allow!(ws, acct, 0)

      assert {:legacy, _decision} = route(ws, task!(ws, 0), [{acct, quota(0.4)}])
    end
  end
end
