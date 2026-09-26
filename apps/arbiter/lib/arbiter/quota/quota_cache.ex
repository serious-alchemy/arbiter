defmodule Arbiter.Quota.QuotaCache do
  @moduledoc """
  Memoizes `Arbiter.Quota.list_latest_for_workspace/2`'s *decorated* result
  for the top-bar `:quota` LiveView hook (`ArbiterWeb.LiveHooks.on_mount(:quota,
  ...)`), which is the only caller that needs this — bd-4p6pw7 round 2,
  finding 1: `Arbiter.Quota.SpendCache` removed the ledger scans, but the hook
  still paid for a `Workspace` read, a `WorkspaceProviderAccount` read and a
  `ProviderAccount` read per tracked provider on *every* mount (18-20 queries
  warm). `GET /api/quota` and `arb quota` call `list_latest_for_workspace/2`
  directly and are left uncached — they're not mount-frequency callers, and
  the P5 tests that exercise them read immediately after a write, which a TTL
  cache keyed only by `{workspace_id, opts}` (with no read-your-own-write
  guarantee) would risk flaking.

  Same shape as `Arbiter.Quota.SpendCache`: a 30-second TTL covers repeat
  mounts/navigations within the window with zero queries, and every
  `Arbiter.Quota.capture/3` / `capture_oauth_usage_for_group/2` write that
  broadcasts a quota update also calls `invalidate/1` for that workspace, so a
  freshly captured snapshot never waits out the TTL to reach a new mount.
  Usage-ledger inserts don't invalidate this cache. `decorate_view/2` reads
  `SpendCache` once, at the moment a `QuotaCache` entry is computed, and
  bakes the result into the cached map's `cost_usd` (and the per-workspace
  spend nested under it). `SpendCache` itself is invalidated on insert, but
  a `QuotaCache` entry that was already cached keeps serving that
  point-in-time spend figure for the rest of the 30-second TTL — it does
  NOT pick up a fresher `SpendCache` value early. So spend, not just the
  structural fields (`account`, `workspaces`, `gate_policy`), can be stale
  for up to the TTL.
  """
  use GenServer

  alias Arbiter.Accounts.Resolver

  @table __MODULE__
  @ttl_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  `compute.()` for `{workspace_id, opts}`, cached for #{@ttl_ms}ms unless
  `invalidate/1` dropped it first.
  """
  @spec fetch(String.t() | nil, keyword(), (-> [map()])) :: [map()]
  def fetch(workspace_id, opts, compute) do
    key = {workspace_id, Enum.sort(opts)}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, inserted_at}] when now - inserted_at < @ttl_ms ->
        value

      _ ->
        value = compute.()
        :ets.insert(@table, {key, value, now})
        value
    end
  rescue
    ArgumentError -> compute.()
  end

  @doc """
  Drops every cached entry for `workspace_id` (every account under it fans
  its broadcast out to every workspace it's linked to — P5 — so this can't
  key narrower than "the whole workspace"). Safe to call before the table
  exists.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(workspace_id) do
    :ets.match_delete(@table, {{workspace_id, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Every workspace this account's quota view is shown on (P5) — what a capture on that account must invalidate."
  @spec invalidate_for_account(String.t()) :: :ok
  def invalidate_for_account(account_id) do
    for workspace_id <- Resolver.workspace_ids(account_id) do
      invalidate(workspace_id)
    end

    :ok
  end
end
