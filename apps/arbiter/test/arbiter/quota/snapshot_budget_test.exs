defmodule Arbiter.Quota.SnapshotBudgetTest do
  @moduledoc """
  DC5 (bd-2c2a4g; `docs/design/provider-dynamic-concurrency.md` §9):
  `quota_get` and `GET /api/quota` gain a `budget` block per account, built by
  `Arbiter.Board.CapacityView.account_blocks/2` and labelled with the
  `scheduler_admission` mode. Both surfaces call `Arbiter.Quota.Snapshot`, so
  one test of the builder covers the wire shape of both; the MCP and REST
  tests below pin that they hand it through.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Quota.Snapshot
  alias Arbiter.Tasks.Workspace

  setup do
    on_exit(fn -> Arbiter.Settings.set_scheduler_admission(nil) end)

    n = System.unique_integer([:positive])
    ws = Ash.create!(Workspace, %{name: "qb-#{n}", prefix: "qb#{n}"})
    account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "qb-#{n}"})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    %{ws: ws, account: account}
  end

  test "for_workspace carries one budget block per metered account", ctx do
    assert %{budget: blocks} = Snapshot.for_workspace(ctx.ws.id)
    assert is_list(blocks)

    assert %{account: name, account_id: id, mode: "legacy", decides: false, pools: pools} =
             Enum.find(blocks, &(&1.account_id == ctx.account.id))

    assert name == "claude:#{ctx.account.slug}"
    assert id == ctx.account.id
    assert is_list(pools)
  end

  test "the block is labelled with the admission mode", ctx do
    {:ok, _} = Arbiter.Settings.set_scheduler_admission("shadow")

    assert %{budget: blocks} = Snapshot.for_workspace(ctx.ws.id)
    assert Enum.all?(blocks, &(&1.mode == "shadow" and &1.decides == false))

    {:ok, _} = Arbiter.Settings.set_scheduler_admission("enforce")
    assert %{budget: blocks} = Snapshot.for_workspace(ctx.ws.id)
    assert Enum.all?(blocks, &(&1.mode == "enforce" and &1.decides == true))
  end

  test "for_account carries that one account's block", ctx do
    assert %{budget: [%{account_id: id, account: name}]} = Snapshot.for_account(ctx.account)
    assert id == ctx.account.id
    assert name == "claude:#{ctx.account.slug}"
  end

  test "a budget read that fails leaves the quota payload intact", ctx do
    :ok = :meck.new(Arbiter.Board.CapacityView, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Arbiter.Board.CapacityView) end)
    :meck.expect(Arbiter.Board.CapacityView, :account_blocks, fn _ids -> raise "boom" end)

    assert %{budget: [], quotas: quotas} = Snapshot.for_workspace(ctx.ws.id)
    assert is_list(quotas)
  end

  describe "published pools ride the block" do
    setup do
      :ok = :meck.new(Arbiter.Board.CapacityView, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Arbiter.Board.CapacityView) end)

      block = %{
        account: "claude:default",
        account_id: "acct-1",
        mode: "shadow",
        decides: false,
        pools: [%{pool: "claude", budget: 3, seats: 3, reason: "ceiling max_concurrent 3"}]
      }

      :meck.expect(Arbiter.Board.CapacityView, :account_blocks, fn _ids -> [block] end)
      %{block: block}
    end

    test "quota_get (MCP) returns the block under `budget`", ctx do
      scope = %Scope{tier: :coordinator, workspace_id: ctx.ws.id}

      assert {:ok, %{budget: [block]}} = Tools.quota_get(scope, %{})
      assert block.mode == "shadow"
      assert [%{pool: "claude", budget: 3}] = block.pools
    end

    test "quota_get with an account returns that account's block", ctx do
      scope = %Scope{tier: :coordinator, workspace_id: ctx.ws.id}
      ref = "claude:#{ctx.account.slug}"

      assert {:ok, %{budget: [%{pools: [%{reason: "ceiling max_concurrent 3"}]}]}} =
               Tools.quota_get(scope, %{"account" => ref})
    end
  end
end
