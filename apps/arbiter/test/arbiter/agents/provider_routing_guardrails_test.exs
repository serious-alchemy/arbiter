defmodule Arbiter.Agents.ProviderRoutingGuardrailsTest do
  @moduledoc """
  bd-atll60 (G13): `check_guardrails` in `ProviderRouting.check/2` — guardrail
  eligibility is a hard filter that runs before any optimisation, and drops a
  candidate with `guardrail_ineligible` however much headroom it has
  (`docs/design/guardrail-profiles.md` §5.4, §8).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Quota.{AnthropicQuota, GoogleQuota}
  alias Arbiter.Tasks.{Issue, Workspace}

  @most_quota %{"routing" => %{"provider_selection" => "most_quota"}}

  @rules [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "antigravity"}, tier: :quarantine}
  ]

  setup do
    on_exit(fn ->
      Application.delete_env(:arbiter, :guardrail_subject_rules)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    :ok
  end

  defp guard!(rules \\ @rules),
    do: Application.put_env(:arbiter, :guardrail_subject_rules, rules)

  defp workspace!(config \\ @most_quota) do
    Ash.create!(Workspace, %{name: "gr-#{System.unique_integer([:positive])}", config: config})
  end

  defp account!(provider, slug) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "#{slug}-#{System.unique_integer([:positive])}"
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

  defp task!(ws, attrs),
    do: Ash.create!(Issue, Map.merge(%{title: "route me", workspace_id: ws.id}, attrs))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp claude_quota(u5) do
    %AnthropicQuota{
      provider: "claude",
      utilization_5h: u5,
      reset_5h_at: ahead(9_000),
      status_5h: "allowed",
      utilization_7d: 0.0,
      reset_7d_at: ahead(302_400),
      status_7d: "allowed",
      captured_at: now()
    }
  end

  defp agy_quota(used) do
    bucket = fn group, window, used, reset ->
      %{
        "model_id" => "#{group}_#{window}",
        "remaining_percentage" => 100.0 - used,
        "reset_at" => DateTime.to_iso8601(reset)
      }
    end

    %GoogleQuota{
      provider: "antigravity",
      captured_at: now(),
      reset_at: ahead(9_000),
      snapshot: %{
        "models" => [
          bucket.("gemini_models", "5h", used, ahead(9_000)),
          bucket.("gemini_models", "weekly", 0.0, ahead(302_400)),
          bucket.("claude_and_gpt_models", "5h", used, ahead(9_000)),
          bucket.("claude_and_gpt_models", "weekly", 0.0, ahead(302_400))
        ]
      }
    }
  end

  defp opts(pairs, extra \\ []) do
    by_id = Map.new(pairs, fn {account, quota} -> {account.id, quota} end)

    Keyword.merge(
      [
        quota_fun: fn account -> Map.get(by_id, account.id) end,
        gemini_code: "antigravity",
        write_confinement: fn _adapter, _policy -> :os_jail end,
        egress_confinement: fn _adapter, _policy -> :os_jail end
      ],
      extra
    )
  end

  # agy has far more headroom than claude, so on quota alone it always wins.
  defp fleet! do
    ws = workspace!()
    claude = account!(:claude, "claude")
    agy = account!(:antigravity, "agy")
    allow!(ws, claude, 0)
    allow!(ws, agy, 1)

    %{
      ws: ws,
      claude: claude,
      agy: agy,
      quotas: [{claude, claude_quota(0.7)}, {agy, agy_quota(0.0)}]
    }
  end

  defp reasons(decision), do: Map.new(decision["dropped"], &{&1["account_slug"], &1["reason"]})

  test "unguarded (no subject rule) the headroom pick is untouched" do
    %{ws: ws, agy: agy, quotas: quotas} = fleet!()
    task = task!(ws, %{difficulty: 3})

    assert {:ok, %{agent_type: :gemini, decision: decision}} =
             ProviderRouting.select(ws, task, :main, opts(quotas))

    assert decision["account_slug"] == agy.slug
    assert decision["dropped"] == []
  end

  test "a candidate above its tier's difficulty ceiling is dropped as guardrail_ineligible" do
    guard!()
    %{ws: ws, claude: claude, agy: agy, quotas: quotas} = fleet!()
    task = task!(ws, %{difficulty: 3})

    assert {:ok, %{agent_type: :claude, decision: decision}} =
             ProviderRouting.select(ws, task, :main, opts(quotas))

    assert decision["account_slug"] == claude.slug
    assert reasons(decision)[agy.slug] == "guardrail_ineligible"

    [dropped] = decision["dropped"]
    assert dropped["detail"] =~ "D3"
    assert dropped["detail"] =~ "quarantine"
  end

  test "an eligible low-tier candidate still competes on headroom" do
    guard!()
    %{ws: ws, agy: agy, quotas: quotas} = fleet!()
    task = task!(ws, %{difficulty: 1})

    assert {:ok, %{decision: decision}} = ProviderRouting.select(ws, task, :main, opts(quotas))
    assert decision["account_slug"] == agy.slug
    assert decision["dropped"] == []
  end

  test "with every candidate ineligible there is no routed pick" do
    guard!([%{match: %{provider: "claude"}, tier: :quarantine}] ++ @rules)
    %{ws: ws, claude: claude, agy: agy, quotas: quotas} = fleet!()
    task = task!(ws, %{difficulty: 3})

    assert {:legacy, decision} = ProviderRouting.select(ws, task, :main, opts(quotas))
    assert decision["outcome"] == "no_candidate"
    assert reasons(decision)[claude.slug] == "guardrail_ineligible"
    assert reasons(decision)[agy.slug] == "guardrail_ineligible"
  end

  test "a tier whose floor the adapter cannot meet is dropped, not run with a weaker posture" do
    guard!()
    %{ws: ws, agy: agy, quotas: quotas} = fleet!()
    task = task!(ws, %{difficulty: 1})

    # Quarantine floors the scope to :strict; this agy cannot confine writes.
    options = opts(quotas, write_confinement: fn _adapter, _policy -> :none end)

    assert {:ok, %{decision: decision}} = ProviderRouting.select(ws, task, :main, options)
    assert reasons(decision)[agy.slug] == "write_confinement_none"
    assert decision["account_slug"] != agy.slug
  end

  test "the same adapter is not dropped for confinement when no rule floors it" do
    %{ws: ws, agy: agy, quotas: quotas} = fleet!()
    task = task!(ws, %{difficulty: 1})
    options = opts(quotas, write_confinement: fn _adapter, _policy -> :none end)

    assert {:ok, %{decision: decision}} = ProviderRouting.select(ws, task, :main, options)
    assert decision["account_slug"] == agy.slug
  end

  test "a ticket's in-force data class limits the candidates" do
    guard!(@rules)
    Application.put_env(:arbiter, :guardrail_data_agreements, %{"phi_data" => []})
    on_exit(fn -> Application.delete_env(:arbiter, :guardrail_data_agreements) end)

    %{ws: ws, claude: claude, agy: agy, quotas: quotas} = fleet!()

    task =
      Ash.create!(
        Issue,
        %{title: "phi", workspace_id: ws.id, difficulty: 1, permissions: ["phi_data"]},
        context: %{guardrail_authority: :coordinator, permission_actor: "t"}
      )

    assert {:legacy, decision} = ProviderRouting.select(ws, task, :main, opts(quotas))
    assert reasons(decision)[agy.slug] == "guardrail_ineligible"
    assert reasons(decision)[claude.slug] == "guardrail_ineligible"

    Application.put_env(:arbiter, :guardrail_data_agreements, %{
      "phi_data" => ["claude:#{String.replace_prefix(claude.slug, "", "")}"]
    })

    assert {:ok, %{decision: ok}} = ProviderRouting.select(ws, task, :main, opts(quotas))
    assert ok["account_slug"] == claude.slug
  end

  test "a tier whose egress ceiling the adapter cannot enforce is dropped" do
    guard!()
    %{ws: ws, agy: agy, quotas: quotas} = fleet!()
    task = task!(ws, %{difficulty: 1})

    options = opts(quotas, egress_confinement: fn _adapter, _policy -> :none end)

    assert {:ok, %{decision: decision}} = ProviderRouting.select(ws, task, :main, options)
    assert reasons(decision)[agy.slug] == "egress_unenforceable"
  end
end
