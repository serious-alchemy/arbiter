defmodule Arbiter.Tasks.AttentionSweep do
  @moduledoc """
  Moves a coordinator-owned attention item the coordinator left unresolved
  past its limit to the operator (ticket lifecycle 7/13, bd-8nlez1).

  Every tick it reads the coordinator's queue
  (`Arbiter.Tasks.Attention.items(owner: :coordinator)`) and promotes each item
  that is past one of its workspace's limits (`Arbiter.Tasks.AttentionLimits`):

    * **time** — unresolved for `attention.coordinator_limit_minutes`, counted
      from when it was raised (`attention.since`), or from the hand-back that
      gave it back to the coordinator if that came later. A derived item has no
      stored `since`; its clock starts when this sweep first sees it, and is
      forgotten when the item goes (a restart starts it again);
    * **attempts** — a `run_crashed` item whose ticket was already resumed
      `attention.run_crashed_max_resumes` times out of a failed run while in
      its state (`Issue.attention_resume_attempts`).

  A promotion sets the owner to `:operator` with the note "coordinator did not
  resolve within <limit>" (`Arbiter.Tasks.Attention.promote/3`), which the
  ticket's attention, `ticket_show` and the dashboard show, and announces
  `promoted` on the `inbox` topic. A derived item seen for the first time is
  announced `raised` — nothing else raised it — so the coordinator wakes for it
  as for a stored one. The first sweep of a process is a baseline, not news
  (bd-9jipdh): the items it finds were there before this boot, so it records
  their clocks without announcing them, and only items that appear after it
  raise. Otherwise every restart would re-raise every ticket awaiting
  verification.

  An `awaiting_verification` item is exempt from the time limit: it waits on
  a restart-and-observe, which the coordinator cannot hurry and the operator
  cannot do any faster, so promoting it after 4 h only moves noise into the
  operator's swimlane. It has no verify-specific window; it stays with the
  coordinator until the verification is recorded.

  Each sweep also records the derived items as attention spans (bd-cq1wsp,
  `Arbiter.Tasks.AttentionSpans.sync_derived/3`): it reads every owner's items,
  opens a span for a derived one on first sight and closes it once the item is
  gone. Those spans live in the database, so unlike the first-seen clock they
  survive a restart. The baseline sweep records them too — the span opens at
  the first sighting this process could make.

  `run/1` is one sweep, with an injectable clock (`:now`) and first-seen map
  (`:seen`), and is what the tests drive. Only the primary instance sweeps.

  ## Configuration

  Via `config :arbiter, :attention_sweep`: `:enabled` (default `true`; `false`
  in test) and `:interval_ms` (default 60 000). `start_link/1` also takes
  `:primary?` and `:clock` (zero-arity funs, for tests).
  """

  use GenServer

  require Logger

  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.AttentionLimits
  alias Arbiter.Tasks.AttentionSpans
  alias Arbiter.Tasks.Workspace

  @default_interval_ms 60_000

  @type seen :: %{{String.t(), atom()} => DateTime.t()}
  @type summary :: %{promoted: [String.t()], seen: seen()}

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  One sweep. Opts: `:now` (default now), `:seen` (the first-seen clock of the
  derived items, from the previous sweep; default empty), and the
  `Attention.items/1` opts (`:workers`, `:issues`, `:workspace_id`), and
  `:announce` (default `true`; `false` records first-seen clocks without
  announcing — the boot baseline).

  Returns the promoted ticket ids and the `seen` map for the next sweep.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    seen = Keyword.get(opts, :seen, %{})

    all_items =
      opts
      |> Keyword.take([:workers, :issues, :workspace_id])
      |> Keyword.merge(now: now)
      |> Attention.items()

    AttentionSpans.sync_derived(all_items, span_scope(opts), now)

    items = Enum.filter(all_items, &(&1.attention.owner == :coordinator))
    seen = track(items, seen, now, Keyword.get(opts, :announce, true))
    limits = limits_by_workspace(items)

    promoted =
      Enum.flat_map(items, fn item ->
        case over_limit(item, Map.fetch!(limits, item.workspace_id), seen, now) do
          nil -> []
          note -> if promote(item, note), do: [item.ticket_id], else: []
        end
      end)

    %{promoted: promoted, seen: seen}
  end

  @doc """
  The note for `item` if it is past a limit in `limits`, else nil. Pure; see
  the moduledoc for the rules.
  """
  @spec over_limit(Attention.item(), AttentionLimits.t(), seen(), DateTime.t()) ::
          String.t() | nil
  def over_limit(%{attention: attention, ticket: ticket} = item, limits, seen, now) do
    cond do
      attention.cause == :run_crashed and limits.max_resumes > 0 and
          (ticket.attention_resume_attempts || 0) >= limits.max_resumes ->
        "coordinator did not resolve within #{limits.max_resumes} resume attempts"

      attention.cause == :awaiting_verification ->
        nil

      limits.minutes > 0 and
          DateTime.diff(now, clock_start(item, seen, now), :second) >= limits.minutes * 60 ->
        "coordinator did not resolve within #{AttentionLimits.describe_minutes(limits.minutes)}"

      true ->
        nil
    end
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    cfg = Application.get_env(:arbiter, :attention_sweep, [])

    state = %{
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true)),
      interval_ms:
        Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, @default_interval_ms)),
      seen: %{},
      primed?: false,
      primary?: Keyword.get(opts, :primary?, &Arbiter.SingleInstance.primary?/0),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    state =
      if state.primary?.() do
        %{seen: seen} = run(seen: state.seen, now: state.clock.(), announce: state.primed?)
        %{state | seen: seen, primed?: true}
      else
        state
      end

    schedule(state.interval_ms)
    {:noreply, state}
  rescue
    e ->
      Logger.warning("AttentionSweep: sweep failed: #{Exception.message(e)}")
      schedule(state.interval_ms)
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)

  # ---- sweep ----------------------------------------------------------------

  # What this sweep read, so the span sync closes only what it looked at.
  defp span_scope(opts) do
    cond do
      issues = Keyword.get(opts, :issues) -> {:tickets, Enum.map(issues, & &1.id)}
      ws_id = Keyword.get(opts, :workspace_id) -> {:workspace, ws_id}
      true -> :all
    end
  end

  # The first-seen clock of the derived items still listed; a stored item
  # carries its own `since`. A derived item new to the map is announced.
  defp track(items, seen, now, announce?) do
    Map.new(items |> Enum.filter(&is_nil(&1.attention.since)), fn item ->
      key = {item.ticket_id, item.attention.cause}

      case Map.fetch(seen, key) do
        {:ok, at} ->
          {key, at}

        :error ->
          if announce?, do: Attention.announce(item.ticket, :raised, item.attention)
          {key, now}
      end
    end)
  end

  defp clock_start(%{attention: attention, ticket_id: id}, seen, now) do
    raised = attention.since || Map.get(seen, {id, attention.cause}, now)

    case attention.owner_since do
      %DateTime{} = handed_back -> Enum.max([raised, handed_back], DateTime)
      _ -> raised
    end
  end

  defp limits_by_workspace(items) do
    items
    |> Enum.map(& &1.workspace_id)
    |> Enum.uniq()
    |> Map.new(fn ws_id -> {ws_id, AttentionLimits.for_workspace(workspace(ws_id))} end)
  end

  defp workspace(nil), do: nil

  defp workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp promote(item, note) do
    case Attention.promote(item.ticket, item.attention.cause, note) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("AttentionSweep: could not promote #{item.ticket_id}: #{inspect(reason)}")
        false
    end
  end
end
