defmodule Arbiter.Quota.Seats do
  @moduledoc """
  Per-pool seat occupancy (DC4, bd-5oquxn; design
  `docs/design/provider-dynamic-concurrency.md` §3.2). **Shadow only**: nothing
  on an admission, gate, dispatch or run-stopping path reads it (I1/I2).
  `Arbiter.Accounts.Concurrency` keeps today's per-account process count under
  `legacy` and `shadow`. The scheduler walk (DC6, `Arbiter.Board.WalkInputs`)
  reads it under `scheduler_admission: shadow` or `enforce`, beside today's
  decision and never in its place; admission reads it from DC8.

  A **seat** is one unit of in-flight work on an (account, pool) pair:

    * **The pin seat.** A ticket In progress takes one seat on its
      implementer pin's pool, for its whole In-progress life: between rounds,
      while its primary worker is parked on a cross-pool reviewer, and while
      it is released to wait for CI or held for quota. (That is wider than
      `Arbiter.Tasks.SlotGate.holds_slot?/2`, which releases the slot in those
      last two cases; the seat is what the fix round comes back to.)
    * **A sub-worker.** A live run keyed under a ticket
      (`<task>#review…`, `<task>:fixpass`, `<task>:conflict`, `<task>#impl…`)
      takes one seat per live worker on its own pool, *unless* it runs on the
      pool its ticket's pin seat already holds: a ticket counts once per pool.
      A fix pass or conflict pass for a ticket in Merging has no pin seat, so
      it always seats.
    * **A reservation.** An admitted dispatch whose worker has not registered
      (`Arbiter.Accounts.Admission.pending/0`) takes the seat its worker will
      take. Once the worker's entry exists the reservation is ignored.

  Everything is derived from `Arbiter.Worker.Registry` (which stamps each
  entry's `account_id` and `pool`), the admission reservations and the stored
  state of the tickets involved; there is no counter, so a worker that dies
  releases its seat with no decrement. An entry that stamped no account is
  resolved from its (workspace, provider), as `Concurrency` does; one that
  stamped no provider reads as the workspace's default provider. A primary
  worker whose ticket cannot be read fails closed and seats: an unreadable
  state must never read as "nothing is running".

  `holders/2` and `tally/1` are pure; `counts/0` and `count/2` read the live
  state.
  """

  require Ash.Query

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Quota
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @type pool_key :: {account_id :: String.t(), pool :: String.t()}
  @type entry :: %{
          required(:registry_key) => String.t(),
          required(:account_id) => String.t() | nil,
          required(:pool) => String.t() | nil,
          optional(:reservation) => boolean(),
          optional(any()) => any()
        }

  @doc """
  Seats per (account, pool), from the live registry and reservations. Pools
  with no seat are absent.
  """
  @spec counts() :: %{pool_key() => non_neg_integer()}
  def counts, do: tally(holders())

  @doc "Seats on one (account, pool) right now."
  @spec count(String.t() | nil, String.t() | nil) :: non_neg_integer()
  def count(account_id, pool), do: counts() |> Map.get({account_id, pool}, 0)

  @doc """
  Who holds the seats, per (account, pool): the ticket id for a pin seat or a
  reservation, the registry key for a sub-worker.
  """
  @spec holders() :: %{pool_key() => [String.t()]}
  def holders do
    entries = live_entries()
    holders(entries, pinned(entries))
  end

  @doc "`holders/0`'s lists, as counts."
  @spec tally(%{pool_key() => [String.t()]}) :: %{pool_key() => non_neg_integer()}
  def tally(holders), do: Map.new(holders, fn {key, list} -> {key, length(list)} end)

  @doc """
  The pure core. `entries` are registry entries (`Registry.live_dispatches/0`'s
  shape, plus `reservation: true` for an admission's reservation) and `pinned`
  the set of ticket ids that hold a pin seat. An entry with no account or no
  pool seats nowhere.
  """
  @spec holders([entry()], MapSet.t(String.t())) :: %{pool_key() => [String.t()]}
  def holders(entries, %MapSet{} = pinned) do
    entries
    |> drop_shadowed_reservations()
    |> Enum.group_by(&base_task_id(&1.registry_key))
    |> Enum.flat_map(fn {ticket, group} -> ticket_seats(ticket, group, pinned) end)
    |> Enum.reject(fn {key, _holder} -> is_nil(key) end)
    |> Enum.group_by(fn {key, _holder} -> key end, fn {_key, holder} -> holder end)
    |> Map.new(fn {key, list} -> {key, Enum.sort(list)} end)
  end

  @doc "The ticket a registry key belongs to: the key up to its first `:` or `#`."
  @spec base_task_id(String.t()) :: String.t()
  def base_task_id(registry_key) when is_binary(registry_key),
    do: registry_key |> String.split([":", "#"], parts: 2) |> List.first()

  # ---- the pure walk --------------------------------------------------------

  # A reservation counts only until its worker's entry exists, as
  # `Concurrency` does: the registered entry takes over under the same key.
  defp drop_shadowed_reservations(entries) do
    registered = for e <- entries, not reserved?(e), into: MapSet.new(), do: e.registry_key
    Enum.reject(entries, &(reserved?(&1) and MapSet.member?(registered, &1.registry_key)))
  end

  defp reserved?(entry), do: Map.get(entry, :reservation, false) == true

  defp ticket_seats(ticket, group, pinned) do
    {primaries, subs} = Enum.split_with(group, &(&1.registry_key == ticket))

    pin =
      Enum.find_value(primaries, fn primary ->
        if reserved?(primary) or MapSet.member?(pinned, ticket), do: pool_key(primary)
      end)

    pin_seat = if pin, do: [{pin, ticket}], else: []

    sub_seats =
      for sub <- subs, key = pool_key(sub), key != pin, do: {key, sub.registry_key}

    pin_seat ++ sub_seats
  end

  defp pool_key(%{account_id: account, pool: pool}) when is_binary(account) and is_binary(pool),
    do: {account, pool}

  defp pool_key(_entry), do: nil

  # ---- the live read --------------------------------------------------------

  # Every live registry entry and reservation, with the account and pool each
  # stamped, or resolved here for an entry that predates the stamp.
  defp live_entries do
    dispatches = WorkerRegistry.live_dispatches()

    reservations =
      Admission.pending() |> Enum.map(&Map.put(&1, :reservation, true))

    {resolved, _cache} =
      Enum.map_reduce(dispatches ++ reservations, %{}, &resolve/2)

    resolved
  end

  defp resolve(entry, cache) do
    provider = entry.provider
    key = {entry.workspace_id, provider}

    {fallback, cache} =
      if entry.account_id && entry.pool do
        {nil, cache}
      else
        cached(cache, key, fn -> resolve_unstamped(entry) end)
      end

    account_id = entry.account_id || (fallback && fallback.account_id)
    pool = entry.pool || (fallback && fallback.pool)
    {%{entry | account_id: account_id, pool: pool}, cache}
  end

  defp resolve_unstamped(%{workspace_id: workspace_id, provider: provider}) do
    provider = provider || to_string(Quota.default_provider(workspace_id))

    %{
      account_id: Resolver.account_id(workspace_id, provider),
      pool: ModelFamily.classify(provider, nil).pool
    }
  rescue
    _ -> %{account_id: nil, pool: nil}
  end

  defp cached(cache, key, fun) do
    case Map.fetch(cache, key) do
      {:ok, value} ->
        {value, cache}

      :error ->
        value = fun.()
        {value, Map.put(cache, key, value)}
    end
  end

  # The tickets holding a pin seat: every primary whose ticket is In progress
  # (stored state `:active`, not an epic), or whose ticket cannot be read.
  defp pinned(entries) do
    ids =
      for e <- entries,
          not reserved?(e),
          e.registry_key == base_task_id(e.registry_key),
          uniq: true,
          do: e.registry_key

    case read_tickets(ids) do
      {:ok, tickets} ->
        known = Map.new(tickets, &{&1.id, &1})

        for id <- ids, pin_holder?(Map.get(known, id)), into: MapSet.new(), do: id

      :error ->
        MapSet.new(ids)
    end
  end

  defp read_tickets([]), do: {:ok, []}

  defp read_tickets(ids) do
    Issue |> Ash.Query.filter(id in ^ids) |> Ash.read()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # No such ticket (a worker keyed on something that is not one): fail closed.
  defp pin_holder?(nil), do: true

  defp pin_holder?(ticket) do
    Lifecycle.state_of(ticket) == :active and
      ticket.issue_type not in Issue.non_dispatchable_types()
  end
end
