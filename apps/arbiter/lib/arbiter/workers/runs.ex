defmodule Arbiter.Workers.Runs do
  @moduledoc """
  The worker read side's one query layer over `Arbiter.Workers.Run` (parity
  audit P-11): run history and its fleet-wide filters, the per-task transcript
  corpus, single-run lookup, and the checks that a run belongs to the task a
  caller named. MCP (`worker_runs` / `worker_log` / `worker_prompt` /
  `run_log_list`), REST (`/api/workers/history`, `/log`, `/prompt`,
  `/run_log_list`) and the CLI (through REST) all call it, so a filter, a cap or
  an ownership rule is changed in one place.

  ## Caps

  A run list is bounded the same way on every surface:

    * history (`worker_runs`, `GET /api/workers/history`, `arb worker runs`):
      default 20, max 200;
    * transcript corpus (`run_log_list`, `/run_log_list`, `arb worker runs
      --corpus`): default 200, max 1000.

  A limit above the max is clamped, never refused; zero, negatives and junk are
  invalid. `history_cap/0` and `corpus_cap/0` are the numbers the tool schemas
  and docs quote.
  """

  alias Arbiter.Params
  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunState

  require Ash.Query

  @history_default 20
  @history_max 200
  @corpus_default 200
  @corpus_max 1000

  # `{state, outcome}` for each pre-5/13 `status` value — the same rule as
  # `RunState.from_legacy_status/1` and the migration that backfilled the
  # columns.
  @legacy_statuses %{
    "running" => {:working, nil},
    "completed" => {:finished, :succeeded},
    "failed" => {:finished, :failed},
    "review_parked" => {:finished, :failed},
    "review_not_started" => {:finished, :failed},
    "interrupted" => {:finished, :interrupted}
  }

  # Every column but `output_lines` (up to 500 strings per run): a list row
  # never needs the transcript tail, and `get/1` is the one way to fetch it.
  @summary_fields [
    :id,
    :task_id,
    :task_title,
    :repo,
    :workspace_id,
    :kind,
    :state,
    :outcome,
    :model,
    :started_at,
    :completed_at,
    :exit_code,
    :failure_reason,
    :failure_summary,
    :resolved_skills,
    :standing_orders_digest,
    :routing_policy,
    :model_tier,
    :thinking,
    :difficulty_at_dispatch,
    :provider,
    :session_id,
    :resumed_from_run_id,
    :provider_fallback,
    :provider_account_id,
    :node_id,
    :model_family,
    :routing_decision,
    :guardrail_decision
  ]

  @type filters :: %{
          optional(:task_id) => String.t() | nil,
          optional(:kind) => atom() | nil,
          optional(:state) => atom() | nil,
          optional(:outcome) => atom() | nil,
          optional(:legacy) => {atom(), atom() | nil} | nil,
          optional(:before) => DateTime.t() | nil
        }

  # ---- caps -----------------------------------------------------------------

  @doc "The largest history list any surface returns."
  @spec history_cap() :: pos_integer()
  def history_cap, do: @history_max

  @doc "The largest transcript-corpus list any surface returns."
  @spec corpus_cap() :: pos_integer()
  def corpus_cap, do: @corpus_max

  @doc "Coerce a history `limit` (absent → #{@history_default}, clamped to #{@history_max})."
  @spec history_limit(term()) :: {:ok, pos_integer()} | {:error, {:invalid, String.t()}}
  def history_limit(raw),
    do: raw |> Params.limit(@history_default, @history_max) |> tag_max(@history_max)

  @doc "Coerce a corpus `limit` (absent → #{@corpus_default}, clamped to #{@corpus_max})."
  @spec corpus_limit(term()) :: {:ok, pos_integer()} | {:error, {:invalid, String.t()}}
  def corpus_limit(raw),
    do: raw |> Params.limit(@corpus_default, @corpus_max) |> tag_max(@corpus_max)

  defp tag_max({:error, {:invalid, _}}, max),
    do: {:error, {:invalid, "limit must be a positive integer (max #{max})"}}

  defp tag_max(ok, _max), do: ok

  # ---- filters --------------------------------------------------------------

  @doc """
  Read the history filters out of string-keyed params (REST query string or MCP
  arguments): `task_id`, `kind`, `state`, `outcome`, `status` (the pre-5/13
  vocabulary, mapped onto state/outcome) and `before` (ISO 8601 `started_at`
  cursor, exclusive). Unknown enum values are refused, never ignored — a typo
  must not widen the query to the whole fleet.
  """
  @spec parse_filters(map()) :: {:ok, filters()} | {:error, {:invalid, String.t()}}
  def parse_filters(params) when is_map(params) do
    with {:ok, kind} <- parse_enum(params["kind"], "kind", Run.kinds()),
         {:ok, state} <- parse_enum(params["state"], "state", RunState.states()),
         {:ok, outcome} <- parse_enum(params["outcome"], "outcome", RunState.outcomes()),
         {:ok, legacy} <- parse_legacy_status(params["status"]),
         {:ok, before} <- parse_before(params["before"]) do
      {:ok,
       %{
         task_id: blank_to_nil(params["task_id"]),
         kind: kind,
         state: state,
         outcome: outcome,
         legacy: legacy,
         before: before
       }}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # Matched against the allowed atoms' names, so an unknown value never
  # reaches `String.to_existing_atom/1`.
  defp parse_enum(raw, _name, _allowed) when raw in [nil, ""], do: {:ok, nil}

  defp parse_enum(raw, name, allowed) when is_binary(raw) do
    case Enum.find(allowed, &(Atom.to_string(&1) == raw)) do
      nil -> {:error, {:invalid, "invalid #{name}: #{inspect(raw)}"}}
      atom -> {:ok, atom}
    end
  end

  defp parse_enum(raw, name, _allowed),
    do: {:error, {:invalid, "invalid #{name}: #{inspect(raw)}"}}

  defp parse_legacy_status(raw) when raw in [nil, ""], do: {:ok, nil}

  defp parse_legacy_status(raw) do
    case Map.fetch(@legacy_statuses, raw) do
      {:ok, state_outcome} -> {:ok, state_outcome}
      :error -> {:error, {:invalid, "invalid status: #{inspect(raw)}"}}
    end
  end

  defp parse_before(raw) when raw in [nil, ""], do: {:ok, nil}

  defp parse_before(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, {:invalid, "before must be ISO8601 (e.g. 2026-05-27T20:00:00Z)"}}
    end
  end

  defp parse_before(_raw),
    do: {:error, {:invalid, "before must be ISO8601 (e.g. 2026-05-27T20:00:00Z)"}}

  # ---- queries --------------------------------------------------------------

  @doc """
  Run history, newest first, without `output_lines`. `filters` is the
  `parse_filters/1` result; `:workspace_id` (nil = every workspace) and `:limit`
  (already coerced with `history_limit/1`) are options.
  """
  @spec history(filters(), keyword()) :: [Run.t()]
  def history(filters, opts) do
    Run
    |> eq(:task_id, filters[:task_id])
    |> eq(:workspace_id, opts[:workspace_id])
    |> eq(:kind, filters[:kind])
    |> eq(:state, filters[:state])
    |> eq(:outcome, filters[:outcome])
    |> legacy(filters[:legacy])
    |> before(filters[:before])
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(Keyword.fetch!(opts, :limit))
    |> Ash.Query.select(@summary_fields)
    |> Ash.read!()
  end

  @doc """
  Every run recorded for `task_id` AND its ReviewGate synthetic children
  (`<task_id>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`), newest first
  — the whole retrievable transcript corpus for a task. Pass the base task id
  even to reach the synthetic runs.
  """
  @spec corpus(String.t(), pos_integer()) :: [Run.t()]
  def corpus(task_id, limit) when is_binary(task_id) do
    prefix = task_id <> "#"

    Run
    |> Ash.Query.filter(task_id == ^task_id or string_starts_with(task_id, ^prefix))
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.select(@summary_fields)
    |> Ash.read!()
  end

  @doc "One run by id, with every column (`output_lines` included)."
  @spec get(String.t()) :: {:ok, Run.t()} | :error
  def get(run_id) when is_binary(run_id) and run_id != "" do
    case Ash.get(Run, run_id) do
      {:ok, %Run{} = run} -> {:ok, run}
      _ -> :error
    end
  end

  def get(_run_id), do: :error

  @doc "The newest run recorded under exactly `task_id` (synthetic ids included), or nil."
  @spec latest(String.t()) :: Run.t() | nil
  def latest(task_id) when is_binary(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # ---- ownership ------------------------------------------------------------

  @doc """
  True when `run` is an attempt at `task_id`: recorded under that id, or — for
  a plain ticket id — under one of its ReviewGate synthetic children. A
  synthetic path id selects exactly that child (`bd-x#review` does not claim
  `bd-x`'s own runs, nor `bd-x#r1`'s).
  """
  @spec belongs_to_task?(Run.t(), String.t()) :: boolean()
  def belongs_to_task?(%Run{task_id: run_task}, task_id) when is_binary(task_id) do
    run_task == task_id or
      (not String.contains?(task_id, "#") and ReviewGate.base_task_id(run_task) == task_id)
  end

  @doc """
  The workspace a task (or synthetic child) lives in: its ticket's, else — for
  an id with no ticket row — its newest run's. nil when neither exists.
  """
  @spec task_workspace_id(String.t()) :: String.t() | nil
  def task_workspace_id(task_id) when is_binary(task_id) do
    base = ReviewGate.base_task_id(task_id)

    case Ash.get(Issue, base) do
      {:ok, %Issue{workspace_id: ws}} when is_binary(ws) -> ws
      _ -> (latest(task_id) || latest(base) || %{workspace_id: nil}).workspace_id
    end
  end

  # ---- query pieces ---------------------------------------------------------

  defp eq(query, _field, value) when value in [nil, ""], do: query
  defp eq(query, :task_id, value), do: Ash.Query.filter(query, task_id == ^value)
  defp eq(query, :workspace_id, value), do: Ash.Query.filter(query, workspace_id == ^value)
  defp eq(query, :kind, value), do: Ash.Query.filter(query, kind == ^value)
  defp eq(query, :state, value), do: Ash.Query.filter(query, state == ^value)
  defp eq(query, :outcome, value), do: Ash.Query.filter(query, outcome == ^value)

  defp legacy(query, nil), do: query
  defp legacy(query, {state, nil}), do: eq(query, :state, state)
  defp legacy(query, {_finished, outcome}), do: eq(query, :outcome, outcome)

  defp before(query, nil), do: query
  defp before(query, %DateTime{} = dt), do: Ash.Query.filter(query, started_at < ^dt)
end
