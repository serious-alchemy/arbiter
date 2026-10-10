defmodule Arbiter.Board.SnapshotLoadWalkTest do
  @moduledoc """
  `Snapshot.load/1`'s `:admission` (DC6): `legacy` (the default) gathers
  nothing for the walk and the board carries none; `shadow` and `enforce`
  gather the walk's inputs (`Arbiter.Board.WalkInputs`) and the board carries
  the walk beside today's plan, which is the same either way.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Board.Snapshot
  alias Arbiter.Quota.Budget
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    ws =
      Ash.create!(Workspace, %{
        name: "load-walk-#{System.unique_integer([:positive])}",
        prefix: "lw#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "lw-#{System.unique_integer([:positive])}",
        max_concurrent: 3
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    created =
      Ash.create!(Issue, %{title: "ready", workspace_id: ws.id, acceptance: "- walk fixture"})

    ready = Ash.update!(created, %{}, action: :promote_to_ready)

    walk_opts = [
      budgets: [
        %Budget{
          account: account.id,
          pool: "claude",
          budget: 2,
          binding: {:window, "5h"},
          reason: "5h"
        }
      ],
      seats: %{},
      local: %{cap: 6, used: 0},
      remote_available?: false
    ]

    %{ws: ws, account: account, ready: ready, walk_opts: walk_opts}
  end

  test "legacy, by default or by name, carries no walk", %{ws: ws, walk_opts: walk_opts} do
    refute Map.has_key?(Snapshot.load(workspace_id: ws.id, walk_opts: walk_opts), :walk)

    refute Map.has_key?(
             Snapshot.load(workspace_id: ws.id, admission: :legacy, walk_opts: walk_opts),
             :walk
           )
  end

  for mode <- [:shadow, :enforce] do
    test "#{mode} carries the walk beside today's unchanged plan", ctx do
      %{ws: ws, account: account, ready: ready, walk_opts: walk_opts} = ctx
      now = DateTime.utc_now()

      today = Snapshot.load(workspace_id: ws.id, now: now, walk_opts: walk_opts)

      board =
        Snapshot.load(
          workspace_id: ws.id,
          now: now,
          admission: unquote(mode),
          walk_opts: walk_opts
        )

      assert Map.delete(board, :walk) == today
      assert today.promote == ready.id

      assert %{promote: promote, placements: [%{pool: pool, node: "local"}]} = board.walk
      assert promote == ready.id
      assert pool == {account.id, "claude"}
      assert board.walk.pools[{account.id, "claude"}].budget == 2
    end
  end

  @tag capture_log: true
  test "a walk whose inputs cannot be read leaves the board without one", ctx do
    board =
      Snapshot.load(
        workspace_id: ctx.ws.id,
        admission: :shadow,
        walk_opts: Keyword.put(ctx.walk_opts, :budgets, :not_a_list)
      )

    refute Map.has_key?(board, :walk)
    assert board.promote == ctx.ready.id
  end

  @tag capture_log: true
  test "a walk input read that exits leaves the board without one", ctx do
    # The node overview, read only for the walk, exiting as a dead process would.
    exiting = Stream.map([:row], fn _ -> exit(:node_overview_down) end)

    board =
      Snapshot.load(
        workspace_id: ctx.ws.id,
        admission: :shadow,
        walk_opts: Keyword.merge(ctx.walk_opts, remote_available?: true, nodes: exiting)
      )

    refute Map.has_key?(board, :walk)
    assert board.promote == ctx.ready.id
  end
end
