defmodule Arbiter.Worker.MergeTrain do
  @moduledoc """
  The coalesced merge train of the auto-merge lane (bd-1754qj, the counterpart of
  bd-d4m8qf's queue head for `merge.auto_merge=true`).

  On the auto-merge lane each ticket's `Arbiter.Worker.Watchdog` syncs its own
  approved MR; with N of them every move of the target branch cost N sync
  pipelines, and each sync made the others stale again at the next merge. There
  is no queue process to choose among them, so this is the one thing they share:
  per *target* (a workspace, a repo and a base branch), **at most one MR is in a
  sync or CI-after-sync state at a time** — the head. An MR that needs a sync and
  is not the head waits (`{:wait, head_task_id}`), spending no sync, no
  `merge.max_freshness_syncs` budget and no CI-remediation attempt.

  The election is `Arbiter.Workflows.MergeHead`, the rule the MergeQueue applies
  to its own train: the head is the best by priority then merge-ready time, keeps
  its place until it merges or leaves, and hands it on when it is parked
  (`release/3`), closed or its process dies, red or otherwise stalled for
  `MergeHead.head_stall_grace_ticks/0` ticks, reporting itself ready to merge for
  `MergeHead.head_ready_ticks/0` ticks without merging (parked on something
  Arbiter-internal), or *running* CI on one head SHA past
  `MergeHead.head_ci_wait_ticks/0` ticks (a pipeline still queued does not
  count). The last two bounds are per workspace: `merge.train_ci_wait_ms` and
  `merge.train_ready_ticks`. At equal priority a green stale MR is elected ahead
  of one in CI remediation (`red?`).

  ## Who calls what

    * `claim/3` — a Watchdog about to sync (merge-time freshness, a forge-reported
      `:behind_base`, a CI-remediation sync) asks for the place. `:head`: go ahead.
      `{:wait, head}`: do not sync. A waiter asks again on each poll, which also
      keeps it in the order.
    * `tick/3` — the head's Watchdog reports once per poll while it holds the
      place (its CI, a block, a failed poll); that is where stalls are counted
      and where the place is handed on.
    * `release/3` — the Watchdog is done with its place (merged, closed, parked,
      its merge refused).
    * `acquire_merge/3` / `release_merge/3` — one merge at a time per target, so
      the next MR's freshness check sees the target the previous merge produced.
      An MR within `merge.up_to_date_tolerance` merges without a sync whatever
      its place, but not at the same instant as another.

  ## Crash and restart

  The state is in memory and every entry is the caller's last report. A Watchdog
  that exits (merged, closed, stopped) is dropped by its monitor; an entry not
  refreshed within its `ttl_ms` is dropped too. A *crashed* head whose sync or
  pipeline is still going is the exception (bd-az0dcu): dropping it would elect
  the next MR, whose sync starts a second pipeline beside the first. It stays the
  head, without a pid, for `orphan_ms` (the CI-wait bound), and the restarted
  Watchdog takes the place back with `resume/3`. A Watchdog records on its
  ticket's lane when it first asked (`train_ready_since`, so a restart keeps the
  order) and the head a sync started from (`train_synced_from`, so a restarted
  Watchdog knows to `resume/3`). When the train process itself
  restarts it knows nothing, so it forms for `merge_train_settle_ms` (default
  30s, about a poll) before electing anyone: waiters answer `{:wait, :forming}`
  while every Watchdog re-registers on its next poll, then the best-ordered one
  leads rather than whichever polled first. Nothing syncs in the meantime;
  nothing is lost either, since the head is a pure function of the entries. An
  MR whose sync was in flight before the restart resumes its place the moment
  its Watchdog restarts (even while the train is forming), so nothing else syncs
  beside its pipeline; one without a recorded sync competes like the others, in
  merge-ready order.

  Callers fail open (`Watchdog` treats an unreachable train as "you are the
  head"): the train only ever saves syncs, never gates a merge.

  ## Speculative seats (bd-6dyva0)

  With `merge.train.depth` K > 1 a target's approved MRs ride a speculative
  train instead of waiting for one serial head: up to K of them are *seated*
  (`board/3`), and each tests a car — a merge commit on an Arbiter-owned ref
  (`Arbiter.Mergers.TrainCar`) of the car ahead of it (the target, for the front
  seat) and its own head. The train holds only the seats and what each car
  stands on; the Watchdogs build, test, merge, and leave (`leave/2`). A red car
  is its MR's own fault only when every car ahead of it is green (`red:
  :eject`); behind a car still running or red it holds. When a seat goes, every
  car behind it re-bases, and its Watchdog rebuilds it.

  Seats are kept across a Watchdog crash (the seat and its car, for
  `resume_grace_ms`) and rebuilt after a server restart from the cars
  themselves: each car names the task whose car it was built on, so a car that
  comes back is put back after it, and a seat is held for a car still missing
  (`ghost_grace_ms`). While the train forms only MRs riding a car are seated.
  Nothing here can make a wrong merge: the Watchdog merges a car's MR only when
  the forge's merge would land the car's tested tree on the target, whatever the
  seats say.
  """

  use GenServer

  alias Arbiter.Workflows.MergeHead

  require Logger

  @default_settle_ms 30_000
  @default_ttl_ms 120_000
  # A merge slot is held for one poll; a holder that neither renews (by asking
  # again) nor releases within this is presumed to have lost the slot.
  @default_merge_lease_ms 300_000

  @type key :: {workspace_id :: String.t() | nil, repo :: String.t() | nil, target :: String.t()}
  @type role :: :head | {:wait, task_id :: String.t() | :forming | nil}

  # ---- API ----------------------------------------------------------------

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Ask for the place to sync. `entry` is a `MergeHead` item (`task_id`, `status`,
  `priority`, `opened_at`, `last_block_reason`, `last_head_sha`, …) plus an
  optional `ttl_ms`.
  """
  @spec claim(key(), map(), GenServer.server()) :: role()
  def claim(key, entry, server \\ __MODULE__),
    do: GenServer.call(server, {:claim, key, entry, self()})

  @doc "The head's once-per-poll report; the place may be handed on. Else as `claim/3`."
  @spec tick(key(), map(), GenServer.server()) :: role()
  def tick(key, entry, server \\ __MODULE__),
    do: GenServer.call(server, {:tick, key, entry, self()})

  @doc """
  A (re)started Watchdog whose MR had a sync under way before it went away asks
  for its place back (bd-az0dcu). `:head` when the train still holds it for this
  task (its previous Watchdog crashed, see "Crash and restart") or holds no head
  at all (the server restarted, so the train forgot): the head is seated at once,
  even while the train is still forming, because its synced pipeline is running
  whether or not anyone knows. `{:wait, head}` when another MR holds the place.
  """
  @spec resume(key(), map(), GenServer.server()) :: role()
  def resume(key, entry, server \\ __MODULE__),
    do: GenServer.call(server, {:resume, key, entry, self()})

  @doc "Record that the head was just synced from `sha` (see `MergeHead.new_watch/0`)."
  @spec note_synced(key(), String.t(), String.t() | nil, GenServer.server()) :: :ok
  def note_synced(key, task_id, sha, server \\ __MODULE__),
    do: GenServer.call(server, {:note_synced, key, task_id, sha})

  @doc "Leave the train: the place, if held, goes to the next."
  @spec release(key(), String.t(), GenServer.server()) :: :ok
  def release(key, task_id, server \\ __MODULE__),
    do: GenServer.call(server, {:release, key, task_id})

  @doc """
  Take the target's merge slot: `:ok`, or `{:busy, holder_task_id}`. The holder
  renews by asking again; a slot not renewed or released within
  `:merge_lease_ms` (default 5 minutes) is freed for the next asker.
  """
  @spec acquire_merge(key(), String.t(), GenServer.server()) ::
          :ok | {:busy, String.t()}
  def acquire_merge(key, task_id, server \\ __MODULE__),
    do: GenServer.call(server, {:acquire_merge, key, task_id, self()})

  @spec release_merge(key(), String.t(), GenServer.server()) :: :ok
  def release_merge(key, task_id, server \\ __MODULE__),
    do: GenServer.call(server, {:release_merge, key, task_id})

  @doc """
  Board the speculative train (bd-6dyva0, `merge.train.depth` > 1): ask for a
  seat, and report the car this MR rides in. `entry` carries `task_id`,
  `priority`, `opened_at`, `depth` (the target's effective depth; `1` while CI
  backpressure holds), `car` (`nil`, or the MR's car: `sha`, `base_task` — the
  task whose car it was built on, `nil` when built on the target — and whatever
  else the Watchdog keeps), `car_status` (`:none`, `:building`, `:pending`,
  `:running`, `:green`, `:red`), and optionally `ttl_ms`, `resume_grace_ms`
  (how long a crashed Watchdog's seat is kept for its restart) and
  `ghost_grace_ms` (how long a seat is kept for a car another car stands on
  that has not boarded since the train restarted).

  `{:seat, seat}` — `position` (1 = the front), `front?`, `ahead` (task ids),
  `base` (`:target` at the front, `{:car, task_id, sha}` behind a built car,
  `:pending` behind a car not built or not seen yet) and `red` (`:eject` when
  every car ahead is green, so a red car is this MR's own; `:hold` otherwise).
  `{:wait, {:full, depth}}` — every seat is taken. `{:wait, :forming}` — the
  train restarted and is still collecting its cars; only an MR that already has
  a car is seated meanwhile, in the order the cars stand on each other.
  """
  @spec board(key(), map(), GenServer.server()) ::
          {:seat, map()} | {:wait, :forming | {:full, pos_integer()}}
  def board(key, entry, server \\ __MODULE__),
    do: GenServer.call(server, {:board, key, entry, self()})

  @doc "Leave the speculative train: the seat goes, and every car behind it re-bases."
  @spec leave(key(), String.t(), GenServer.server()) :: :ok
  def leave(key, task_id, server \\ __MODULE__),
    do: GenServer.call(server, {:leave, key, task_id})

  @doc "The speculative train's seats, front first (observability; tests)."
  @spec seats(key(), GenServer.server()) :: [map()]
  def seats(key, server \\ __MODULE__), do: GenServer.call(server, {:seats, key})

  @doc "End the forming period now (tests; operators)."
  @spec settle_now(GenServer.server()) :: :ok
  def settle_now(server \\ __MODULE__), do: GenServer.call(server, :settle_now)

  @doc "The head and the task ids waiting behind it, in order."
  @spec view(key(), GenServer.server()) :: %{head: String.t() | nil, waiting: [String.t()]}
  def view(key, server \\ __MODULE__), do: GenServer.call(server, {:view, key})

  # A resuming Watchdog is seated only on a live sync: it started one (`synced_from`
  # is the head that sync started from), the forge applied it (the MR's head has
  # moved on) and the pipeline that follows is running. A sync that never applied,
  # or started no pipeline (pending), takes the normal election instead.
  defp live_sync?(synced_from, entry) do
    head = Map.get(entry, :last_head_sha)

    is_binary(synced_from) and is_binary(head) and head != synced_from and
      Map.get(entry, :status) == :ci_running and Map.get(entry, :ci_phase) == :running
  end

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    settle =
      case Keyword.get(
             opts,
             :settle_ms,
             Application.get_env(:arbiter, :merge_train_settle_ms, @default_settle_ms)
           ) do
        ms when is_integer(ms) and ms > 0 ->
          Process.send_after(self(), :settled, ms)
          :forming

        :infinity ->
          :forming

        _ ->
          :settled
      end

    lease =
      case Keyword.get(
             opts,
             :merge_lease_ms,
             Application.get_env(:arbiter, :merge_train_merge_lease_ms, @default_merge_lease_ms)
           ) do
        ms when is_integer(ms) and ms >= 0 -> ms
        _ -> @default_merge_lease_ms
      end

    {:ok, %{settle: settle, trains: %{}, merge_lease_ms: lease}}
  end

  @impl true
  def handle_call({:claim, key, entry, pid}, _from, state) do
    {role, state} = do_claim(state, key, entry, pid)
    {:reply, role, state}
  end

  def handle_call({:tick, key, entry, pid}, _from, state) do
    id = entry.task_id
    train = Map.get(state.trains, key, new_train())

    if train.head == id do
      train = upsert(train, entry, pid)
      {role, train} = advance_head(train, key, id)
      {:reply, role, put_train(state, key, train)}
    else
      {role, state} = do_claim(state, key, entry, pid)
      {:reply, role, state}
    end
  end

  def handle_call({:resume, key, entry, pid}, _from, state) do
    id = entry.task_id
    train = Map.get(state.trains, key, new_train())

    {synced_from, entry} = Map.pop(entry, :synced_from)

    if train.head == id or (is_nil(train.head) and live_sync?(synced_from, entry)) do
      train = upsert(train, entry, pid)
      watch = Map.put(old_watch(train, id), :synced_from, synced_from)
      item = train.entries |> Map.fetch!(id) |> Map.fetch!(:item) |> Map.put(:queue_head, watch)
      train = set_head(train, item)
      {:reply, :head, put_train(state, key, train)}
    else
      {role, state} = do_claim(state, key, entry, pid)
      {:reply, role, state}
    end
  end

  def handle_call({:note_synced, key, id, sha}, _from, state) do
    state =
      update_train(state, key, fn
        %{head: ^id, entries: %{^id => %{item: %{queue_head: %{} = watch} = item} = e}} = train ->
          item = %{item | queue_head: %{watch | synced_from: sha}}
          %{train | entries: Map.put(train.entries, id, %{e | item: item})}

        train ->
          train
      end)

    {:reply, :ok, state}
  end

  def handle_call({:release, key, id}, _from, state) do
    {:reply, :ok, update_train(state, key, &drop(&1, id))}
  end

  def handle_call({:acquire_merge, key, id, pid}, _from, state) do
    train = Map.get(state.trains, key, new_train())

    case train.merge do
      nil ->
        ref = Process.monitor(pid)
        {:reply, :ok, put_train(state, key, %{train | merge: {id, ref, now()}})}

      # The holder asking again may be a replaced Watchdog (same task id, new
      # pid): the monitor must follow the pid that holds the slot now, or the
      # old one's exit frees it and the new one's does not.
      {^id, ref, _at} ->
        Process.demonitor(ref, [:flush])
        ref = Process.monitor(pid)
        {:reply, :ok, put_train(state, key, %{train | merge: {id, ref, now()}})}

      {holder, ref, at} ->
        if now() - at >= state.merge_lease_ms do
          Logger.warning(
            "MergeTrain: merge slot for #{label(key)} held by #{holder} was not renewed " <>
              "within #{state.merge_lease_ms}ms; freeing it for #{id}"
          )

          Process.demonitor(ref, [:flush])
          new_ref = Process.monitor(pid)
          {:reply, :ok, put_train(state, key, %{train | merge: {id, new_ref, now()}})}
        else
          {:reply, {:busy, holder}, state}
        end
    end
  end

  def handle_call({:release_merge, key, id}, _from, state) do
    {:reply, :ok, update_train(state, key, &drop_merge(&1, id))}
  end

  def handle_call({:board, key, entry, pid}, _from, state) do
    id = entry.task_id
    depth = max(Map.get(entry, :depth) || 1, 1)

    train =
      state.trains
      |> Map.get(key, new_train())
      |> upsert_rider(entry, pid)
      |> expire_riders(id, state.settle)
      |> seat_resuming(id, entry)
      |> fill_seats(depth, state.settle)

    reply =
      cond do
        id in train.seats -> {:seat, seat_info(train, id, state.settle)}
        state.settle == :forming -> {:wait, :forming}
        true -> {:wait, {:full, depth}}
      end

    {:reply, reply, put_train(state, key, train)}
  end

  def handle_call({:leave, key, id}, _from, state) do
    {:reply, :ok, update_train(state, key, &drop_rider(&1, id))}
  end

  def handle_call({:seats, key}, _from, state) do
    train = Map.get(state.trains, key, new_train())

    seats =
      Enum.map(train.seats, fn id ->
        rider = Map.fetch!(train.riders, id)

        %{
          task_id: id,
          car: rider.car,
          status: rider.status,
          ghost?: rider.ghost?,
          orphan?: is_nil(rider.pid) and not rider.ghost?
        }
      end)

    {:reply, seats, state}
  end

  def handle_call(:settle_now, _from, state), do: {:reply, :ok, %{state | settle: :settled}}

  def handle_call({:view, key}, _from, state) do
    train = Map.get(state.trains, key, new_train())

    waiting =
      train.entries
      |> Map.values()
      |> Enum.map(& &1.item)
      |> MergeHead.sort()
      |> Enum.map(& &1.task_id)
      |> List.delete(train.head)

    {:reply, %{head: train.head, waiting: waiting}, state}
  end

  @impl true
  def handle_info(:settled, state), do: {:noreply, %{state | settle: :settled}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    trains =
      state.trains
      |> Enum.map(fn {key, train} ->
        {key, train |> drop_ref(ref, reason) |> drop_rider_ref(ref, reason)}
      end)
      |> Enum.reject(fn {_key, train} -> empty?(train) end)
      |> Map.new()

    {:noreply, %{state | trains: trains}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- the rule -----------------------------------------------------------

  defp do_claim(state, key, entry, pid) do
    id = entry.task_id
    train = state.trains |> Map.get(key, new_train()) |> upsert(entry, pid) |> expire(id)

    {role, train} =
      cond do
        train.head == id -> {:head, train}
        train.head != nil -> {{:wait, train.head}, train}
        state.settle == :forming -> {{:wait, :forming}, train}
        true -> elect(train, key, id)
      end

    {role, put_train(state, key, train)}
  end

  # No head: the front of the train takes the place, which may not be the caller
  # (a better-ordered MR registered on an earlier poll and is still asking).
  defp elect(train, key, id) do
    {head, _} = train |> items() |> MergeHead.pick()
    announce(key, train, head)
    train = set_head(train, head)

    cond do
      is_nil(head) -> {{:wait, nil}, train}
      head.task_id == id -> {:head, train}
      true -> {{:wait, head.task_id}, train}
    end
  end

  defp advance_head(train, key, id) do
    {head, handed_on} = train |> items() |> MergeHead.pick()

    with {incumbent, why} <- handed_on do
      Logger.warning(
        "MergeTrain: merge head #{incumbent.task_id} for #{label(key)} #{why}; handing its " <>
          "place on"
      )
    end

    if head && head.task_id != id, do: announce(key, train, head)
    train = set_head(train, head)

    cond do
      is_nil(head) -> {{:wait, nil}, train}
      head.task_id == id -> {:head, train}
      true -> {{:wait, head.task_id}, train}
    end
  end

  defp announce(key, train, %{task_id: id}) do
    waiting = map_size(train.entries) - 1

    Logger.info(
      "MergeTrain: #{id} is the merge head for #{label(key)} (#{waiting} waiting behind it); " <>
        "only it is synced"
    )
  end

  defp announce(_key, _train, nil), do: :ok

  defp label({_workspace, repo, target}),
    do: Enum.map_join(Enum.reject([repo, target], &is_nil/1), "/", &to_string/1)

  # ---- bookkeeping --------------------------------------------------------

  defp new_train, do: %{entries: %{}, head: nil, merge: nil, riders: %{}, seats: []}

  defp empty?(train),
    do: train.entries == %{} and is_nil(train.merge) and train.riders == %{} and train.seats == []

  defp items(train), do: train.entries |> Map.values() |> Enum.map(& &1.item) |> MergeHead.sort()

  defp upsert(train, entry, pid) do
    id = entry.task_id
    old = Map.get(train.entries, id)

    ref =
      case old do
        %{pid: ^pid, ref: ref} ->
          ref

        %{ref: ref} ->
          demonitor(ref)
          Process.monitor(pid)

        nil ->
          Process.monitor(pid)
      end

    {ttl, entry} = Map.pop(entry, :ttl_ms, @default_ttl_ms)

    item =
      if train.head == id and old,
        do: Map.put(entry, :queue_head, old.item.queue_head),
        else: Map.delete(entry, :queue_head)

    entries =
      Map.put(train.entries, id, %{
        item: item,
        pid: pid,
        ref: ref,
        ttl_ms: ttl,
        seen_at: now()
      })

    %{train | entries: entries}
  end

  # Entries that stopped asking are not in the order. The caller and the head
  # (which reports through `tick/3`) are judged on what they last said.
  defp expire(train, keep) do
    now = now()

    {live, dead} =
      Enum.split_with(train.entries, fn {id, e} -> id == keep or now - e.seen_at < e.ttl_ms end)

    Enum.each(dead, fn {_id, e} -> demonitor(e.ref) end)
    train = %{train | entries: Map.new(live)}

    if train.head && not Map.has_key?(train.entries, train.head),
      do: %{train | head: nil},
      else: train
  end

  # Only the head carries a `queue_head` watch: an item handed on has lost its.
  defp set_head(train, head) do
    keep = head && head.task_id

    entries =
      Map.new(train.entries, fn
        {^keep, e} -> {keep, %{e | item: head}}
        {id, e} -> {id, %{e | item: Map.delete(e.item, :queue_head)}}
      end)

    %{train | head: keep, entries: entries}
  end

  defp drop(train, id) do
    case Map.pop(train.entries, id) do
      {nil, _} ->
        train

      {e, entries} ->
        demonitor(e.ref)
        %{train | entries: entries, head: if(train.head == id, do: nil, else: train.head)}
    end
  end

  defp drop_merge(%{merge: {id, ref, _at}} = train, id) do
    Process.demonitor(ref, [:flush])
    %{train | merge: nil}
  end

  defp drop_merge(train, _id), do: train

  defp drop_ref(train, ref, reason) do
    train =
      case Enum.find(train.entries, fn {_id, e} -> e.ref == ref end) do
        {id, e} ->
          if orphan?(train, id, e, reason), do: orphan(train, id, e), else: drop(train, id)

        nil ->
          train
      end

    case train.merge do
      {_id, ^ref, _at} -> %{train | merge: nil}
      _ -> train
    end
  end

  # A head whose Watchdog crashed (any exit but a normal stop, which releases
  # first) while its sync or the pipeline after it is still going. Dropping it
  # would elect the next MR, whose sync would start a second pipeline beside the
  # first. It stays the head, unmonitored, for `orphan_ms` (the CI-wait bound) so
  # the restarted Watchdog can `resume/3`; a head nobody resumes then expires like
  # any entry that stopped asking.
  defp orphan?(train, id, e, reason) do
    crashed?(reason) and train.head == id and
      (e.item.status in [:ci_running, :updating_base] or
         (e.item.status == :behind_base and synced?(e.item))) and
      is_nil(Map.get(e.item, :last_block_reason))
  end

  # A deliberate stop (a merge, a close, an operator's pull) is not a crash.
  defp crashed?(reason),
    do: reason not in [:normal, :shutdown] and not match?({:shutdown, _}, reason)

  defp synced?(item), do: match?(%{synced_from: sha} when is_binary(sha), item[:queue_head])

  defp orphan(train, id, e) do
    ttl = orphan_ttl(e)
    entry = %{e | pid: nil, ref: nil, ttl_ms: ttl, seen_at: now()}
    %{train | entries: Map.put(train.entries, id, entry)}
  end

  defp orphan_ttl(e) do
    case Map.get(e.item, :orphan_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> e.ttl_ms
    end
  end

  defp old_watch(train, id) do
    case train.entries do
      %{^id => %{item: %{queue_head: %{} = watch}}} -> watch
      _ -> MergeHead.new_watch()
    end
  end

  defp put_train(state, key, train) do
    trains =
      if empty?(train), do: Map.delete(state.trains, key), else: Map.put(state.trains, key, train)

    %{state | trains: trains}
  end

  defp update_train(state, key, fun) do
    case Map.fetch(state.trains, key) do
      {:ok, train} -> put_train(state, key, fun.(train))
      :error -> state
    end
  end

  # ---- speculative seats (bd-6dyva0) ----------------------------------------
  #
  # `riders` is every MR that asked for a seat, plus the seats kept without a
  # Watchdog: an *orphan* (its Watchdog crashed; its car is still known and may
  # still be running) and a *ghost* (a car another car stands on that has not
  # boarded since this train started). Both carry `expires_at`. `seats` is the
  # order, front first. A seat is kept until its MR leaves; a free seat goes to
  # the best-ordered waiting MR (`MergeHead.sort/1`), and only once the train
  # has formed. An MR that comes back already riding a car (a restart, a
  # crash) is put back where its car stands — after the car it was built on,
  # before the car built on it — whether the train has formed or not, so the
  # order survives and nobody new takes its place.

  @default_resume_grace_ms 120_000

  # `{train, resuming?}`: resuming when this train has not had a live Watchdog
  # for the MR until now (first sight, a ghost or an orphan).
  defp upsert_rider(train, entry, pid) do
    id = entry.task_id
    old = Map.get(train.riders, id)

    ref =
      case old do
        %{pid: ^pid, ref: ref} when not is_nil(ref) ->
          ref

        %{ref: ref} ->
          demonitor(ref)
          Process.monitor(pid)

        nil ->
          Process.monitor(pid)
      end

    rider = %{
      item: %{
        task_id: id,
        priority: Map.get(entry, :priority),
        opened_at: Map.get(entry, :opened_at)
      },
      pid: pid,
      ref: ref,
      seen_at: now(),
      ttl_ms: Map.get(entry, :ttl_ms, @default_ttl_ms),
      grace_ms: grace(entry, :resume_grace_ms),
      ghost_grace_ms: grace(entry, :ghost_grace_ms),
      car: Map.get(entry, :car),
      status: Map.get(entry, :car_status, :none),
      expires_at: nil,
      ghost?: false,
      resuming?: is_nil(old) or old.ghost? or is_nil(old.pid)
    }

    %{train | riders: Map.put(train.riders, id, rider)}
  end

  defp grace(entry, key) do
    case Map.get(entry, key) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @default_resume_grace_ms
    end
  end

  # A seat kept without a Watchdog (an orphan, a ghost) does not lapse while the
  # train forms: forming is the time the Watchdogs have to come back.
  defp expire_riders(train, keep, settle) do
    now = now()

    train.riders
    |> Enum.filter(fn {id, rider} ->
      id != keep and not (settle == :forming and is_nil(rider.pid)) and
        rider_expired?(rider, now)
    end)
    |> Enum.reduce(train, fn {id, _rider}, train -> drop_rider(train, id) end)
  end

  defp rider_expired?(%{expires_at: at}, now) when is_integer(at), do: now >= at
  defp rider_expired?(rider, now), do: now - rider.seen_at >= rider.ttl_ms

  defp seat_resuming(train, id, _entry) do
    case Map.fetch!(train.riders, id) do
      %{resuming?: true, car: %{} = car} ->
        train = if id in train.seats, do: train, else: insert_by_chain(train, id, car)
        train |> ghost_for_base(id, car) |> reorder_by_chain()

      _ ->
        train
    end
  end

  defp insert_by_chain(train, id, car) do
    parent = Map.get(car, :base_task)
    child_at = Enum.find_index(train.seats, &(base_task(train, &1) == id))
    parent_at = if parent, do: Enum.find_index(train.seats, &(&1 == parent))

    seats =
      cond do
        is_integer(child_at) -> List.insert_at(train.seats, child_at, id)
        is_integer(parent_at) -> List.insert_at(train.seats, parent_at + 1, id)
        true -> train.seats ++ [id]
      end

    %{train | seats: seats}
  end

  # The car a resuming rider stands on has not boarded (yet): keep a seat for it,
  # just ahead, for `ghost_grace_ms`, so the rider is not taken for the front
  # while that car may still come back.
  defp ghost_for_base(train, id, car) do
    parent = Map.get(car, :base_task)

    if is_nil(parent) or Map.has_key?(train.riders, parent) do
      train
    else
      at = Enum.find_index(train.seats, &(&1 == id))

      ghost = %{
        item: %{task_id: parent, priority: nil, opened_at: nil},
        pid: nil,
        ref: nil,
        seen_at: now(),
        ttl_ms: 0,
        grace_ms: 0,
        ghost_grace_ms: 0,
        car: nil,
        status: :unknown,
        expires_at: now() + Map.fetch!(train.riders, id).ghost_grace_ms,
        ghost?: true,
        resuming?: false
      }

      %{
        train
        | riders: Map.put(train.riders, parent, ghost),
          seats: List.insert_at(train.seats, at, parent)
      }
    end
  end

  # Put every seated car right behind the car it stands on, keeping the order
  # otherwise. Riders come back in any order after a restart, and a car that
  # comes back before the car standing on it cannot know where it belongs until
  # that one says. No seat is ever dropped, whatever the links say.
  defp reorder_by_chain(%{seats: seats} = train) do
    parents = Map.new(seats, &{&1, chain_parent(train, &1, seats)})
    roots = Enum.filter(seats, &is_nil(Map.fetch!(parents, &1)))

    {ordered, _seen} =
      Enum.reduce(roots, {[], MapSet.new()}, &emit_chain(&1, seats, parents, &2))

    ordered = Enum.reverse(ordered)
    %{train | seats: ordered ++ Enum.reject(seats, &(&1 in ordered))}
  end

  defp emit_chain(id, seats, parents, {out, seen} = acc) do
    if MapSet.member?(seen, id) do
      acc
    else
      seats
      |> Enum.filter(&(Map.fetch!(parents, &1) == id))
      |> Enum.reduce({[id | out], MapSet.put(seen, id)}, &emit_chain(&1, seats, parents, &2))
    end
  end

  defp chain_parent(train, id, seats) do
    case base_task(train, id) do
      parent when is_binary(parent) and parent != id -> if parent in seats, do: parent
      _ -> nil
    end
  end

  defp base_task(train, id) do
    case train.riders do
      %{^id => %{car: %{} = car}} -> Map.get(car, :base_task)
      _ -> nil
    end
  end

  defp fill_seats(train, _depth, :forming), do: train

  defp fill_seats(train, depth, _settled) do
    case depth - length(train.seats) do
      free when free > 0 ->
        boarding =
          train.riders
          |> Enum.reject(fn {id, rider} -> id in train.seats or is_nil(rider.pid) end)
          |> Enum.map(fn {_id, rider} -> rider.item end)
          |> MergeHead.sort()
          |> Enum.take(free)
          |> Enum.map(& &1.task_id)

        %{train | seats: train.seats ++ boarding}

      _ ->
        train
    end
  end

  defp seat_info(train, id, settle) do
    index = Enum.find_index(train.seats, &(&1 == id))
    ahead = Enum.take(train.seats, index)

    base =
      case List.last(ahead) do
        nil ->
          :target

        prev ->
          case Map.fetch!(train.riders, prev) do
            %{ghost?: false, car: %{sha: sha}} when is_binary(sha) -> {:car, prev, sha}
            _ -> :pending
          end
      end

    red =
      if Enum.all?(ahead, &(Map.fetch!(train.riders, &1).status == :green)),
        do: :eject,
        else: :hold

    %{
      position: index + 1,
      front?: index == 0,
      ahead: ahead,
      base: base,
      red: red,
      forming?: settle == :forming
    }
  end

  defp drop_rider(train, id) do
    {rider, riders} = Map.pop(train.riders, id)
    if rider, do: demonitor(rider.ref)
    %{train | riders: riders, seats: List.delete(train.seats, id)}
  end

  # A seated rider whose Watchdog crashed keeps its seat (and its car) for
  # `resume_grace_ms`: the cars behind stand on it, and its restarted Watchdog
  # takes the seat back. Any other exit leaves the train.
  defp drop_rider_ref(train, ref, reason) do
    case Enum.find(train.riders, fn {_id, rider} -> rider.ref == ref end) do
      nil ->
        train

      {id, rider} ->
        if crashed?(reason) and id in train.seats do
          orphan = %{rider | pid: nil, ref: nil, expires_at: now() + rider.grace_ms}
          %{train | riders: Map.put(train.riders, id, orphan)}
        else
          drop_rider(train, id)
        end
    end
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp now, do: System.monotonic_time(:millisecond)
end
