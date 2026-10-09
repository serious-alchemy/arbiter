defmodule Arbiter.Guardrails.SpendCalibration do
  @moduledoc """
  Calibrates the tier spend caps against the usage ledger (G19,
  `docs/design/guardrail-profiles.md` §9: "calibrate from the ledger").

  `report/1` folds each task's `source: :task` ledger rows into one token total and
  one wall-clock total (`tokens_in + tokens_out + thinking_tokens`, the figure
  `Arbiter.Guardrails.SpendPatrol` caps; the sum of `duration_ms`), then reports
  their percentiles per provider. A cap is a number to set against a provider's p90 or
  p99, with the incident that motivated it (bd-bxwsvo: 7.7M tokens, 65 minutes on a
  D1) as the floor it must trip.

  From a release shell:

      Arbiter.Guardrails.SpendCalibration.report(since: ~U[2026-09-01 00:00:00Z])

  Options: `:since` (a `DateTime`), `:workspace_id`.
  """

  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.Event

  require Ash.Query

  @percentiles [p50: 0.5, p90: 0.9, p99: 0.99]

  @type dist :: %{p50: number(), p90: number(), p99: number(), max: number()}
  @type provider_report :: %{tasks: pos_integer(), tokens: dist(), wall_clock_s: dist()}

  @spec report(keyword()) :: %{String.t() => provider_report()}
  def report(opts \\ []) do
    task_source = :task

    Event
    |> Ash.Query.filter(source == ^task_source and not is_nil(task_id))
    |> filter_since(Keyword.get(opts, :since))
    |> filter_workspace(Keyword.get(opts, :workspace_id))
    |> Ash.Query.select([
      :task_id,
      :base_task_id,
      :provider,
      :tokens_in,
      :tokens_out,
      :thinking_tokens,
      :duration_ms
    ])
    |> Ash.read!()
    |> Enum.group_by(&{&1.provider || "claude", Budget.fold_event_id(&1)})
    |> Enum.map(fn {{provider, _task}, rows} ->
      {provider,
       %{
         tokens: Enum.sum(Enum.map(rows, &tokens/1)),
         wall_clock_s: div(Enum.sum(Enum.map(rows, &(&1.duration_ms || 0))), 1000)
       }}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {provider, tasks} ->
      {provider,
       %{
         tasks: length(tasks),
         tokens: dist(Enum.map(tasks, & &1.tokens)),
         wall_clock_s: dist(Enum.map(tasks, & &1.wall_clock_s))
       }}
    end)
  end

  defp tokens(row), do: (row.tokens_in || 0) + (row.tokens_out || 0) + (row.thinking_tokens || 0)

  defp filter_since(query, nil), do: query
  defp filter_since(query, since), do: Ash.Query.filter(query, occurred_at >= ^since)

  defp filter_workspace(query, nil), do: query
  defp filter_workspace(query, ws_id), do: Ash.Query.filter(query, workspace_id == ^ws_id)

  # Nearest-rank percentiles of a non-empty list.
  defp dist(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    @percentiles
    |> Map.new(fn {name, q} -> {name, Enum.at(sorted, max(ceil(q * n) - 1, 0))} end)
    |> Map.put(:max, List.last(sorted))
  end
end
