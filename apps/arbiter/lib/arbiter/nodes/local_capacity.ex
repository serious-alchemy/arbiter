defmodule Arbiter.Nodes.LocalCapacity do
  @moduledoc """
  The primary is a node too (RW8 operator amendment, bd-3igo6h): it has a
  concurrency cap of its own, and **one cap covers every run that executes on
  it** — the remote-eligible implementer placed locally *and* all the
  remote-ineligible work (ReviewGate reviewers, fix and conflict passes,
  agy/codex runs, research and task dispatches, anything bwrap-jailed).

  ## The cap

    * default — the install's local concurrency, `conductor.max_concurrent`
      (`Board.Snapshot.system_max_concurrent/0`). The board already plans to it,
      so with no override this module admits everything and **dispatch behaves
      exactly as before**.
    * override — `nodes.local_max_workers` (`Arbiter.Nodes.set_local_max_workers/2`,
      the nodes page, `arb node set local --max-workers N`), up or down, **down
      to 0** so remote nodes do the work and the machine stays free. An override
      is *enforced* here.

  `conductor.max_concurrent` is a different number: the operator-owned global
  quota valve. It is never derived from this cap or from any node's.

  ## What counts, and what is held

  `kinds/0` is the list of spawn kinds, with how each is capped. A run counts
  while it is a live worker on the primary (`Arbiter.Accounts.Concurrency`'s
  occupancy read, minus runs placed on a node) or an admission reserved but not
  yet registered. Of the kinds:

    * `:at_cap` — a **fresh implementer** (`Worker.Dispatch.dispatch/2` of a
      ticket not yet In progress): refused when the primary is at its cap, and
      at 0;
    * `:zero_only` — **follow-up roles of work already in flight**: a
      re-dispatch of a ticket already In progress (`:redispatch`), a review
      dispatch, ReviewGate reviewers and fix rounds, merge-queue fix and
      conflict passes. They are counted, but held only when the cap is 0, never
      for merely being at it: a ticket's follow-up replaces the ticket's own
      slot, and holding it for other tickets could deadlock a ticket waiting
      for its own review (`Arbiter.Worker.ResumeSlot`'s no-deadlock rule);
    * `:never` — a **resume** of a ticket already In progress: counted, never
      held (stranding work is worse than overshooting).

  Not counted, because they are not workers: preflight and usage probes,
  coordinator PTY sessions, external PR reviews and ReviewPatrol re-reviews.

  A hold is `{:error, {:no_node_capacity, info}}` — the same error as a
  `remote_only` workspace with no node free — with `info.phrase` such as
  `held — local capacity 0 (run is local-only: provider codex has no podman
  path)`. It is **held, not failed**: every caller treats it like
  `{:account_at_capacity, _}`, and the run starts the moment the cap rises or a
  slot frees. The nodes page, the board and `arb server doctor` carry a
  persistent warning while the cap is 0 (`Arbiter.Nodes.Overview`).

  A guard test (`LocalCapacityKindsTest`) pins `kinds/0` and requires every
  spawn site to go through this module.
  """

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Board.Snapshot
  alias Arbiter.Nodes.Placement
  alias Arbiter.Settings
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  require Logger

  @local "local"

  # kind => how the primary's cap governs it. Keep in step with
  # `Arbiter.Nodes.Placement.kinds/0`; the guard test checks both.
  @kinds %{
    implementer: :at_cap,
    redispatch: :zero_only,
    resume: :never,
    review: :zero_only,
    reviewer: :zero_only,
    fix_pass: :zero_only,
    conflict_pass: :zero_only,
    review_fix_round: :zero_only
  }

  @type reason :: {:local_only, Placement.reason()} | :no_node | nil
  @type info :: %{
          required(:task_id) => String.t(),
          required(:node) => String.t(),
          required(:kind) => atom(),
          required(:cap) => non_neg_integer(),
          required(:holders) => [String.t()],
          required(:phrase) => String.t(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }

  @doc "Every spawn kind that counts against the primary's cap, and how it is capped."
  @spec kinds() :: %{atom() => :at_cap | :zero_only | :never}
  def kinds, do: @kinds

  @doc """
  The primary's cap: `%{cap:, source: :override | :default, enforced?:}`.
  `enforced?` is true only for an operator override.
  """
  @spec cap() :: %{cap: non_neg_integer(), source: :override | :default, enforced?: boolean()}
  def cap do
    case Settings.nodes_local_max_workers() do
      nil -> %{cap: Snapshot.system_max_concurrent(), source: :default, enforced?: false}
      n -> %{cap: n, source: :override, enforced?: true}
    end
  rescue
    # An unreadable cap must not stop the fleet: read as "not enforced".
    _ -> %{cap: Snapshot.system_max_concurrent(), source: :default, enforced?: false}
  end

  @doc """
  The runs holding the primary's slots, as registry keys: live workers with no
  node, plus admissions still waiting to register. `exclude_task:` leaves out
  every worker that task owns (a follow-up replaces its own ticket's run).
  """
  @spec holders(keyword()) :: [String.t()]
  def holders(opts \\ []) do
    exclude = Keyword.get(opts, :exclude_task)

    live =
      Concurrency.live_occupants()
      |> Enum.filter(&is_nil(Map.get(&1, :node_id)))
      |> Enum.map(& &1.registry_key)

    reserved = for %{node: @local, task_id: id} <- Placement.reservations(), do: id

    (live ++ reserved)
    |> Enum.uniq()
    |> Enum.reject(&(is_binary(exclude) and WorkerRegistry.owned_by?(&1, exclude)))
  rescue
    _ -> []
  end

  @doc """
  Decide where a dispatch runs and, if it is the primary, whether the primary
  has room: `Placement.place/2`, then `admit/3` for a run that stays local.

    * `{:ok, {:node, row}}` — placed on a node (a slot is reserved);
    * `{:ok, :local}` — runs here (a slot of the primary's cap is reserved when
      the cap is enforced);
    * `{:error, {:no_node_capacity, info}}` — held.

  `request` is a `t:Arbiter.Nodes.Placement.request/0`; `opts` are
  `Placement.place/2`'s plus `admit/3`'s `:force` and `:actor`.
  """
  @spec gate(Placement.request(), keyword()) ::
          {:ok, :local} | {:ok, {:node, map()}} | {:error, {:no_node_capacity, map()}}
  def gate(request, opts \\ []) do
    case Placement.place(request, opts) do
      {:ok, {:node, _row}} = placed ->
        placed

      {:ok, {:local, why}} ->
        admit_opts =
          opts
          |> Keyword.take([:force, :actor])
          |> Keyword.merge(
            reason: why,
            provider: request.provider,
            workspace_id: Map.get(request, :workspace_id)
          )

        with :ok <- admit(request.task_id, request.kind, admit_opts), do: {:ok, :local}

      {:error, _} = refused ->
        refused
    end
  end

  @doc """
  Admit `kind` for `task_id` onto the primary. `:ok`, or `{:error,
  {:no_node_capacity, info}}` (nothing reserved). With no override this is
  always `:ok` and reserves nothing.

  Options: `:force` (go over; recorded), `:actor`, `:reason` (why the run is
  local, for the hold phrase), `:provider`, `:workspace_id`.
  """
  @spec admit(String.t(), atom(), keyword()) :: :ok | {:error, {:no_node_capacity, info()}}
  def admit(task_id, kind, opts \\ []) when is_binary(task_id) and is_map_key(@kinds, kind) do
    case cap() do
      %{enforced?: false} -> :ok
      %{cap: cap} -> admit_enforced(task_id, kind, cap, opts)
    end
  end

  defp admit_enforced(task_id, kind, cap, opts) do
    case Map.fetch!(@kinds, kind) do
      :never ->
        :ok

      :zero_only ->
        if cap > 0 or forced?(opts),
          do: :ok,
          else: refuse(task_id, kind, cap, holders(exclude_task: task_id), opts)

      :at_cap ->
        :global.trans(
          {{__MODULE__, @local}, self()},
          fn -> admit_at_cap(task_id, kind, cap, opts) end,
          [node()]
        )
    end
  end

  defp admit_at_cap(task_id, kind, cap, opts) do
    holders = holders(exclude_task: task_id)

    cond do
      length(holders) < cap ->
        Placement.reserve(task_id, @local)
        :ok

      forced?(opts) ->
        Placement.reserve(task_id, @local)
        record_override(task_id, cap, holders, opts)
        :ok

      true ->
        refuse(task_id, kind, cap, holders, opts)
    end
  end

  defp forced?(opts), do: Keyword.get(opts, :force) == true

  defp refuse(task_id, kind, cap, holders, opts) do
    phrase = phrase(cap, holders, Keyword.get(opts, :reason), Keyword.get(opts, :provider), kind)

    info = %{
      task_id: task_id,
      node: @local,
      kind: kind,
      cap: cap,
      holders: holders,
      reason: Keyword.get(opts, :reason),
      phrase: phrase,
      message: message(task_id, phrase, cap)
    }

    {:error, {:no_node_capacity, info}}
  end

  @doc "Release the calling process's admission for `task_id` (see `Placement.release/1`)."
  @spec release(String.t()) :: :ok
  defdelegate release(task_id), to: Placement

  # ---- phrases ---------------------------------------------------------------

  defp phrase(cap, holders, reason, provider, kind) do
    head =
      if cap == 0,
        do: "held — local capacity 0",
        else: "held — local capacity full (cap #{cap}, #{length(holders)} running)"

    head <> suffix(reason, provider, kind)
  end

  defp suffix({:local_only, why}, provider, kind),
    do: " (run is local-only: #{Placement.reason_phrase(why, %{provider: provider, kind: kind})})"

  defp suffix(:no_node, _provider, _kind), do: " (no node had a free slot)"
  defp suffix(_reason, _provider, _kind), do: ""

  defp message(task_id, phrase, 0) do
    "#{phrase}: #{task_id} waits because this machine's worker cap is 0 — nodes do the work. " <>
      "It starts when the cap is raised (`arb node set local --max-workers N`) or, if it is " <>
      "remote-eligible, when a node has a free slot."
  end

  defp message(task_id, phrase, _cap) do
    "#{phrase}: #{task_id} waits for a slot on this machine. It starts when a run ends, " <>
      "when the cap is raised (`arb node set local --max-workers N`), or with the override " <>
      "(`arb dispatch --over-cap`); the override is recorded."
  end

  defp record_override(task_id, cap, holders, opts) do
    Logger.warning(
      "LocalCapacity: #{task_id} dispatched over the primary's cap (#{cap}, held by " <>
        "#{inspect(holders)}) by force from #{inspect(Keyword.get(opts, :actor))}"
    )

    case Keyword.get(opts, :workspace_id) do
      ws_id when is_binary(ws_id) ->
        Arbiter.Events.broadcast(ws_id, "local_cap_override", %{
          "task_id" => task_id,
          "cap" => cap,
          "holders" => holders,
          "actor" => Keyword.get(opts, :actor)
        })

      _ ->
        :ok
    end
  end
end
