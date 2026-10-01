defmodule Arbiter.Board.SnapshotMostQuotaTest do
  @moduledoc """
  bd-3fvue3: under `routing.provider_selection: most_quota` the board's
  Autopilot hold and slot arithmetic ask `Arbiter.Agents.ProviderRouting` who
  can take a ticket, not the workspace's default provider alone.

    * the workspace is held only when no implementer candidate is available;
    * `slots_total` folds in the **sum** of the available candidates' account
      headroom, capped by the workspace and system caps;
    * a failover workspace is exactly what it was.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Board.Snapshot
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota}
  alias Arbiter.Tasks.Workspace

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    put_app_env(:arbiter, :conductor_system_max_concurrent, 3)
    :ok
  end

  # ---- fixtures -------------------------------------------------------------

  # `agent.type` lists Claude first, so Claude is the workspace's default
  # provider — the one the pre-fix hold and cap were computed from.
  defp workspace!(routing) do
    Ash.create!(Workspace, %{
      name: "smq-#{System.unique_integer([:positive])}",
      prefix: "smq#{System.unique_integer([:positive])}",
      config: %{"agent" => %{"type" => ["claude", "codex"]}, "routing" => routing}
    })
  end

  defp most_quota!, do: workspace!(%{"provider_selection" => "most_quota"})

  defp account!(provider, attrs) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{provider}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp allow!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: position
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp claude_used!(account, u5) do
    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: u5,
      reset_5h_at: ahead(9_000),
      status_5h: "allowed",
      utilization_7d: 0.0,
      reset_7d_at: ahead(302_400),
      status_7d: "allowed",
      captured_at: now()
    })
  end

  defp codex_used!(account, pct) do
    Ash.create!(CodexQuota, %{
      provider_account_id: account.id,
      provider: "codex",
      session_used_percent: pct,
      session_reset_at: ahead(3_600),
      weekly_used_percent: 0.0,
      weekly_reset_at: ahead(302_400),
      limit_reached: false,
      captured_at: now()
    })
  end

  # A live dispatch counted against `provider` for `ws`.
  defp live_worker!(ws, provider) do
    key = "smq-worker-#{System.unique_integer([:positive])}"
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Arbiter.Worker.Registry, key, nil)
        :ok = Arbiter.Worker.Registry.put_dispatch(key, ws.id, provider)
        send(test, {:registered, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # Claude is the default provider and is paced out of a dispatch (its 5h
  # window is over the account's own 0.5 ceiling); Codex has room.
  defp claude_held_codex_free!(ws, claude_attrs \\ %{}, codex_attrs \\ %{}) do
    claude =
      account!(:claude, Map.merge(%{quota_config: %{"throttle_threshold" => 0.5}}, claude_attrs))

    codex = account!(:codex, codex_attrs)
    allow!(ws, claude, 0)
    allow!(ws, codex, 1)
    claude_used!(claude, 0.70)
    codex_used!(codex, 10.0)
    %{claude: claude, codex: codex}
  end

  defp claude_slug(ws) do
    ws.id
    |> then(
      &(Ash.read!(WorkspaceProviderAccount, authorize?: false)
        |> Enum.filter(fn w -> w.workspace_id == &1 and w.provider == :claude end))
    )
    |> hd()
    |> Map.fetch!(:provider_account_id)
    |> then(&Ash.get!(ProviderAccount, &1).slug)
  end

  # ---- the hold -------------------------------------------------------------

  describe "quota_hold/2" do
    test "is :ok while another candidate is available though the default provider is held" do
      ws = most_quota!()
      claude_held_codex_free!(ws)

      assert Snapshot.quota_hold(ws.id) == :ok
    end

    test "holds when every implementer candidate is quota-held" do
      ws = most_quota!()
      %{codex: codex} = claude_held_codex_free!(ws)
      Ash.update!(codex, %{quota_config: %{"throttle_threshold" => 0.5}})
      codex_used!(codex, 60.0)

      assert {:hold, reason} = Snapshot.quota_hold(ws.id)
      # Every held account is named, not just the default provider's.
      assert reason =~ "claude:#{claude_slug(ws)}"
      assert reason =~ "codex:#{codex.slug}"
    end

    test "holds when the only available-looking candidate is out of capacity and the rest are held" do
      ws = most_quota!()
      %{codex: codex} = claude_held_codex_free!(ws, %{}, %{max_concurrent: 1})
      live_worker!(ws, "codex")

      assert codex.max_concurrent == 1
      assert {:hold, _reason} = Snapshot.quota_hold(ws.id)
    end

    test "a mixed drop names every dropped candidate: the held account and why the other can't help" do
      ws = most_quota!()
      %{codex: codex} = claude_held_codex_free!(ws, %{}, %{max_concurrent: 1})
      live_worker!(ws, "codex")

      assert {:hold, reason} = Snapshot.quota_hold(ws.id)
      assert reason =~ "claude:#{claude_slug(ws)}"
      assert reason =~ "codex:#{codex.slug} at capacity"
    end

    test "a failover workspace is held by its default provider exactly as before" do
      ws = workspace!(%{})
      claude_held_codex_free!(ws)

      assert {:hold, _reason} = Snapshot.quota_hold(ws.id)
    end

    test "a most_quota workspace with no implementer attachment keeps the default-provider hold" do
      ws = most_quota!()
      claude = account!(:claude, %{quota_config: %{"throttle_threshold" => 0.5}})

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: claude.id
      })

      claude_used!(claude, 0.70)

      assert {:hold, _reason} = Snapshot.quota_hold(ws.id)
    end
  end

  # ---- the per-ticket hold (bd-1qjv3j) --------------------------------------

  describe "load/1 per-ticket holds" do
    defp ready_issue(id, ws) do
      now = now()

      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: ws.id,
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: now,
        updated_at: now,
        closed_at: nil
      }
    end

    defp load_ready(ws, ids) do
      board =
        Snapshot.load(
          workspace_id: ws.id,
          issues: Enum.map(ids, &ready_issue(&1, ws)),
          workers: [],
          slots_total: 3
        )

      Map.new(board.ready, &{&1.card.id, &1})
    end

    test "a Ready ticket whose pool has an account with headroom is not shown as held" do
      ws = most_quota!()
      claude_held_codex_free!(ws)

      assert %{"t-1" => %{state: :next, reason: reason}} = load_ready(ws, ["t-1"])
      refute reason =~ "quota"
    end

    test "every Ready ticket lists each held account when all candidates are held" do
      ws = most_quota!()
      %{codex: codex} = claude_held_codex_free!(ws)
      Ash.update!(codex, %{quota_config: %{"throttle_threshold" => 0.5}})
      codex_used!(codex, 60.0)

      ready = load_ready(ws, ["t-1", "t-2"])

      for {_id, %{state: :blocked, reason: reason}} <- ready do
        assert reason =~ "claude:#{claude_slug(ws)}"
        assert reason =~ "codex:#{codex.slug}"
      end

      assert map_size(ready) == 2
    end
  end

  # ---- the slots ------------------------------------------------------------

  describe "effective_max_concurrent/3" do
    test "sums the available candidates' headroom: claude 2 (1 used) + codex 2 (0 used), cap 3, 1 in use → 2 free" do
      ws = most_quota!()
      claude = account!(:claude, %{max_concurrent: 2})
      codex = account!(:codex, %{max_concurrent: 2})
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, 0.1)
      codex_used!(codex, 10.0)
      live_worker!(ws, "claude")

      in_use = 1
      total = Snapshot.effective_max_concurrent(ws.id, in_use)

      assert total == 3
      assert total - in_use == 2
    end

    test "counts only the available candidates: a held default provider adds nothing" do
      ws = most_quota!()
      %{} = claude_held_codex_free!(ws, %{max_concurrent: 2}, %{max_concurrent: 2})

      # Codex's two free slots, none of Claude's.
      assert Snapshot.effective_max_concurrent(ws.id, 0) == 2
    end

    test "is capped by the system cap" do
      ws = most_quota!()
      claude = account!(:claude, %{max_concurrent: 5})
      codex = account!(:codex, %{max_concurrent: 5})
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, 0.1)
      codex_used!(codex, 10.0)

      assert Snapshot.effective_max_concurrent(ws.id, 0) == 3
    end

    test "is capped by the workspace cap" do
      ws =
        Ash.create!(Workspace, %{
          name: "smq-cap-#{System.unique_integer([:positive])}",
          prefix: "smqc#{System.unique_integer([:positive])}",
          config: %{
            "agent" => %{"type" => ["claude", "codex"]},
            "routing" => %{"provider_selection" => "most_quota"},
            "conductor" => %{"max_concurrent" => 1}
          }
        })

      claude = account!(:claude, %{max_concurrent: 2})
      codex = account!(:codex, %{max_concurrent: 2})
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, 0.1)
      codex_used!(codex, 10.0)

      assert Snapshot.effective_max_concurrent(ws.id, 0) == 1
    end

    test "an unbounded available candidate leaves the workspace and system caps in charge" do
      ws = most_quota!()
      %{} = claude_held_codex_free!(ws, %{max_concurrent: 1})

      assert Snapshot.effective_max_concurrent(ws.id, 0) == 3
    end

    test "a failover workspace still sizes from the default provider's account alone" do
      ws = workspace!(%{})
      claude = account!(:claude, %{max_concurrent: 2})
      codex = account!(:codex, %{max_concurrent: 2})
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, 0.1)
      codex_used!(codex, 10.0)
      live_worker!(ws, "claude")

      # Claude 2 − 1 = 1 more, on top of the 1 already counted. Codex is invisible.
      assert Snapshot.effective_max_concurrent(ws.id, 1) == 2
    end

    test "with every candidate at capacity there are no slots beyond what is running" do
      ws = most_quota!()
      claude = account!(:claude, %{max_concurrent: 1})
      codex = account!(:codex, %{max_concurrent: 1})
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, 0.1)
      codex_used!(codex, 10.0)
      live_worker!(ws, "claude")
      live_worker!(ws, "codex")

      assert Snapshot.effective_max_concurrent(ws.id, 2) == 2
    end
  end

  describe "load/1" do
    test "carries the routed hold and slot count onto the board" do
      ws = most_quota!()
      %{} = claude_held_codex_free!(ws, %{}, %{max_concurrent: 2})

      board = Snapshot.load(workspace_id: ws.id, issues: [], workers: [])

      assert board.quota == :ok
      assert board.slots_total == 2
      assert board.slots_free == 2
    end

    test "a failover workspace's board still carries the default provider's hold" do
      ws = workspace!(%{})
      claude_held_codex_free!(ws)

      board = Snapshot.load(workspace_id: ws.id, issues: [], workers: [])

      assert {:hold, _reason} = board.quota
    end
  end
end
