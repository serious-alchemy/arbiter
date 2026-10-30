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

  @doc "End the forming period now (tests; operators)."
  @spec settle_now(GenServer.server()) :: :ok
  def settle_now(server \\ __MODULE__), do: GenServer.call(server, :settle_now)

  @doc "The head and the task ids waiting behind it, in order."
  @spec view(key(), GenServer.server()) :: %{head: String.t() | nil, waiting: [String.t()]}
  def view(key, server \\ __MODULE__), do: GenServer.call(server, {:view, key})

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

    if train.head in [nil, id] do
      {synced_from, entry} = Map.pop(entry, :synced_from)
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
      |> Enum.map(fn {key, train} -> {key, drop_ref(train, ref, reason)} end)
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

  defp new_train, do: %{entries: %{}, head: nil, merge: nil}

  defp empty?(train), do: train.entries == %{} and is_nil(train.merge)

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

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp now, do: System.monotonic_time(:millisecond)
end
