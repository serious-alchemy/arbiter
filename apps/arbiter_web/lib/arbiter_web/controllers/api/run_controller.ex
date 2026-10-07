defmodule ArbiterWeb.Api.RunController do
  @moduledoc """
  REST endpoints for `Arbiter.Workers.Run` — the durable history of worker
  runs (a worker's lifecycle after the GenServer is gone).

  Routes:

    * `GET /api/workers/history`      — :index (filters: task_id, workspace_id,
                                          kind, state, outcome, limit [default
                                          20], before [ISO8601 started_at
                                          cursor])
    * `GET /api/workers/history/:id`  — :show (single run with full output)

  Newest first. Pass `task_id` to list every historical run for a single task
  (the per-task run history surfaced by `arb worker runs <task-id>`).

  `kind`, `state` and `outcome` filter on the one run vocabulary
  (`Arbiter.Workers.RunState`, bd-1uu19b). The pre-5/13 `status` filter is
  still accepted and mapped onto it the way the migration mapped the column:
  `running` is `state=working`, `completed` is `outcome=succeeded`, `failed` /
  `review_parked` / `review_not_started` are `outcome=failed`, `interrupted`
  is `outcome=interrupted`.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunState
  alias ArbiterWeb.Api.WorkspaceParam
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @default_limit 20

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

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, kind} <- parse_enum(params["kind"], "kind", Run.kinds()),
         {:ok, state} <- parse_enum(params["state"], "state", RunState.states()),
         {:ok, outcome} <- parse_enum(params["outcome"], "outcome", RunState.outcomes()),
         {:ok, legacy} <- parse_legacy_status(params["status"]),
         {:ok, before} <- parse_before(params["before"]) do
      runs =
        Run
        |> filter_eq(:task_id, params["task_id"])
        |> filter_eq(:workspace_id, ws_id)
        |> filter_eq(:kind, kind)
        |> filter_eq(:state, state)
        |> filter_eq(:outcome, outcome)
        |> filter_legacy_status(legacy)
        |> filter_before(before)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> exclude_output_lines()
        |> Ash.read!()

      render(conn, :index, runs: runs)
    end
  end

  def show(conn, %{"id" => id}) when is_binary(id) and id != "" do
    case Ash.get(Run, id) do
      {:ok, run} -> render(conn, :show, run: run)
      {:error, _} -> {:error, :not_found}
    end
  end

  def show(_conn, _params), do: {:error, {:invalid_request, "id is required", %{}}}

  # ---- query helpers ----

  defp filter_eq(query, _field, value) when value in [nil, ""], do: query

  defp filter_eq(query, :task_id, value),
    do: Ash.Query.filter(query, task_id == ^value)

  defp filter_eq(query, :workspace_id, value),
    do: Ash.Query.filter(query, workspace_id == ^value)

  defp filter_eq(query, :kind, value), do: Ash.Query.filter(query, kind == ^value)
  defp filter_eq(query, :state, value), do: Ash.Query.filter(query, state == ^value)
  defp filter_eq(query, :outcome, value), do: Ash.Query.filter(query, outcome == ^value)

  defp filter_legacy_status(query, nil), do: query
  defp filter_legacy_status(query, {state, nil}), do: filter_eq(query, :state, state)
  defp filter_legacy_status(query, {_finished, outcome}), do: filter_eq(query, :outcome, outcome)

  defp filter_before(query, nil), do: query
  defp filter_before(query, %DateTime{} = dt), do: Ash.Query.filter(query, started_at < ^dt)

  defp exclude_output_lines(query) do
    Ash.Query.select(query, [
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
      :model_family,
      :routing_decision
    ])
  end

  # ---- param coercion ----

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "limit must be a positive integer"}}
    end
  end

  defp parse_limit(_), do: {:error, {:invalid_request, "limit must be a positive integer"}}

  # Matched against the allowed atoms' names, so an unknown value never
  # reaches `String.to_existing_atom/1`.
  defp parse_enum(raw, _name, _allowed) when raw in [nil, ""], do: {:ok, nil}

  defp parse_enum(raw, name, allowed) when is_binary(raw) do
    case Enum.find(allowed, &(Atom.to_string(&1) == raw)) do
      nil -> {:error, {:invalid_request, "invalid #{name}: #{inspect(raw)}"}}
      atom -> {:ok, atom}
    end
  end

  defp parse_enum(raw, name, _allowed),
    do: {:error, {:invalid_request, "invalid #{name}: #{inspect(raw)}"}}

  defp parse_legacy_status(raw) when raw in [nil, ""], do: {:ok, nil}

  defp parse_legacy_status(raw) do
    case Map.fetch(@legacy_statuses, raw) do
      {:ok, state_outcome} -> {:ok, state_outcome}
      :error -> {:error, {:invalid_request, "invalid status: #{inspect(raw)}"}}
    end
  end

  defp parse_before(nil), do: {:ok, nil}
  defp parse_before(""), do: {:ok, nil}

  defp parse_before(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, {:invalid_request, "before must be ISO8601 (e.g. 2026-05-27T20:00:00Z)"}}
    end
  end
end
