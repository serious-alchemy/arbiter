defmodule Arbiter.Loop.Trust do
  @moduledoc """
  Earned trust, computed by the Loop (G18, `docs/design/guardrail-profiles.md`
  §6.2–6.5).

  `tick/1` runs on the canary ticker (`Arbiter.Loop.CanaryTicker`). Each tick
  folds the window's `guardrail_events` and `Arbiter.Loop.SubjectStats` into one
  `Arbiter.Guardrails.TrustRecord` per `(provider, model)` subject
  (`Arbiter.Loop.Trust.Sample` reads, `Arbiter.Loop.Trust.Criteria` judges):
  window counts, recent events, round-1 quality, promotion eligibility, and the
  last harness and model version.

  ## What it does on its own

  Tightening never needs approval (§6.4), so a tick acts by itself — on a
  guarded install only (with no subject rule configured nothing is tiered, and
  writing a rule would switch guardrails on for every other subject):

    * **A critical event suspends the subject.** The suspension is an overlay on
      its rule: `Arbiter.Guardrails.effective/4` treats it as `quarantine` and
      `Arbiter.Guardrails.Eligibility` refuses it every role, every run of it in
      flight is parked (`Arbiter.Worker.park_suspended/2`), and the coordinator
      is paged. The coordinator then confirms (`confirm/2`: the subject drops to
      `quarantine`) or dismisses it as a false positive (`dismiss/3`: its tier
      returns).

  ## Acting once, and not on history

  An event triggers an action once: each record keeps the newest event it has
  folded (`events_watermark`), and only events after it are new. Events recorded
  before the **trust cutover** — when the `trust_records` migration ran
  (`cutover/0`) — count against a subject but never trigger anything, so the
  deploy does not suspend a subject for something that happened before trust
  was watching.
  """

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Guardrails.TrustRecord
  alias Arbiter.Loop.Trust.Criteria
  alias Arbiter.Loop.Trust.Sample
  alias Arbiter.Messages.Escalation
  alias Arbiter.Repo
  alias Arbiter.Worker
  alias Arbiter.Worker.StopReason

  require Ash.Query
  require Logger

  @window_days 30
  @recent_events 10
  @cutover_migration 20_261_010_004_432
  @actor "loop:trust"

  @type subject :: {String.t(), String.t()}

  # ---- reads -------------------------------------------------------------------

  @doc "Every trust record, subject order."
  @spec list() :: [TrustRecord.t()]
  def list do
    TrustRecord
    |> Ash.Query.sort(provider: :asc, model: :asc)
    |> Ash.read!()
  end

  @doc "The record for a subject (`{provider, model}` or `\"provider/model\"`), or `nil`."
  @spec get(subject() | String.t()) :: TrustRecord.t() | nil
  def get(key) when is_binary(key) do
    case parse_subject(key) do
      {:ok, subject} -> get(subject)
      {:error, _} -> nil
    end
  end

  def get({provider, model}) do
    TrustRecord
    |> Ash.Query.filter(provider == ^provider and model == ^model)
    |> Ash.read_one!()
  end

  @doc """
  Parse a subject key, `provider/model` (the first `/` splits them, so a model
  may itself contain one).
  """
  @spec parse_subject(String.t()) :: {:ok, subject()} | {:error, String.t()}
  def parse_subject(text) when is_binary(text) do
    case String.split(String.trim(text), "/", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:ok, {provider, model}}
      _ -> {:error, "a subject is provider/model, e.g. antigravity/gemini-3.8-flash-low"}
    end
  end

  @doc "The `provider/model` key for a subject."
  @spec key(subject() | TrustRecord.t()) :: String.t()
  def key(%TrustRecord{provider: provider, model: model}), do: "#{provider}/#{model}"
  def key({provider, model}), do: "#{provider}/#{model}"

  @doc """
  The trust cutover: when the `trust_records` migration ran on this database
  (`schema_migrations`). Events recorded before it never trigger an automatic
  action. Falls back to the oldest record's creation, then to now.
  """
  @spec cutover() :: DateTime.t()
  def cutover do
    %{rows: rows} =
      Repo.query!("SELECT inserted_at FROM schema_migrations WHERE version = ?1", [
        @cutover_migration
      ])

    case rows do
      [[at]] -> parse_time(at)
      _ -> oldest_record() || DateTime.utc_now()
    end
  end

  defp oldest_record do
    case TrustRecord |> Ash.Query.sort(inserted_at: :asc) |> Ash.Query.limit(1) |> Ash.read!() do
      [%TrustRecord{inserted_at: at}] -> at
      [] -> nil
    end
  end

  # ---- the fold -------------------------------------------------------------

  @doc """
  Fold the window into the trust records and act on what is new.

  Options: `:now`, `:window_days` (#{@window_days}), `:rules` (default
  `Arbiter.Guardrails.Rules.all/0`), `:cutover` (default `cutover/0`) and
  `:workers` (live worker snapshots to park from, default
  `Arbiter.Worker.list_children/0`, read only when a subject is suspended).

  Returns `{:ok, %{records: [record], actions: [action]}}`; an action is a map
  with `:action` (`:suspended`) and `:subject` (the `provider/model` key).
  """
  @spec tick(keyword()) :: {:ok, %{records: [TrustRecord.t()], actions: [map()]}}
  def tick(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    window_days = Keyword.get(opts, :window_days, @window_days)
    rules = Keyword.get_lazy(opts, :rules, &Rules.all/0)
    from = DateTime.add(now, -window_days * 86_400, :second)

    sample = Sample.load(from, now)
    existing = Map.new(list(), &{{&1.provider, &1.model}, &1})

    by_subject = %{
      runs: Enum.group_by(sample.runs, & &1.subject),
      events: Enum.group_by(sample.events, & &1.subject),
      tasks: Enum.group_by(sample.tasks, & &1.subject)
    }

    keys =
      [Map.keys(by_subject.runs), Map.keys(by_subject.events), Map.keys(by_subject.tasks)]
      |> Enum.concat()
      |> Enum.reject(&is_nil/1)
      |> Enum.concat(Map.keys(existing))
      |> Enum.uniq()
      |> Enum.sort()

    rule_of = Map.new(keys, &{&1, match_rule(rules, &1)})
    guarded? = rules != []

    incumbents =
      keys
      |> Enum.map(fn subject ->
        {key(subject), tier_of(rule_of[subject], guarded?),
         Criteria.quality(Map.get(by_subject.tasks, subject, []), nil)}
      end)
      |> Criteria.incumbents()

    ctx = %{
      now: now,
      from: from,
      window_days: window_days,
      guarded?: guarded?,
      incumbents: incumbents,
      cutover: Keyword.get_lazy(opts, :cutover, &cutover/0),
      workers: fn -> Keyword.get_lazy(opts, :workers, &list_workers/0) end
    }

    {records, actions} =
      keys
      |> Enum.map(fn subject ->
        prior = Map.get(existing, subject)
        data = slice(by_subject, subject)
        {state, acted} = fold(subject, prior, rule_of[subject], data, ctx)
        {persist(prior, state), acted}
      end)
      |> Enum.unzip()

    {:ok, %{records: records, actions: List.flatten(actions)}}
  end

  defp slice(by_subject, subject) do
    %{
      runs: Map.get(by_subject.runs, subject, []),
      events: Map.get(by_subject.events, subject, []),
      tasks: Map.get(by_subject.tasks, subject, [])
    }
  end

  defp match_rule(rules, {provider, model}) do
    Rules.match(rules, Guardrails.subject(provider, model))
  end

  defp tier_of(nil, true), do: :quarantine
  defp tier_of(nil, false), do: nil
  defp tier_of(rule, _guarded?), do: rule.tier

  # One subject: its versions and clock, the actions its new events call for,
  # then the counts and the verdict over the clock those actions leave.
  defp fold({provider, model} = subject, prior, rule, data, ctx) do
    tier = tier_of(rule, ctx.guarded?)
    {tier_since, clock} = tier_clock(prior, tier, ctx.now)
    {harness_version, model_version, last_run_at} = versions(data.runs, prior)

    state = %{
      provider: provider,
      model: model,
      family: Guardrails.subject(provider, model).family,
      tier: tier,
      pinned: (rule && Map.get(rule, :pinned)) == true,
      window_days: ctx.window_days,
      harness_version: harness_version,
      model_version: model_version,
      last_run_at: last_run_at,
      clock_started_at: clock,
      tier_since: tier_since,
      suspended_at: prior && prior.suspended_at,
      suspension: prior && prior.suspension,
      last_demoted_at: prior && prior.last_demoted_at,
      history: (prior && prior.history) || [],
      events_watermark: watermark(data.events, prior),
      recent_events: recent_events(data.events),
      computed_at: ctx.now
    }

    {state, acted} =
      if ctx.guarded? and tier != nil,
        do: suspend(state, subject, prior, data, ctx),
        else: {state, []}

    {judge(state, subject, prior, data, ctx), acted}
  end

  # Counts, quality and the §6.3 verdict, over the promotion clock the actions
  # left behind.
  defp judge(state, subject, prior, data, ctx) do
    window_start = later(ctx.from, state.clock_started_at)
    counts = Criteria.run_counts(data.runs, data.events, data.tasks, window_start)
    {critical, major, minor} = Criteria.event_counts(data.events)
    quality = Criteria.quality(data.tasks, window_start)

    facts =
      Map.merge(counts, %{
        key: key(subject),
        critical_events: critical,
        major_events: major,
        quality: quality,
        days_at_tier:
          days_since(state.tier_since || (prior && prior.inserted_at) || ctx.now, ctx.now),
        pinned: state.pinned,
        suspended: state.suspended_at != nil,
        incumbents: ctx.incumbents
      })

    {eligible_for, eligibility} = Criteria.eligibility(state.tier, facts)

    Map.merge(state, %{
      runs: counts.runs,
      clean_runs: counts.clean_runs,
      clean_tickets: counts.clean_tickets,
      clean_repos: counts.clean_repos,
      critical_events: critical,
      major_events: major,
      minor_events: minor,
      reviewed: quality.reviewed,
      round1_approve_rate: quality.q,
      quality: %{"bands" => quality.bands, "since" => iso(window_start)},
      eligible_for: eligible_for,
      eligibility: eligibility
    })
  end

  # ---- suspension --------------------------------------------------------------

  # A critical event newer than both the cutover and what the record has already
  # folded suspends the subject. While suspended, more criticals are added to the
  # suspension without a second page.
  defp suspend(state, subject, prior, data, ctx) do
    since = later(ctx.cutover, prior && prior.events_watermark)

    criticals =
      data.events
      |> Enum.filter(&(&1.severity == "critical" and after?(&1.inserted_at, since)))
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    cond do
      criticals == [] ->
        {state, []}

      state.suspended_at != nil ->
        ids = Map.get(state.suspension || %{}, "events", []) ++ Enum.map(criticals, & &1.id)
        {%{state | suspension: Map.put(state.suspension || %{}, "events", ids)}, []}

      true ->
        [event | _] = criticals
        parked = park(subject, event, ctx)

        suspension =
          event
          |> event_entry()
          |> Map.take(~w(id kind severity source detail run_id task_id at))
          |> Map.put("prior_tier", to_string(state.tier))
          |> Map.put("events", Enum.map(criticals, & &1.id))
          |> Map.put("parked", parked)

        page_suspended(subject, state.tier, event, parked)

        state =
          %{
            state
            | suspended_at: ctx.now,
              suspension: suspension,
              history:
                state.history ++
                  [
                    history(ctx.now, "suspended", @actor, %{
                      "event_id" => event.id,
                      "kind" => event.kind,
                      "tier" => to_string(state.tier)
                    })
                  ]
          }

        {state, [%{action: :suspended, subject: key(subject), event: event.id, parked: parked}]}
    end
  end

  # Every live run of the subject, implementer or reviewer, is parked.
  defp park(subject, event, ctx) do
    reason =
      StopReason.trust_suspended(%{subject: key(subject), kind: event.kind, run_id: event.run_id})

    for snap <- ctx.workers.(),
        Map.get(snap, :agent_live) == true,
        snapshot_subject(snap) == subject,
        Worker.park_suspended(snap.pid, reason) == :ok,
        do: snap.task_id
  end

  defp snapshot_subject(%{meta: %{} = meta}) do
    case Map.get(meta, :guardrail_decision) do
      %{"subject" => %{"provider" => provider, "model" => model}}
      when is_binary(provider) and is_binary(model) ->
        {provider, model}

      _ ->
        Sample.adapter_subject(Worker.provider(meta), Map.get(meta, :model), Sample.harness_map())
    end
  end

  defp snapshot_subject(_snap), do: nil

  defp list_workers do
    Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ---- pages -------------------------------------------------------------------

  defp page_suspended(subject, tier, event, parked) do
    k = key(subject)

    page(
      :trust_suspended,
      "trust: #{k} suspended after a critical guardrail event (#{event.kind})",
      """
      #{k} (tier #{tier}) had a critical guardrail event and is suspended: it is treated as quarantine and takes no work in any role until you decide.

      Event:   #{event.kind} (#{event.severity}, #{event.source}) on run #{event.run_id || "?"}, ticket #{event.task_id || "?"}
      Detail:  #{event.detail || "—"}
      Parked:  #{if parked == [], do: "no run of it was in flight", else: Enum.join(parked, ", ")}

      Decide with:

          arb trust confirm #{k}                       # the demotion to quarantine stands
          arb trust dismiss #{k} --reason "..."        # a false positive: the #{tier} tier returns

      `arb trust show #{k}` has the record.
      """
    )
  end

  defp page(kind, subject, body) do
    with {:ok, ws_id} <- Arbiter.Tasks.Workspaces.default_id(),
         {:ok, _message} <-
           Escalation.post(%{
             kind: kind,
             workspace_id: ws_id,
             from_ref: @actor,
             subject: subject,
             body: body
           }) do
      :ok
    else
      other ->
        Logger.warning("Loop.Trust: #{kind} page not posted: #{inspect(other)}")
        :skipped
    end
  rescue
    e ->
      Logger.warning("Loop.Trust: #{kind} page not posted: #{Exception.message(e)}")
      :skipped
  end

  # ---- record pieces -------------------------------------------------------------

  # A tier change (seen against the last fold) restarts the clock; so does the
  # first time a subject gets a tier at all.
  defp tier_clock(nil, _tier, _now), do: {nil, nil}

  defp tier_clock(%TrustRecord{tier: tier} = prior, tier, _now),
    do: {prior.tier_since, prior.clock_started_at}

  defp tier_clock(_prior, nil, _now), do: {nil, nil}
  defp tier_clock(_prior, _tier, now), do: {now, now}

  # The newest run's harness version and reported model; a run that recorded no
  # version keeps the last one known.
  defp versions([], nil), do: {nil, nil, nil}
  defp versions([], prior), do: {prior.harness_version, prior.model_version, prior.last_run_at}

  defp versions(runs, prior) do
    latest = Enum.max_by(runs, & &1.started_at, DateTime)

    {latest.harness_version || (prior && prior.harness_version),
     latest.model || (prior && prior.model_version), latest.started_at}
  end

  defp watermark(events, prior) do
    [prior && prior.events_watermark | Enum.map(events, & &1.inserted_at)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp recent_events(events) do
    events
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(@recent_events)
    |> Enum.map(&event_entry/1)
  end

  defp event_entry(event) do
    %{
      "id" => event.id,
      "kind" => event.kind,
      "severity" => event.severity,
      "source" => event.source,
      "tool" => event.tool,
      "detail" => event.detail,
      "run_id" => event.run_id,
      "task_id" => event.task_id,
      "at" => iso(event.inserted_at)
    }
  end

  defp history(now, action, actor, extra),
    do: Map.merge(%{"at" => iso(now), "action" => action, "actor" => actor}, extra)

  defp persist(nil, attrs), do: Ash.create!(TrustRecord, attrs)

  defp persist(%TrustRecord{} = prior, attrs),
    do: Ash.update!(prior, Map.drop(attrs, [:provider, :model]))

  # ---- time ----------------------------------------------------------------------

  defp later(a, nil), do: a
  defp later(nil, b), do: b
  defp later(a, b), do: if(DateTime.compare(b, a) == :gt, do: b, else: a)

  defp after?(%DateTime{} = dt, %DateTime{} = since), do: DateTime.compare(dt, since) == :gt
  defp after?(_dt, _since), do: false

  defp days_since(%DateTime{} = then, now), do: max(DateTime.diff(now, then, :day), 0)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_time(%DateTime{} = dt), do: dt
  defp parse_time(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> text |> NaiveDateTime.from_iso8601!() |> parse_time()
    end
  end
end
