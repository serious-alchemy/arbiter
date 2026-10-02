defmodule Arbiter.Tasks.BacklogTailDigest do
  @moduledoc """
  Daily coordinator digest of the backlog tail (bd-b1b3mp, ES8 of
  `docs/design/epic-aware-scheduling.md` §9).

  Floors and finish-first reorder what is already Ready, but an epic's
  unblocked leaves can sit in Backlog indefinitely, stalling the epic at 90%.
  This lists, per workspace, every unblocked Backlog leaf older than 24h in an
  open epic that has a floor (`:floor_priority`, once the field exists) or is
  in progress (a child closed, running or waiting). It posts one
  `:backlog_tail_digest` message to the coordinator inbox and sends nothing
  when the list is empty.

  **It never promotes.** Promotion stays an operator decision; this module only
  reads tickets and writes a message.

  The ticker wakes hourly and sends only when no digest was posted for the
  workspace in the last 23h, so the cadence survives restarts. Primary instance
  only; disabled in test, where tests call `sweep/1` directly.
  """

  use GenServer

  alias Arbiter.Messages.Escalation
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.EpicRollup
  alias Arbiter.Tasks.Issue

  require Ash.Query
  require Logger

  @tick_ms :timer.hours(1)
  @min_age_s 24 * 3600
  @resend_after_s 23 * 3600
  @max_listed 40

  @type entry :: %{epic_id: String.t(), workspace_id: String.t(), leaves: [Issue.t()]}

  # ---- process -------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:arbiter, :backlog_tail_digest, [])
    enabled? = Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true))
    if enabled?, do: Process.send_after(self(), :tick, :timer.minutes(10))

    {:ok, %{primary?: Keyword.get(opts, :primary?, &Arbiter.SingleInstance.primary?/0)}}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.primary?.(), do: sweep()
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- the digest ----------------------------------------------------------

  @doc """
  One pass: post a digest for each workspace with a non-empty list and no
  digest in the last 23h. Always returns `:ok`. Option: `:now`.
  """
  @spec sweep(keyword()) :: :ok
  def sweep(opts \\ []) do
    opts
    |> collect()
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.each(fn {ws_id, entries} -> post(ws_id, entries) end)
  rescue
    e ->
      Logger.warning("BacklogTailDigest.sweep failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  The stale unblocked Backlog leaves, grouped by qualifying epic (those with at
  least one). Pure read. Option: `:now`.
  """
  @spec collect(keyword()) :: [entry()]
  def collect(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    epics = open_epics()
    rollups = EpicRollup.for_epics(epics, Keyword.take(opts, [:workers, :now]))

    for epic <- epics,
        qualifies?(epic, Map.fetch!(rollups, epic.id)),
        leaves = stale_leaves(epic, now, opts),
        leaves != [] do
      %{epic_id: epic.id, workspace_id: epic.workspace_id, leaves: leaves}
    end
  end

  defp open_epics do
    closed = :closed

    Issue
    |> Ash.Query.filter(issue_type == :epic and state != ^closed)
    |> Ash.read!()
  end

  # A floor, or work already under way (something closed, running or waiting).
  defp qualifies?(epic, rollup) do
    is_integer(Map.get(epic, :floor_priority)) or rollup.closed > 0 or rollup.counts.running > 0 or
      rollup.counts.waiting > 0
  end

  defp stale_leaves(epic, now, opts) do
    epic
    |> EpicRollup.children_with_status(Keyword.take(opts, [:workers, :now]))
    |> Enum.filter(fn %{issue: i, bucket: bucket, blocked?: blocked?} ->
      bucket == :backlog and not blocked? and i.issue_type != :epic and
        DateTime.diff(now, i.created_at, :second) >= @min_age_s
    end)
    |> Enum.map(& &1.issue)
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  defp post(ws_id, entries) do
    if recently_sent?(ws_id) do
      :ok
    else
      total = entries |> Enum.map(&length(&1.leaves)) |> Enum.sum()

      {:ok, _} =
        Escalation.post(%{
          kind: :backlog_tail_digest,
          workspace_id: ws_id,
          subject:
            "backlog tail: #{total} unblocked leaf(s) waiting in Backlog across #{length(entries)} epic(s)",
          body: body(entries)
        })

      :ok
    end
  end

  defp recently_sent?(ws_id) do
    case Message.last_escalation(:backlog_tail_digest, workspace_id: ws_id) do
      nil -> false
      %{inserted_at: at} -> DateTime.diff(DateTime.utc_now(), at, :second) < @resend_after_s
    end
  end

  defp body(entries) do
    sections =
      Enum.map(entries, fn %{epic_id: epic_id, leaves: leaves} ->
        {shown, rest} = Enum.split(leaves, @max_listed)

        lines = Enum.map(shown, &"  - #{&1.id}  #{&1.title}")
        more = if rest == [], do: [], else: ["  - … and #{length(rest)} more"]
        Enum.join(["#{epic_id} (#{length(leaves)}):" | lines ++ more], "\n")
      end)

    Enum.join(
      [
        "Unblocked Backlog leaves older than 24h in epics that are floored or in progress.",
        "Nothing was promoted — promoting them to Ready is your call."
        | sections
      ],
      "\n\n"
    )
  end
end
