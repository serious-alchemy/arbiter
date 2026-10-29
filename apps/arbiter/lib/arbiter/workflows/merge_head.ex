defmodule Arbiter.Workflows.MergeHead do
  @moduledoc """
  The merge-head rule: who may sync a target branch's approved PRs (bd-d4m8qf,
  extended to the auto-merge lane by bd-1754qj).

  The approved PRs heading for one target branch (a workspace, a repo and a base)
  form its *train*. Syncing every one of them whenever the target moves only makes
  each of them stale again at the next merge, at the price of a pipeline each
  time. So one of them, the **head**, is synced and waited on at a time; the rest
  wait without syncing, and the next takes over when the head merges or leaves.

  This module is that rule, as pure functions over *train items*: maps with the
  fields below. Two callers feed it, each with its own source of items and its own
  action once a head is chosen:

    * `Arbiter.Workflows.MergeQueue`, which holds every item itself and acts on
      each train's head per tick (the queue-driven merge lane);
    * `Arbiter.Worker.MergeTrain`, a registry the per-ticket Watchdogs report to,
      one report per poll (the auto-merge lane, where nothing holds the whole
      train).

  Item fields: `task_id`, `status` (`:behind_base` waiting for a sync,
  `:updating_base` its sync is landing, `:ci_running`, `:ready_to_merge`),
  `priority` (0 = P0 highest), `opened_at` (when it became merge-ready; `nil`
  sorts last), `last_block_reason` (a block the forge names on an item in CI),
  `poll_failed?`, `last_head_sha` and `queue_head` (the head's own bookkeeping,
  `nil` on everyone else, see `new_watch/0`).

  ## Hand-off

  The head keeps its place until it merges or leaves the train, even when an
  item ahead of it in queue order joins. A head that cannot progress hands its
  place on after `head_stall_grace_ticks/0` ticks in a row of no progress (CI
  failed or cancelled, the forge names another block, its polls fail, its sync is
  never applied) or `head_ci_wait_ticks/0` ticks in CI on one head SHA. A head
  whose merge was refused (`refused?`) has nothing under way to protect and keeps
  only its queue order.
  """

  # bd-d4m8qf. Ticks a stalled queue head keeps its place before the next item
  # takes over. A block the forge reports right after the head's own sync (no
  # pipeline registered yet, a check about to be re-run) is not a reason to hand
  # its place on; one that outlasts this is.
  @head_stall_grace_ticks 3

  # bd-d4m8qf. Ticks a queue head may sit in CI on one head SHA before it is
  # taken to be waiting on a pipeline that will not finish (a required check
  # that never starts, no runner) and the next item takes over: two hours at the
  # default 30s poll. Generous on purpose: a long pipeline must be allowed to run
  # its course, and handing the place on mid-run wastes it.
  @head_ci_wait_ticks 240

  @type item :: map()

  @doc """
  Ticks a head that cannot progress on its own keeps its place (bd-d4m8qf).
  """
  @spec head_stall_grace_ticks() :: pos_integer()
  def head_stall_grace_ticks, do: @head_stall_grace_ticks

  @doc "Ticks a head may sit in CI on one head SHA before the next takes over."
  @spec head_ci_wait_ticks() :: pos_integer()
  def head_ci_wait_ticks, do: @head_ci_wait_ticks

  @doc """
  The head's own bookkeeping: ticks in a row of no progress, ticks in CI on one
  head SHA, the head SHA it was last synced from, and whether its merge was
  refused last tick.
  """
  @spec new_watch() :: map()
  def new_watch, do: %{stalls: 0, ci_wait: nil, synced_from: nil, refused?: false}

  @doc """
  The train's head, given its items in queue order (`sort/1`), and the incumbent
  handed on this tick with the reason, if any: `{head | nil, handed_on}`.

  The incumbent (the item carrying a `queue_head`) keeps its place unless it
  cannot claim it. Then, or with no incumbent, the front item that can progress
  leads. The returned head carries its `queue_head` watch.
  """
  @spec pick(item_list :: [item()]) :: {item() | nil, {item(), String.t()} | nil}
  def pick(train) do
    case Enum.find(train, &Map.get(&1, :queue_head)) do
      nil -> {front(train), nil}
      %{queue_head: %{refused?: true}} -> {front(train), nil}
      incumbent -> keep_or_hand_on(incumbent, train)
    end
  end

  @doc """
  Queue order: lower priority number first (P0 before P4), earliest `opened_at`
  as the tiebreak. Items without an `opened_at` sort last.
  """
  @spec order_key(item()) :: {integer(), integer()}
  def order_key(item),
    do: {Map.get(item, :priority) || 2, opened_at_key(Map.get(item, :opened_at))}

  @doc "Items in queue order."
  @spec sort([item()]) :: [item()]
  def sort(items), do: Enum.sort_by(items, &order_key/1)

  @doc """
  An item in CI is waiting for its pipeline. One whose forge names a block (CI
  failed or was cancelled, a draft, an unmet approval or branch rule, the PR
  closed) is waiting for something the queue cannot do for it, so it cannot lead.
  """
  @spec stalled?(item()) :: boolean()
  def stalled?(%{status: :ci_running} = item), do: not is_nil(Map.get(item, :last_block_reason))
  def stalled?(_item), do: false

  defp keep_or_hand_on(%{queue_head: watch} = incumbent, train) do
    watch = %{
      watch
      | stalls: if(stuck?(incumbent, watch), do: watch.stalls + 1, else: 0),
        ci_wait: ci_wait(incumbent, watch.ci_wait)
    }

    case hand_on_reason(incumbent, watch) do
      nil ->
        {Map.merge(incumbent, %{queue_head: watch, waiting_for_head: nil}), nil}

      why ->
        {front(Enum.reject(train, &(&1.task_id == incumbent.task_id))), {incumbent, why}}
    end
  end

  defp hand_on_reason(item, %{stalls: stalls}) when stalls > @head_stall_grace_ticks do
    "made no progress for #{stalls} ticks (forge block " <>
      "#{inspect(Map.get(item, :last_block_reason))}, last error #{inspect(Map.get(item, :last_error))})"
  end

  defp hand_on_reason(_item, %{ci_wait: {sha, ticks}}) when ticks > @head_ci_wait_ticks,
    do: "has been in CI on #{inspect(sha)} for #{ticks} ticks"

  defp hand_on_reason(_item, _watch), do: nil

  defp front(train) do
    case Enum.find(train, &(not stalled?(&1))) do
      nil -> nil
      head -> Map.merge(head, %{queue_head: new_watch(), waiting_for_head: nil})
    end
  end

  # No progress since the last tick: stalled, its poll failed, or still behind
  # on the very head it was last synced from (the update-branch failed, or the
  # forge accepted it and never applied it). Judged on this tick's poll, so a
  # head whose CI is re-run keeps its place.
  defp stuck?(item, watch) do
    head = Map.get(item, :last_head_sha)

    stalled?(item) or Map.get(item, :poll_failed?, false) or
      (item.status == :behind_base and is_binary(head) and head == watch.synced_from)
  end

  # Ticks in a row the head has been in CI, with no block named, on its head SHA.
  defp ci_wait(%{status: :ci_running} = item, wait) do
    sha = Map.get(item, :last_head_sha)

    cond do
      stalled?(item) -> nil
      match?({^sha, _}, wait) -> {sha, elem(wait, 1) + 1}
      true -> {sha, 1}
    end
  end

  defp ci_wait(_item, _wait), do: nil

  defp opened_at_key(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp opened_at_key(_), do: 9_223_372_036_854_775_807
end
