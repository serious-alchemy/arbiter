defmodule Arbiter.Nodes.LocalCapacity do
  @moduledoc """
  The primary is a node too (RW8 operator amendment, bd-3igo6h): it has a
  concurrency cap of its own, and **one cap covers every run that executes on
  it** — the remote-eligible implementer placed locally *and* all the
  remote-ineligible work (ReviewGate reviewers, fix and conflict passes,
  agy/codex runs, research and task dispatches, anything bwrap-jailed).

  ## The cap

    * default — the primary's hardware suggestion, `NodeAgent.Protocol.suggestion/2`
      of this machine's CPUs and memory: the formula every node already reports
      (`min(cpus / 2, 0.8 × MemTotal / 4 GiB)`, at least 1). It is **enforced**
      like any node's cap (docs/design/provider-dynamic-concurrency.md §5.1, DC1).
      It replaces the install-wide `conductor.max_concurrent`, which is gone.
    * override — `nodes.local_max_workers` (`Arbiter.Nodes.set_local_max_workers/2`,
      the nodes page, `arb node set local --max-workers N`), up or down, **down
      to 0** so remote nodes do the work and the machine stays free.

  ## What counts, and what is held

  `kinds/0` is the list of spawn kinds, with how each is capped. A run counts
  while it is a live worker on the primary (`Arbiter.Accounts.Concurrency`'s
  occupancy read, minus runs placed on a node) or an admission reserved but not
  yet registered. Of the kinds:

    * `:at_cap` — a run of **a ticket's own implementer**: a fresh implementer
      (`Worker.Dispatch.dispatch/2` of a ticket not yet In progress), a
      re-dispatch of a ticket already In progress (`:redispatch`) and a resume
      of one (`:resume`: briefing or session, the boot Reconciler's sweep, a
      Watchdog or `LostResume` auto-resume, `arb worker resume`). Refused when
      *other* tickets' runs fill the primary's cap, and at 0. A ticket's own
      workers are left out of the count (it replaces its own run), so a resume
      of the one live ticket is never held by itself (bd-b2iigy: these used to
      be uncapped, and a restart's resume sweep put 5 runs on a cap of 2 —
      the laptop hit 100 °C);
    * `:zero_only` — **review-side follow-up roles of work already in flight**:
      a review dispatch, ReviewGate reviewers and fix rounds, merge-queue fix
      and conflict passes. They are counted, but held only when the cap is 0,
      never for merely being at it: holding them for other tickets could
      deadlock a ticket waiting for its own review
      (`Arbiter.Worker.ResumeSlot`'s no-deadlock rule).

  A held **automatic** resume is deferred, not failed: `Worker.Dispatch` hands
  it to `Arbiter.Board.Autopilot.defer_resume/4` marked `held_for:
  :local_capacity`, and the Autopilot replays it, highest ticket priority
  first, the moment `check/3` says the primary has room — the board and `arb
  scheduler status` list it as `held: local capacity`. A human resume is
  refused with the hold (`--force` goes over; recorded).

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
  alias Arbiter.NodeAgent.Protocol
  alias Arbiter.Nodes.Placement
  alias Arbiter.Settings
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  require Logger

  @local "local"

  # kind => how the primary's cap governs it. Keep in step with
  # `Arbiter.Nodes.Placement.kinds/0`; the guard test checks both.
  @kinds %{
    implementer: :at_cap,
    redispatch: :at_cap,
    resume: :at_cap,
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
  @spec kinds() :: %{atom() => :at_cap | :zero_only}
  def kinds, do: @kinds

  @doc """
  The primary's cap: `%{cap:, source: :override | :suggestion}`. Always enforced.
  """
  @spec cap() :: %{cap: non_neg_integer(), source: :override | :suggestion}
  def cap do
    case Settings.nodes_local_max_workers() do
      nil -> %{cap: suggestion(), source: :suggestion}
      n -> %{cap: n, source: :override}
    end
  rescue
    # An unreadable override must not stop the fleet: fall back to the suggestion.
    _ -> %{cap: suggestion(), source: :suggestion}
  end

  @doc """
  This machine's hardware suggestion, `NodeAgent.Protocol.suggestion/2`. The
  hardware is read once per boot; `config :arbiter, :local_hardware` (a map of
  `:cpus` and `:mem_total`) pins it, which is how the test suite holds it steady.
  """
  @spec suggestion() :: pos_integer()
  def suggestion do
    %{cpus: cpus, mem_total: mem_total} =
      Application.get_env(:arbiter, :local_hardware) || hardware()

    Protocol.suggestion(cpus, mem_total)
  end

  defp hardware do
    case :persistent_term.get({__MODULE__, :hardware}, nil) do
      nil ->
        hardware = Protocol.local_hardware()
        :persistent_term.put({__MODULE__, :hardware}, hardware)
        hardware

      hardware ->
        hardware
    end
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

    * `{:ok, :local}` — runs here (a slot of the primary's cap is reserved);
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
  {:no_node_capacity, info}}` (nothing reserved).

  Options: `:force` (go over; recorded), `:actor`, `:reason` (why the run is
  local, for the hold phrase), `:provider`, `:workspace_id`.
  """
  @spec admit(String.t(), atom(), keyword()) :: :ok | {:error, {:no_node_capacity, info()}}
  def admit(task_id, kind, opts \\ []) when is_binary(task_id) and is_map_key(@kinds, kind) do
    admit_enforced(task_id, kind, cap().cap, opts)
  end

  @doc """
  `admit/3` that takes nothing: would `kind` for `task_id` be admitted right
  now? `:ok`, or the same `{:error, {:no_node_capacity, info}}`. For a caller
  that must decide *before* it changes anything (a resume stops the prior
  worker; a scheduler waits for room before replaying a deferred resume) —
  `Worker.Dispatch` still admits for real at its own gate, so a slot taken in
  between holds the run there instead.
  """
  @spec check(String.t(), atom(), keyword()) :: :ok | {:error, {:no_node_capacity, info()}}
  def check(task_id, kind, opts \\ []) when is_binary(task_id) and is_map_key(@kinds, kind) do
    admit_enforced(task_id, kind, cap().cap, Keyword.put(opts, :reserve?, false))
  end

  defp admit_enforced(task_id, kind, cap, opts) do
    case Map.fetch!(@kinds, kind) do
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
        reserve(task_id, opts)
        :ok

      forced?(opts) ->
        reserve(task_id, opts)
        if reserve?(opts), do: record_override(task_id, cap, holders, opts)
        :ok

      true ->
        refuse(task_id, kind, cap, holders, opts)
    end
  end

  defp forced?(opts), do: Keyword.get(opts, :force) == true

  # `check/3` asks without taking the slot.
  defp reserve?(opts), do: Keyword.get(opts, :reserve?, true)

  defp reserve(task_id, opts) do
    if reserve?(opts), do: Placement.reserve(task_id, @local)
    :ok
  end

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
