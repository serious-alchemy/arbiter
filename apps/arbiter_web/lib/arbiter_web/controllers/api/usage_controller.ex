defmodule ArbiterWeb.Api.UsageController do
  @moduledoc """
  REST endpoints for the structured usage ledger (`Arbiter.Usage.Event`).

  Routes:

    * `GET /api/usage`          — aggregated rollup. Required query: `by` (one of
                                  `day | task | epic | workspace |
                                  provider_account | repo | model | step |
                                  provider | source | session`; `campaign`
                                  also accepted as a deprecated alias for
                                  `epic`, and `account` accepted as an alias
                                  for `provider_account`). Optional:
                                  `workspace` (id or name; alias `workspace_id`),
                                  `account`, `since` (ISO8601), `limit`.
    * `GET /api/usage/events`   — raw event list (newest first). Optional
                                  filters: `workspace`, `account`, `task_id`,
                                  `session_id`, `since`, `step`, `source`,
                                  `limit` (default 50).
    * `GET /api/usage/calibration` — difficulty mis-rating report (bd-3j4ch4):
                                  closed tasks whose actual cost lands outside
                                  their own tier's p25–p75 but inside an
                                  adjacent tier's. Optional: `workspace`,
                                  `window_days`.

  `by=task` covers task-attributed spend only — probe / pre-flight / session
  rows carry no `task_id` (bd-adyhvn). Use `by=source` for the full split.

  `account` (P10, `docs/provider-account-design.md` §8) accepts anything
  `Arbiter.Accounts.get_account/1` resolves — a UUID, a `"provider:slug"`
  ref, or a bare unambiguous slug — and filters
  `usage_events.provider_account_id` directly (P9), so probe/pre-flight rows
  (no `workspace_id`, but always an account) are included. `by=provider_account`
  is the rollup dimension; `account` narrows any rollup or the raw event list
  to one account.

  A `workspace` that names nothing means every workspace; the body echoes the
  resolved `workspace_id` (`null` for all). A token bound to one workspace is
  confined to it, and an unknown workspace is a 404, never an empty rollup.

  Both back the `arb usage` CLI; the rollup is the primary surface (per-day
  spend, top tasks, rework cost). `events` is for debugging / drill-down.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Params
  alias Arbiter.Usage
  alias Arbiter.Usage.Params, as: UsageParams
  alias Arbiter.Usage.Serializer
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  def summarize(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, by} <- parse_by(params["by"]),
         {:ok, since} <- parse_since(params["since"]),
         {:ok, limit} <- parse_optional_limit(params["limit"]),
         {:ok, account_id} <- UsageParams.account_id(params["account"]) |> Params.to_rest() do
      opts =
        [by: by]
        |> add_opt(:since, since)
        |> add_opt(:workspace_id, ws_id)
        |> add_opt(:provider_account_id, account_id)
        |> add_opt(:limit, limit)

      case Usage.summarize(opts) do
        {:ok, rollups} ->
          json(conn, %{
            by: Atom.to_string(Usage.normalize_by(by)),
            workspace_id: ws_id,
            data: Enum.map(rollups, &Serializer.rollup/1)
          })

        {:error, reason} ->
          {:error, {:invalid_request, "could not summarize usage: #{inspect(reason)}"}}
      end
    end
  end

  @doc """
  The mis-rating report behind `arb usage --calibration`.

  Rendered wholesale rather than paginated: the flagged list is the tasks
  whose rating looks wrong, which is a handful even over a busy 60 days, and
  truncating it would silently hide the tail that matters most.
  """
  def calibration(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, window_days} <- UsageParams.window_days(params["window_days"]) |> Params.to_rest() do
      opts =
        []
        |> add_opt(:workspace_id, ws_id)
        |> add_opt(:window_days, window_days)

      json(conn, Serializer.calibration(Usage.calibration(opts), ws_id))
    end
  end

  def events(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, since} <- parse_since(params["since"]),
         {:ok, step} <- UsageParams.step(params["step"]) |> Params.to_rest(),
         {:ok, source} <- UsageParams.source(params["source"]) |> Params.to_rest(),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, account_id} <- UsageParams.account_id(params["account"]) |> Params.to_rest() do
      events =
        Usage.list_events(
          workspace_id: ws_id,
          provider_account_id: account_id,
          task_id: params["task_id"],
          session_id: params["session_id"],
          step: step,
          source: source,
          since: since,
          limit: limit
        )

      json(conn, %{workspace_id: ws_id, data: Enum.map(events, &Serializer.event/1)})
    end
  end

  defp add_opt(opts, _key, nil), do: opts
  defp add_opt(opts, _key, ""), do: opts
  defp add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # ---- param coercion ----------------------------------------------------

  defp parse_by(nil), do: {:error, {:invalid_request, "by is required: one of #{by_options()}"}}
  defp parse_by(""), do: {:error, {:invalid_request, "by is required: one of #{by_options()}"}}

  defp parse_by(raw) when is_binary(raw) do
    atom = String.to_existing_atom(raw)

    if atom in Usage.acceptable_groupings() do
      {:ok, atom}
    else
      {:error,
       {:invalid_request, "invalid by: #{inspect(raw)} (expected one of #{by_options()})"}}
    end
  rescue
    ArgumentError ->
      {:error,
       {:invalid_request, "invalid by: #{inspect(raw)} (expected one of #{by_options()})"}}
  end

  defp by_options do
    Usage.valid_groupings() |> Enum.map_join(", ", &Atom.to_string/1)
  end

  defp parse_since(nil), do: {:ok, nil}
  defp parse_since(""), do: {:ok, nil}

  defp parse_since(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:invalid_request, "since must be ISO8601 (e.g. 2026-06-01T00:00:00Z)"}}
    end
  end

  defp parse_limit(raw), do: raw |> UsageParams.event_limit() |> Params.to_rest()

  defp parse_optional_limit(nil), do: {:ok, nil}
  defp parse_optional_limit(""), do: {:ok, nil}
  defp parse_optional_limit(raw), do: parse_limit(raw)
end
