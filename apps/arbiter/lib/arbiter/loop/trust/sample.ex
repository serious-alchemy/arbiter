defmodule Arbiter.Loop.Trust.Sample do
  @moduledoc """
  What `Arbiter.Loop.Trust` folds, read for one window (G18,
  `docs/design/guardrail-profiles.md` §6.5): the window's runs, its guardrail
  events and `Arbiter.Loop.SubjectStats`' task records, each attributed to the
  `(provider, model)` subject it belongs to.

  **A run's subject is the one it was dispatched as.** A guarded dispatch
  records the subject its tier was judged for in `worker_runs.guardrail_decision`,
  and that is the run's subject. A run without one is its own `provider` (the
  adapter type, mapped to the harness by `Arbiter.Guardrails.subject/2`, so a
  `gemini` adapter running agy is `antigravity`) and `model`. An event belongs to
  its run's subject, and a SubjectStats task to its first attempt's; either falls
  back to its own provider and model when its run is unknown.

  Reads follow the `Arbiter.Loop.Canary.Metrics` discipline: raw `Repo.query!/2`,
  bound parameters, `IN` lists chunked.
  """

  alias Arbiter.Guardrails
  alias Arbiter.Loop.SubjectStats
  alias Arbiter.Repo
  alias Arbiter.Usage.Estimate

  # SQLite's default parameter ceiling is 999.
  @chunk 200

  @type subject :: {String.t(), String.t()}

  @type run :: %{
          id: String.t(),
          task_id: String.t(),
          kind: String.t() | nil,
          role: String.t() | nil,
          model: String.t() | nil,
          repo: String.t() | nil,
          workspace_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          stop_category: String.t() | nil,
          failure_reason: String.t() | nil,
          harness_version: String.t() | nil,
          subject: subject() | nil
        }

  @type event :: %{
          id: String.t(),
          run_id: String.t() | nil,
          task_id: String.t() | nil,
          workspace_id: String.t() | nil,
          kind: String.t(),
          severity: String.t(),
          source: String.t() | nil,
          tool: String.t() | nil,
          detail: String.t() | nil,
          inserted_at: DateTime.t(),
          subject: subject() | nil
        }

  @type t :: %{runs: [run()], events: [event()], tasks: [map()]}

  @doc """
  The runs started and events recorded in `[from, now)`, and SubjectStats' tasks
  whose first attempt started in it. Every element carries its `:subject`.
  """
  @spec load(DateTime.t(), DateTime.t()) :: t()
  def load(%DateTime{} = from, %DateTime{} = now) do
    harness = harness_map()

    runs = Enum.map(runs_in(from, now), &to_run(&1, harness))
    by_id = Map.new(runs, &{&1.id, &1})

    raw_events = events_in(from, now)

    outside =
      raw_events
      |> Enum.map(& &1["run_id"])
      |> Enum.reject(&(is_nil(&1) or Map.has_key?(by_id, &1)))
      |> runs_by_id()
      |> Map.new(fn row -> {row["id"], to_run(row, harness)} end)

    known = Map.merge(outside, by_id)

    tasks =
      [now: now, from: from, until: now, half_life_days: nil]
      |> SubjectStats.sample()
      |> Enum.map(fn task ->
        Map.put(
          task,
          :subject,
          subject_of(known[task.run_id], task.provider, task.model, harness)
        )
      end)

    %{
      runs: runs,
      events:
        Enum.map(raw_events, fn row ->
          run = known[row["run_id"]]
          to_event(row, subject_of(run, row["provider"], row["model"], harness), run)
        end),
      tasks: tasks
    }
  end

  @doc """
  The subject for a run row (`worker_runs` columns, string keys): its dispatch
  decision's subject when it recorded one, else its own provider and model.
  `harness` maps an adapter provider to the harness name (`harness_map/0`).
  """
  @spec run_subject(map(), %{optional(String.t()) => String.t()}) :: subject() | nil
  def run_subject(row, harness \\ %{}) do
    case decision_subject(row["guardrail_decision"]) do
      {provider, nil} ->
        adapter_subject(provider, row["model"], harness)

      {provider, model} ->
        {provider, model}

      nil ->
        adapter_subject(row["provider"] || infer_provider(row["model"]), row["model"], harness)
    end
  end

  @doc """
  `{provider, model}` for an adapter provider and model, with the provider
  mapped to its harness (`gemini` → `antigravity` where agy is the installed
  CLI). `nil` when either is unknown.
  """
  @spec adapter_subject(String.t() | nil, String.t() | nil, map()) :: subject() | nil
  def adapter_subject(provider, model, harness \\ %{})
  def adapter_subject(nil, _model, _harness), do: nil
  def adapter_subject(_provider, nil, _harness), do: nil
  def adapter_subject("", _model, _harness), do: nil
  def adapter_subject(_provider, "", _harness), do: nil

  def adapter_subject(provider, model, harness) do
    {Map.get_lazy(harness, provider, fn -> Guardrails.subject(provider, model).provider end),
     model}
  end

  @doc """
  Adapter provider → harness provider, resolved once per fold:
  `Arbiter.Guardrails.subject/2` probes `PATH` for the `gemini` adapter.
  """
  @spec harness_map() :: %{String.t() => String.t()}
  def harness_map do
    Map.new(~w(claude codex gemini grok antigravity), fn p ->
      {p, Guardrails.subject(p, nil).provider}
    end)
  end

  defp subject_of(%{subject: subject}, _provider, _model, _harness) when subject != nil,
    do: subject

  defp subject_of(_run, provider, model, harness),
    do: adapter_subject(provider || infer_provider(model), model, harness)

  defp decision_subject(nil), do: nil

  defp decision_subject(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decision} -> decision_subject(decision)
      _ -> nil
    end
  end

  defp decision_subject(%{"subject" => %{"provider" => provider} = subject})
       when is_binary(provider) and provider != "" do
    case subject["model"] do
      model when is_binary(model) and model != "" -> {provider, model}
      _ -> {provider, nil}
    end
  end

  defp decision_subject(_), do: nil

  # The same inference `Arbiter.Loop.SubjectStats` applies to rows that recorded
  # no provider (they predate the column).
  defp infer_provider("claude-" <> _), do: "claude"
  defp infer_provider("gemini-" <> _), do: "gemini"
  defp infer_provider("gpt-" <> _), do: "codex"
  defp infer_provider("o" <> <<d, _::binary>>) when d in ?0..?9, do: "codex"
  defp infer_provider(_), do: nil

  # ---- rows -----------------------------------------------------------------

  @run_columns """
  id, task_id, base_task_id, workspace_id, kind, role, provider, model, repo, started_at,
  stop_category, failure_reason, harness_version, guardrail_decision
  """

  defp runs_in(from, now) do
    query(
      """
      SELECT #{@run_columns}
      FROM worker_runs
      WHERE started_at >= ?1 AND started_at < ?2
      ORDER BY started_at, id
      """,
      [iso(from), iso(now)]
    )
    |> Enum.reject(&is_nil(&1["task_id"]))
  end

  defp runs_by_id([]), do: []

  defp runs_by_id(ids) do
    ids
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      placeholders = Enum.map_join(1..length(chunk), ", ", &"?#{&1}")

      query("SELECT #{@run_columns} FROM worker_runs WHERE id IN (#{placeholders})", chunk)
    end)
  end

  defp events_in(from, now) do
    query(
      """
      SELECT id, run_id, task_id, provider, model, kind, severity, source, tool, detail,
             inserted_at
      FROM guardrail_events
      WHERE inserted_at >= ?1 AND inserted_at < ?2
      ORDER BY inserted_at, id
      """,
      [iso(from), iso(now)]
    )
  end

  defp to_run(row, harness) do
    %{
      id: row["id"],
      task_id: Estimate.fold_task_id(row["base_task_id"] || row["task_id"]),
      kind: row["kind"],
      role: row["role"],
      model: row["model"],
      repo: row["repo"],
      workspace_id: row["workspace_id"],
      started_at: parse(row["started_at"]),
      stop_category: row["stop_category"],
      failure_reason: row["failure_reason"],
      harness_version: row["harness_version"],
      subject: run_subject(row, harness)
    }
  end

  # An event's workspace is its run's: `guardrail_events` records none itself.
  defp to_event(row, subject, run) do
    %{
      id: row["id"],
      run_id: row["run_id"],
      task_id: row["task_id"] && Estimate.fold_task_id(row["task_id"]),
      workspace_id: run && run.workspace_id,
      kind: row["kind"],
      severity: row["severity"],
      source: row["source"],
      tool: row["tool"],
      detail: row["detail"],
      inserted_at: parse(row["inserted_at"]),
      subject: subject
    }
  end

  # ---- plumbing -----------------------------------------------------------

  defp iso(%DateTime{microsecond: {us, _}} = dt),
    do: dt |> Map.put(:microsecond, {us, 6}) |> DateTime.to_iso8601()

  defp parse(nil), do: nil

  defp parse(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  # The only interpolations reaching this helper are the fixed column list and
  # the `?1, ?2, …` placeholders `runs_by_id/1` builds from `1..length(chunk)`.
  # Every value is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  defp query(sql, params) do
    %{columns: cols, rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
  end
end
