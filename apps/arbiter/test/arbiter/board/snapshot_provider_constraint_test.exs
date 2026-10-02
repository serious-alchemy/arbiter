defmodule Arbiter.Board.SnapshotProviderConstraintTest do
  @moduledoc """
  bd-13pqcp: a Ready ticket whose provider constraint leaves no eligible
  account with capacity is held on the board with `held — provider constraint
  (<detail>)`, as its own block (it does not hold the queue behind it), so
  Autopilot plans past it. A ticket without a constraint, or with an eligible
  provider, is planned exactly as before.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Workspace

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  defp workspace!(config) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "spc-#{n}", prefix: "spc#{n}", config: config})
  end

  defp failover!(types \\ ["claude", "gemini"]),
    do: workspace!(%{"agent" => %{"type" => types}})

  defp most_quota!,
    do:
      workspace!(%{
        "agent" => %{"type" => ["claude", "codex"]},
        "routing" => %{"provider_selection" => "most_quota"}
      })

  defp account!(provider, attrs \\ %{}) do
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

  defp issue(id, ws, extra \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
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
      },
      extra
    )
  end

  defp load_ready(ws, issues) do
    board = Snapshot.load(workspace_id: ws.id, issues: issues, workers: [], slots_total: 3)
    Map.new(board.ready, &{&1.card.id, &1})
  end

  defp live_worker!(ws, provider) do
    key = "spc-worker-#{System.unique_integer([:positive])}"
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

  test "an unconstrained ticket is planned as before" do
    ws = failover!()
    assert %{"t-1" => %{state: :next}} = load_ready(ws, [issue("t-1", ws)])
  end

  test "a constraint that leaves an eligible provider does not hold the card" do
    ws = failover!()
    constrained = issue("t-1", ws, %{provider_constraint: %{"exclude" => ["gemini"]}})

    assert %{"t-1" => %{state: :next}} = load_ready(ws, [constrained])
  end

  test "a constraint that leaves no provider in the pool holds the card, and the next one goes" do
    ws = failover!(["claude", "gemini"])
    stuck = issue("t-1", ws, %{provider_constraint: %{"exclude" => ["claude", "gemini"]}})

    ready = load_ready(ws, [stuck, issue("t-2", ws)])

    assert %{state: :blocked, reason: reason} = ready["t-1"]
    assert reason =~ "held — provider constraint (exclude claude, gemini"
    assert %{state: :next} = ready["t-2"]
  end

  test "a failover workspace whose only allowed provider is at capacity holds the card" do
    ws = failover!(["claude", "gemini"])
    claude = account!(:claude, %{max_concurrent: 1})
    link = %{workspace_id: ws.id, provider: :claude, provider_account_id: claude.id}
    Ash.create!(WorkspaceProviderAccount, link)
    live_worker!(ws, :claude)

    stuck = issue("t-1", ws, %{provider_constraint: %{"require" => ["claude"]}})
    assert %{"t-1" => %{state: :blocked, reason: reason}} = load_ready(ws, [stuck])
    assert reason =~ "held — provider constraint (require claude"
    assert reason =~ "at capacity"
  end

  test "under most_quota the card is held when every allowed account is dropped, naming why" do
    ws = most_quota!()
    claude = account!(:claude)
    codex = account!(:codex, %{max_concurrent: 1})
    allow!(ws, claude, 0)
    allow!(ws, codex, 1)
    live_worker!(ws, :codex)

    stuck = issue("t-1", ws, %{provider_constraint: %{"require" => ["codex"]}})
    free = issue("t-2", ws, %{provider_constraint: %{"exclude" => ["codex"]}})

    ready = load_ready(ws, [stuck, free])

    assert %{state: :blocked, reason: reason} = ready["t-1"]
    assert reason =~ "held — provider constraint (require codex"
    assert reason =~ "codex:#{codex.slug} at capacity"
    assert %{state: :next} = ready["t-2"]
  end
end
