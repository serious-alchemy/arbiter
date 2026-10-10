defmodule Arbiter.Workers.Serializer do
  @moduledoc """
  The one place a worker read is turned into a JSON-ready map (parity audit
  P-11). REST (`ArbiterWeb.Api.WorkerJSON`, `RunJSON`, `WorkerController`),
  MCP (`Arbiter.MCP.Tools.Worker`) and — through REST — the CLI all render
  through here, so a field added or renamed shows up on every surface at once.

    * `summary/2` — a `worker_list` / `GET /api/workers` row;
    * `show/3` — a `worker_show` / `GET /api/workers/:task_id` payload: the
      current run's summary, its bounded output tail and its `runs`;
    * `current_run/1` — the slim current-run object a ticket payload carries;
    * `run_summary/1` / `run_detail/1` — a `Run` row (history list / one run);
    * `log/2`, `prompt/1`, `run_log_entry/1` — the transcript, prompt and
      corpus-listing entries.

  Atom keys throughout (REST and MCP both encode them as JSON strings), ISO 8601
  timestamps, enum values as strings.

  ## Slim views: `fields`

  A caller that wants less asks for it with a `fields` list; `project/2` keeps
  those keys of the one full payload (and refuses a name the payload does not
  have). A slim view is therefore always a subset of the full one — it can never
  drift into a shape of its own.
  """

  alias Arbiter.Usage.LiveSpend
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Worker.Phase
  alias Arbiter.Worker.PromptLog
  alias Arbiter.Worker.Stats
  alias Arbiter.Workers.OutputOffload
  alias Arbiter.Workers.PrepushSteps
  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunNode
  alias Arbiter.Workflows.DispatchQueue

  require Logger

  @type view :: map()

  # ---- worker rows ------------------------------------------------------------

  @doc "A `worker_list` row: the current run, its resumability and its spend."
  @spec summary(view(), LiveSpend.t() | nil) :: map()
  def summary(view, spend) do
    view
    |> row()
    |> Map.merge(resumable_fields(view))
    |> Map.merge(LiveSpend.cost_fields(spend))
  end

  @doc """
  A ticket's current run and its recent runs, in full detail.

  Options: `:lines` — keep only the last N output lines; `:cost` — the ticket's
  `LiveSpend` (nil for none).
  """
  @spec show(view(), [view()], keyword()) :: map()
  def show(current, runs, opts \\ []) do
    meta = Map.get(current, :meta) || %{}
    run = Map.get(current, :run)

    output_lines = Map.get(meta, :output_lines, [])

    output_lines =
      case opts[:lines] do
        n when is_integer(n) and n > 0 -> Enum.take(output_lines, -n)
        _ -> output_lines
      end

    current
    |> row()
    |> Map.merge(resumable_fields(current))
    |> Map.merge(%{
      task_title: task_title(run),
      step_started_at: iso(Map.get(current, :step_started_at)),
      last_merger_status: Map.get(meta, :last_merger_status),
      last_checked_at: iso(Map.get(meta, :last_checked_at)),
      output_lines: output_lines,
      exit_status: Map.get(meta, :exit_status),
      exited_at: iso(Map.get(meta, :exited_at)),
      result: Map.get(meta, :result),
      # bd-8wdrql: what the pre-push recipe ran for this run, per attempt.
      pre_push_checks: pre_push_checks(Map.get(current, :run_id)),
      runs: Enum.map(runs, &recent_run/1)
    })
    |> Map.merge(LiveSpend.cost_fields(opts[:cost]))
  end

  defp pre_push_checks(run_id),
    do: run_id |> PrepushSteps.list() |> Enum.map(&PrepushSteps.to_map/1)

  @doc """
  The slim current-run object a ticket payload carries (`GET /api/issues/:id`,
  `ticket_show full:true`): kind / state / outcome / phase, no transcript. nil
  stays nil.
  """
  @spec current_run(view() | nil) :: map() | nil
  def current_run(nil), do: nil

  def current_run(view) do
    view
    |> row()
    |> Map.take([
      :run_id,
      :run_task_id,
      :source,
      :kind,
      :state,
      :outcome,
      :waiting_on,
      :role,
      :node_id,
      :node_name,
      :phase,
      :phase_label,
      :started_at,
      :completed_at,
      :failure_reason
    ])
  end

  # A recent run in `show`'s `runs` list: the same vocabulary, no transcript.
  @spec recent_run(view()) :: map()
  def recent_run(view) do
    view
    |> row()
    |> Map.take([
      :run_id,
      :run_task_id,
      :source,
      :kind,
      :state,
      :outcome,
      :role,
      :node_id,
      :node_name,
      :model,
      :started_at,
      :completed_at,
      :failure_reason,
      :failure_summary
    ])
    |> Map.put(:current, Map.get(view, :current, false))
  end

  # One run, as `summary/2` and `show/3` both report it, in the one run
  # vocabulary (`Arbiter.Workers.RunState`). `task_id` is the ticket;
  # `run_task_id` is the id the run itself runs under — a ReviewGate reviewer
  # runs under `<ticket>#review`.
  defp row(view) do
    meta = Map.get(view, :meta) || %{}

    view
    |> RunNode.fields()
    |> Map.merge(%{
      task_id: view.ticket_id,
      run_task_id: view.task_id,
      run_id: Map.get(view, :run_id),
      source: to_str(view.source),
      kind: to_str(view.kind),
      state: to_str(view.state),
      outcome: to_str(view.outcome),
      waiting_on: to_str(Map.get(view, :waiting_on)),
      # bd-8lq2g7: the registry key + role tell a merge-queue pass from the
      # ticket's own run.
      registry_key: Map.get(view, :registry_key),
      role: to_str(Map.get(view, :role)),
      workspace_id: Map.get(view, :workspace_id),
      repo: Map.get(view, :repo),
      current_step: Map.get(view, :current_step),
      claude_session: Map.get(meta, :claude_session, false),
      activity: Map.get(meta, :activity),
      # bd-aw2cyt: what the work is actually doing, and whether a process
      # exists behind it.
      phase: to_str(Map.get(view, :phase)),
      phase_label: Phase.label(Map.get(view, :phase)),
      # bd-6omte4: the dispatch the quota gate is holding for the ticket.
      held: DispatchQueue.serialize_held(Map.get(view, :held)),
      agent_live: Map.get(view, :agent_live),
      started_at: iso(Map.get(view, :started_at)),
      completed_at: iso(Map.get(view, :completed_at)),
      mr_ref: Map.get(view, :mr_ref),
      merger_url: Map.get(view, :merger_url),
      pid: inspect_pid(Map.get(view, :pid)),
      failure_reason: stringify(Map.get(view, :failure_reason)),
      failure_summary: Map.get(meta, :failure_summary)
    })
    |> Map.merge(routing_fields(Map.get(view, :run), meta))
  end

  # bd-40pzpj: the model and provider, and what provider routing chose and why
  # — off the run's row when the view was read from one, else the live
  # worker's meta. `model` is the short display name ("Sonnet") everywhere.
  defp routing_fields(%Run{} = run, _meta) do
    run
    |> Map.take([
      :provider,
      :provider_fallback,
      :provider_account_id,
      :model_family,
      :routing_decision,
      :guardrail_decision
    ])
    |> Map.put(:model, Stats.short_model_name(run.model))
  end

  defp routing_fields(nil, meta) do
    routing = Map.get(meta, :routing_config) || %{}

    %{
      model: Stats.short_model_name(Map.get(meta, :model) || Map.get(routing, :model)),
      provider: Worker.provider(meta) || Map.get(routing, :provider),
      provider_fallback: Map.get(meta, :provider_fallback),
      provider_account_id: Map.get(meta, :provider_account_id),
      model_family: Map.get(meta, :model_family),
      routing_decision: Map.get(meta, :routing_decision),
      guardrail_decision: Map.get(meta, :guardrail_decision)
    }
  end

  defp resumable_fields(view) do
    {resumable, blocked_reason} = Dispatch.resumable_status(view.ticket_id)
    %{resumable: resumable, blocked_reason: blocked_reason}
  end

  # ---- Run rows -----------------------------------------------------------------

  @doc "A `Run` row as a history list entry (no `output_lines`)."
  @spec run_summary(Run.t()) :: map()
  def run_summary(%Run{} = r) do
    r
    |> RunNode.fields()
    |> Map.merge(%{
      id: r.id,
      task_id: r.task_id,
      task_title: r.task_title,
      repo: r.repo,
      workspace_id: r.workspace_id,
      # bd-1uu19b: the one run vocabulary (`Arbiter.Workers.RunState`);
      # `outcome` is nil until the run has finished.
      kind: to_str(r.kind),
      state: to_str(r.state),
      outcome: to_str(r.outcome),
      model: r.model,
      started_at: iso(r.started_at),
      completed_at: iso(r.completed_at),
      exit_code: r.exit_code,
      failure_reason: r.failure_reason,
      failure_summary: r.failure_summary,
      resolved_skills: r.resolved_skills || [],
      standing_orders_digest: r.standing_orders_digest,
      routing_policy: r.routing_policy,
      model_tier: r.model_tier,
      thinking: r.thinking,
      difficulty_at_dispatch: r.difficulty_at_dispatch,
      provider: r.provider,
      provider_fallback: r.provider_fallback,
      # bd-40pzpj: what provider routing chose and why (nil when not routed).
      provider_account_id: r.provider_account_id,
      model_family: r.model_family,
      routing_decision: r.routing_decision,
      guardrail_decision: r.guardrail_decision,
      session_id: r.session_id,
      resumed_from_run_id: r.resumed_from_run_id
    })
  end

  @doc "One `Run` row with its output tail (`GET /api/workers/history/:id`, `worker_runs run_id:`)."
  @spec run_detail(Run.t()) :: map()
  def run_detail(%Run{} = r) do
    r
    |> run_summary()
    |> Map.merge(%{
      output_lines: OutputOffload.output_lines(r),
      inserted_at: iso(r.inserted_at),
      updated_at: iso(r.updated_at)
    })
  end

  @doc """
  The durable transcript of one run. `:tail` keeps only the last N lines;
  `line_count` is always the transcript's true length and `truncated` says
  whether `lines` is shorter than it. `exists` distinguishes "no file yet /
  never captured" (false, no lines) from "captured but empty" (true, no lines).
  """
  @spec log(Run.t(), keyword()) :: map()
  def log(%Run{} = run, opts \\ []) do
    {exists, all} =
      case OutputLog.read_lines(run.id) do
        {:ok, lines} -> {true, lines}
        {:error, _} -> {false, []}
      end

    lines =
      case opts[:tail] do
        n when is_integer(n) and n > 0 -> Enum.take(all, -n)
        _ -> all
      end

    %{
      task_id: run.task_id,
      run_id: run.id,
      path: OutputLog.path_for(run.id),
      exists: exists,
      line_count: length(all),
      truncated: length(lines) < length(all),
      lines: lines
    }
  end

  @doc """
  The composed prompt one run was spawned with (bd-9rdwe4), redacted through
  the same choke-point as transcript lines.
  """
  @spec prompt(Run.t()) :: map()
  def prompt(%Run{} = run) do
    {exists, text} =
      case PromptLog.read(run.id) do
        {:ok, content} -> {true, content}
        {:error, _} -> {false, nil}
      end

    %{
      task_id: run.task_id,
      run_id: run.id,
      path: PromptLog.path_for(run.id),
      exists: exists,
      prompt: text,
      prompt_sha256: run.prompt_sha256
    }
  end

  @doc "A `run_log_list` entry: a run plus whether (and how long) its transcript is."
  @spec run_log_entry(Run.t()) :: map()
  def run_log_entry(%Run{} = run) do
    line_count =
      case OutputLog.read_lines(run.id) do
        {:ok, lines} -> length(lines)
        {:error, _} -> 0
      end

    run
    |> RunNode.fields()
    |> Map.merge(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: to_str(run.kind),
      state: to_str(run.state),
      outcome: to_str(run.outcome),
      model: run.model,
      started_at: iso(run.started_at),
      transcript_exists: File.regular?(OutputLog.path_for(run.id)),
      line_count: line_count
    })
  end

  # ---- slim views ---------------------------------------------------------------

  @doc """
  Keep only `fields` of `payload` — the `fields` option of the slim MCP view.
  `nil` / `[]` keep everything. A name the payload does not have is
  `{:error, {:invalid, msg}}`, never silently dropped, so a typo cannot read as
  "that field is empty".
  """
  @spec project(map(), [String.t()] | nil) ::
          {:ok, map()} | {:error, {:invalid, String.t()}}
  def project(payload, fields) when fields in [nil, []], do: {:ok, payload}

  def project(payload, fields) when is_list(fields) do
    names = Map.new(payload, fn {key, _} -> {to_string(key), key} end)

    case Enum.reject(fields, &(is_binary(&1) and Map.has_key?(names, &1))) do
      [] -> {:ok, Map.take(payload, Enum.map(fields, &Map.fetch!(names, &1)))}
      unknown -> {:error, {:invalid, "unknown fields: #{Enum.join(unknown, ", ")}"}}
    end
  end

  def project(_payload, _fields),
    do: {:error, {:invalid, "`fields` must be a list of field names"}}

  # ---- spend ----------------------------------------------------------------------

  @doc """
  Settled + in-flight spend per live task, keyed by task id. Best-effort: a
  failed ledger read costs the rows their cost fields, never the listing.
  """
  @spec costs([view()]) :: %{optional(String.t()) => LiveSpend.t()}
  def costs(views) do
    LiveSpend.by_worker_task(views)
  rescue
    e ->
      Logger.warning("worker list: live spend read failed: #{Exception.message(e)}")
      %{}
  end

  @doc "One ticket's spend (best-effort, like `costs/1`); nil when unreadable."
  @spec task_cost(String.t()) :: LiveSpend.t() | nil
  def task_cost(task_id) do
    task_id |> Arbiter.Usage.Estimate.fold_task_id() |> LiveSpend.for_task()
  rescue
    e ->
      Logger.warning("worker show: live spend read failed: #{Exception.message(e)}")
      nil
  end

  # ---- helpers ----------------------------------------------------------------------

  defp task_title(%Run{task_title: title}), do: title
  defp task_title(_view), do: nil

  defp inspect_pid(nil), do: nil
  defp inspect_pid(pid), do: inspect(pid)

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)

  defp to_str(nil), do: nil
  defp to_str(a) when is_atom(a), do: Atom.to_string(a)
  defp to_str(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso(other), do: other
end
