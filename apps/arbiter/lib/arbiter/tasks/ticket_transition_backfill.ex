defmodule Arbiter.Tasks.TicketTransitionBackfill do
  @moduledoc """
  The one-off backfill of `ticket_transitions` from the paper trail (bd-d8fi92;
  reports design v2, `docs/design/reports-design-v2.md` §3.4). Each ticket's
  `issues_versions` are replayed by `Arbiter.Tasks.Lifecycle.History` and
  written as `source: "backfill"` rows.

  Runs on every boot of the primary instance (`Arbiter.Boot.TicketTransitions`,
  which applies it) and by hand through `Arbiter.Release.backfill/2`
  (`:ticket_transitions`, a dry run unless `apply?: true`) or
  `mix arbiter.backfill_ticket_transitions`.

  ## Which tickets

  A ticket is **pending** until its history has a start: a `create` row (every
  ticket created since the `ticket_transitions` triggers shipped has a live
  one) or a backfilled row. A pending ticket with no rows gets its whole
  replayed history. A pending ticket that already has live rows — it
  transitioned between the triggers' deploy and this backfill — gets only the
  history *before* its first live row: versions at or after that row's `at`
  are left out (the paper trail stamps a transition's version a moment after
  the state write the trigger recorded), and the replay must end in that row's
  `from_state`. Nothing is ever overwritten, so a second run plans nothing.

  ## The check

  The replay's final state must equal the stored `issues.state` (or the first
  live row's `from_state`). A mismatch is logged and, when applied, closed by
  one `source: "backfill_reconcile"` row named `reconcile`, at the replay's
  last transition (the ticket's `created_at` when there was none, so a ticket
  with no paper trail enters the history at its creation) — so a ticket's last
  row always ends in its state. Unknown `status` / `state` values and era-B/C
  pairs outside the lifecycle table are reported, never fatal.

  `cfd` checks the cumulative-flow invariant (§3.3) over the existing rows
  plus the plan: on each sample day, the tickets the history places in a band
  must be the tickets created by then.

  ## Writes

  One `BEGIN IMMEDIATE` transaction per ticket that re-checks the ticket is
  still pending as planned before it inserts, so a concurrent run (a manual
  eval beside a booting node) or a live transition in between skips it
  (`raced`) instead of duplicating; the next run picks it up.
  """

  require Logger

  alias Arbiter.Repo
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Lifecycle.History
  alias Arbiter.Tasks.TicketTransition

  # Migration 20260824170000 added `refined`; 20260927184052 added `state`.
  @refined_migration 20_260_824_170_000
  @state_migration 20_260_927_184_052

  @states Map.new(Lifecycle.states(), &{Atom.to_string(&1), &1})
  @close_reasons Map.new(Lifecycle.close_reasons(), &{Atom.to_string(&1), &1})

  # A version that can move state: the creation, or one carrying a state key
  # or a derivation input. A prefilter only — the JSON is decoded after.
  @versions_sql """
  SELECT version_source_id, version_action_name, version_inserted_at, changes
  FROM issues_versions
  WHERE version_action_name = 'create'
     OR changes LIKE '%"state"%'
     OR changes LIKE '%"status"%'
     OR changes LIKE '%"refined"%'
     OR changes LIKE '%"pr_ref"%'
     OR changes LIKE '%"pending_merge"%'
     OR changes LIKE '%"close_reason"%'
  ORDER BY version_source_id, version_inserted_at, id
  """

  @started """
  EXISTS (SELECT 1 FROM ticket_transitions s
          WHERE s.ticket_id = i.id AND (s.transition = 'create' OR s.source <> 'live'))
  """

  @first_row "FROM ticket_transitions f WHERE f.ticket_id = i.id ORDER BY f.at, f.rowid LIMIT 1"

  @pending_sql """
  SELECT i.id, i.workspace_id, i.repo, i.state, i.close_reason, i.created_at,
         (SELECT f.at #{@first_row}), (SELECT f.from_state #{@first_row})
  FROM issues i
  WHERE NOT #{@started}
  ORDER BY i.created_at, i.id
  """

  @recheck_sql """
  SELECT #{@started}, (SELECT f.at #{@first_row})
  FROM issues i WHERE i.id = ?1
  """

  @type mismatch :: %{
          ticket_id: String.t(),
          replayed: Lifecycle.state() | nil,
          stored: Lifecycle.state()
        }

  @type result :: %{
          apply?: boolean(),
          tickets: non_neg_integer(),
          pending: non_neg_integer(),
          versions: non_neg_integer(),
          planned: non_neg_integer(),
          inserted: non_neg_integer(),
          raced: non_neg_integer(),
          failed: non_neg_integer(),
          mismatches: [mismatch()],
          unmapped: [map()],
          illegal: [map()],
          cutovers: %{refined_cutover: DateTime.t() | nil, state_cutover: DateTime.t() | nil},
          cfd: [%{day: Date.t(), banded: non_neg_integer(), created: non_neg_integer()}]
        }

  @doc """
  Plan the backfill and, with `apply?: true`, write it.

  Opts: `:apply?` (default `false`); `:refined_cutover` / `:state_cutover`
  (`DateTime` or `nil`, default `cutovers/0`); `:cfd_days` (the `Date`s to
  check the CFD invariant on; default the first of every month since the
  oldest ticket, plus today).
  """
  @spec backfill(keyword()) :: result()
  def backfill(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)
    cutovers = Map.merge(cutovers(), Map.new(Keyword.take(opts, [:refined_cutover, :state_cutover])))
    pending = load_pending()

    result = %{
      apply?: apply?,
      tickets: count_tickets(),
      pending: length(pending),
      versions: 0,
      planned: 0,
      inserted: 0,
      raced: 0,
      failed: 0,
      mismatches: [],
      unmapped: [],
      illegal: [],
      cutovers: cutovers,
      cfd: []
    }

    if pending == [] do
      result
    else
      run(pending, result, opts)
    end
  end

  @doc """
  This install's cutovers: when the `refined` migration (`20260824170000`)
  and the `state` migration (`20260927184052`) were applied, from
  `schema_migrations`; `nil` for one that is not recorded.
  """
  @spec cutovers() :: %{refined_cutover: DateTime.t() | nil, state_cutover: DateTime.t() | nil}
  def cutovers do
    %{rows: rows} =
      Repo.query!("SELECT version, inserted_at FROM schema_migrations WHERE version IN (?1, ?2)", [
        @refined_migration,
        @state_migration
      ])

    applied = Map.new(rows, fn [version, at] -> {version, parse(at)} end)

    %{
      refined_cutover: Map.get(applied, @refined_migration),
      state_cutover: Map.get(applied, @state_migration)
    }
  end

  # ---- plan ------------------------------------------------------------------

  defp run(pending, result, opts) do
    ids = MapSet.new(pending, & &1.id)
    versions = load_versions(ids)
    plans = Enum.map(pending, &plan(&1, Map.get(versions, &1.id, []), result.cutovers))

    result = %{
      result
      | versions: versions |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
        planned: plans |> Enum.map(&length(&1.rows)) |> Enum.sum(),
        mismatches: for(%{mismatch: %{} = m} <- plans, do: m),
        unmapped: Enum.flat_map(plans, & &1.unmapped),
        illegal: Enum.flat_map(plans, & &1.illegal),
        cfd: cfd(plans, Keyword.get(opts, :cfd_days))
    }

    result = if result.apply?, do: write(plans, result), else: result
    report(result)
    result
  end

  defp plan(ticket, versions, cutovers) do
    first_live = ticket.first_live

    versions =
      if first_live,
        do: Enum.filter(versions, &(DateTime.compare(&1.at, first_live.at) == :lt)),
        else: versions

    replay =
      History.replay(versions,
        created_at: ticket.created_at,
        refined_cutover: cutovers.refined_cutover,
        state_cutover: cutovers.state_cutover
      )

    target = (first_live && first_live.from_state) || ticket.state
    transitions = replay.transitions ++ reconcile(ticket, replay, target)
    tag = &Map.put(&1, :ticket_id, ticket.id)

    %{
      ticket: ticket,
      rows: Enum.map(transitions, &row(ticket, &1)),
      mismatch:
        if(replay.state != target,
          do: %{ticket_id: ticket.id, replayed: replay.state, stored: target}
        ),
      unmapped: Enum.map(replay.unmapped, tag),
      illegal: Enum.map(replay.illegal, tag)
    }
  end

  defp reconcile(_ticket, %{state: target}, target), do: []

  defp reconcile(ticket, replay, target) do
    at =
      case List.last(replay.transitions) do
        %{at: at} -> at
        nil -> ticket.created_at
      end

    # Before the first live row, whose from_state this is.
    at =
      case ticket.first_live do
        %{at: live_at} -> Enum.min([at, DateTime.add(live_at, -1, :microsecond)], DateTime)
        nil -> at
      end

    close_reason =
      if target == :closed,
        do: (ticket.first_live == nil && ticket.close_reason) || :completed

    [
      %{
        from_state: replay.state,
        to_state: target,
        transition: "reconcile",
        close_reason: close_reason,
        at: at,
        source: "backfill_reconcile"
      }
    ]
  end

  defp row(ticket, transition) do
    %{
      id: Ash.UUIDv7.generate(),
      ticket_id: ticket.id,
      workspace_id: ticket.workspace_id,
      repo: ticket.repo,
      from_state: transition.from_state,
      to_state: transition.to_state,
      transition: transition.transition,
      close_reason: transition.close_reason,
      at: usec(transition.at),
      source: Map.get(transition, :source, "backfill"),
      origin: nil
    }
  end

  # ---- write -----------------------------------------------------------------

  defp write(plans, result) do
    Enum.reduce(plans, result, fn plan, acc ->
      case write_ticket(plan) do
        {:ok, n} ->
          %{acc | inserted: acc.inserted + n}

        :raced ->
          %{acc | raced: acc.raced + 1}

        {:error, reason} ->
          Logger.error(
            "TicketTransitionBackfill: #{plan.ticket.id} not written: #{Exception.format(:error, reason)}"
          )

          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp write_ticket(%{ticket: ticket, rows: rows}) do
    Repo.transaction(
      fn ->
        if still_pending?(ticket) do
          {n, _} = Repo.insert_all(TicketTransition, rows)
          {:ok, n}
        else
          :raced
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp still_pending?(ticket) do
    %{rows: [[started, first_at]]} = Repo.query!(@recheck_sql, [ticket.id])
    planned_first_at = ticket.first_live && ticket.first_live.at
    started in [0, false] and parse(first_at) == planned_first_at
  end

  # ---- the CFD check ---------------------------------------------------------

  # Every ticket sits in exactly one band from its first row on, so Σ bands
  # on a day is the tickets whose history has started by then.
  defp cfd(plans, days) do
    %{rows: rows} =
      Repo.query!("""
      SELECT i.id, i.created_at, (SELECT min(t.at) FROM ticket_transitions t WHERE t.ticket_id = i.id)
      FROM issues i
      """)

    planned = Map.new(plans, fn plan -> {plan.ticket.id, plan.rows |> Enum.map(& &1.at) |> min_at()} end)

    tickets =
      for [id, created_at, first_at] <- rows do
        {parse(created_at), min_at(Enum.reject([parse(first_at), planned[id]], &is_nil/1))}
      end

    days = days || default_days(tickets)

    for day <- days do
      day_end = DateTime.new!(day, ~T[23:59:59.999999])
      by? = &(&1 != nil and DateTime.compare(&1, day_end) != :gt)

      %{
        day: day,
        banded: Enum.count(tickets, fn {_created, first} -> by?.(first) end),
        created: Enum.count(tickets, fn {created, _first} -> by?.(created) end)
      }
    end
  end

  defp min_at([]), do: nil
  defp min_at(ats), do: Enum.min(ats, DateTime)

  defp default_days(tickets) do
    today = Date.utc_today()

    case tickets |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> min_at() do
      nil ->
        [today]

      oldest ->
        oldest
        |> DateTime.to_date()
        |> Date.beginning_of_month()
        |> Stream.iterate(&(&1 |> Date.end_of_month() |> Date.add(1)))
        |> Enum.take_while(&(Date.compare(&1, today) != :gt))
        |> Kernel.++([today])
        |> Enum.uniq()
    end
  end

  # ---- report ----------------------------------------------------------------

  defp report(result) do
    for m <- result.mismatches do
      Logger.warning(
        "TicketTransitionBackfill: #{m.ticket_id} replays to #{inspect(m.replayed)} " <>
          "but is stored #{inspect(m.stored)} — #{if result.apply?, do: "reconciled", else: "would reconcile"}"
      )
    end

    for u <- result.unmapped do
      Logger.warning(
        "TicketTransitionBackfill: #{u.ticket_id} has an unmapped #{u.key} #{inspect(u.value)} at #{DateTime.to_iso8601(u.at)}"
      )
    end

    for t <- result.illegal do
      Logger.warning(
        "TicketTransitionBackfill: #{t.ticket_id} has an illegal transition " <>
          "#{t.from_state} → #{t.to_state} at #{DateTime.to_iso8601(t.at)}"
      )
    end

    for %{banded: b, created: c} = d <- result.cfd, b != c do
      Logger.warning("TicketTransitionBackfill: CFD on #{d.day}: #{b} tickets banded, #{c} created")
    end

    Logger.info(
      "TicketTransitionBackfill: #{result.pending} of #{result.tickets} ticket(s) pending, " <>
        "#{result.planned} row(s) planned, #{result.inserted} inserted, " <>
        "#{length(result.mismatches)} mismatch(es), #{result.raced} raced, #{result.failed} failed"
    )
  end

  # ---- load ------------------------------------------------------------------

  defp count_tickets do
    %{rows: [[n]]} = Repo.query!("SELECT COUNT(*) FROM issues")
    n
  end

  defp load_pending do
    %{rows: rows} = Repo.query!(@pending_sql)

    for [id, workspace_id, repo, state, close_reason, created_at, first_at, first_from] <- rows do
      %{
        id: id,
        workspace_id: workspace_id,
        repo: repo,
        state: Map.fetch!(@states, state),
        close_reason: Map.get(@close_reasons, close_reason),
        created_at: parse(created_at),
        first_live: first_at && %{at: parse(first_at), from_state: Map.get(@states, first_from)}
      }
    end
  end

  defp load_versions(ids) do
    %{rows: rows} = Repo.query!(@versions_sql)

    rows
    |> Enum.filter(fn [id | _] -> MapSet.member?(ids, id) end)
    |> Enum.flat_map(fn [id, action, at, changes] ->
      case Jason.decode(changes || "{}") do
        {:ok, %{} = changes} -> [{id, %{action: action, at: parse(at), changes: changes}}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp parse(nil), do: nil
  defp parse(%DateTime{} = dt), do: usec(dt)
  defp parse(%NaiveDateTime{} = naive), do: naive |> DateTime.from_naive!("Etc/UTC") |> usec()

  defp parse(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> usec(dt)
      {:error, _} -> text |> NaiveDateTime.from_iso8601!() |> parse()
    end
  end

  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
