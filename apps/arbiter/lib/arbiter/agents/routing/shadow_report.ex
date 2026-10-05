defmodule Arbiter.Agents.Routing.ShadowReport do
  @moduledoc """
  The shadow report (bd-adtnto, R5; `docs/design/paced-quota-routing-signals.md`
  §9.2 item 3): under `routing.provider_selection: scored` with
  `routing.scoring.mode: shadow`, `most_quota` dispatches and the scorer's
  choice is only recorded on `worker_runs.routing_decision["shadow"]`. This
  compares the two — the agreement rate over every decision that consulted the
  rank, and every disagreement with its reason — so an operator can read it
  before setting `enforce`.

  Only a fresh choice (`selected`, `fallback`) is comparable. A pinned
  dispatch, an override and a no-candidate decision never consulted the rank,
  so they are counted apart rather than inflating the agreement rate.

  Read-only. `build/1` is pure; `collect/1` reads the runs; `format/1` renders.
  """

  require Ash.Query

  alias Arbiter.Workers.Run

  @type row :: %{
          run_id: String.t(),
          task_id: String.t() | nil,
          workspace_id: String.t() | nil,
          at: DateTime.t() | nil,
          decision: map()
        }

  @type report :: %{
          shadow_decisions: non_neg_integer(),
          comparable: non_neg_integer(),
          agree: non_neg_integer(),
          disagree: non_neg_integer(),
          agreement_rate: float() | nil,
          not_comparable: %{String.t() => non_neg_integer()},
          disagreements: [map()]
        }

  @doc """
  The runs in the window that carry a shadow record, as `t:row/0`s, oldest
  first. Options: `:since` (default 30 days ago), `:until` (default now) and
  `:workspace_id`.
  """
  @spec collect(keyword()) :: [row()]
  def collect(opts \\ []) do
    until = Keyword.get_lazy(opts, :until, &DateTime.utc_now/0)
    since = Keyword.get_lazy(opts, :since, fn -> DateTime.add(until, -30 * 86_400, :second) end)

    Run
    |> Ash.Query.filter(
      not is_nil(routing_decision) and started_at >= ^since and started_at <= ^until
    )
    |> maybe_workspace(Keyword.get(opts, :workspace_id))
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.Query.select([:id, :base_task_id, :workspace_id, :started_at, :routing_decision])
    |> Ash.read!()
    |> Enum.filter(&match?(%{"shadow" => %{}}, &1.routing_decision))
    |> Enum.map(fn run ->
      %{
        run_id: run.id,
        task_id: run.base_task_id,
        workspace_id: run.workspace_id,
        at: run.started_at,
        decision: run.routing_decision
      }
    end)
  end

  defp maybe_workspace(query, nil), do: query
  defp maybe_workspace(query, ws_id), do: Ash.Query.filter(query, workspace_id == ^ws_id)

  @doc "Summarise `rows` (`t:row/0`); rows without a shadow record are ignored."
  @spec build([row()]) :: report()
  def build(rows) do
    shadowed = Enum.filter(rows, &match?(%{decision: %{"shadow" => %{}}}, &1))
    {comparable, other} = Enum.split_with(shadowed, &(shadow(&1)["comparable"] == true))
    {agree, disagree} = Enum.split_with(comparable, &(shadow(&1)["agrees"] == true))

    %{
      shadow_decisions: length(shadowed),
      comparable: length(comparable),
      agree: length(agree),
      disagree: length(disagree),
      agreement_rate: if(comparable != [], do: length(agree) / length(comparable)),
      not_comparable: other |> Enum.frequencies_by(& &1.decision["outcome"]),
      disagreements: Enum.map(disagree, &disagreement/1)
    }
  end

  defp shadow(%{decision: %{"shadow" => shadow}}), do: shadow

  defp disagreement(%{decision: decision} = row) do
    shadow = shadow(row)

    %{
      run_id: row.run_id,
      task_id: row.task_id,
      workspace_id: row.workspace_id,
      at: row.at,
      outcome: decision["outcome"],
      actual: pick_label(decision),
      scored: pick_label(shadow["pick"]),
      reason: shadow["reason"]
    }
  end

  defp pick_label(%{} = pick) do
    [pick["account_slug"], pick["model"]] |> Enum.reject(&is_nil/1) |> Enum.join(" / ")
  end

  defp pick_label(_), do: "(none)"

  @doc "Render a `t:report/0` as plain text."
  @spec format(report()) :: String.t()
  def format(%{shadow_decisions: 0}) do
    "routing shadow report: no shadow decisions in the window " <>
      "(needs routing.provider_selection: scored with routing.scoring.mode: shadow)"
  end

  def format(report) do
    header =
      "routing shadow report: #{report.shadow_decisions} shadow decisions, " <>
        "#{report.comparable} comparable, #{report.agree} agree, #{report.disagree} disagree" <>
        rate_text(report.agreement_rate)

    skipped =
      case Enum.sort(report.not_comparable) do
        [] ->
          []

        counts ->
          ["  not comparable: " <> Enum.map_join(counts, ", ", fn {k, v} -> "#{k} #{v}" end)]
      end

    lines =
      Enum.map(report.disagreements, fn d ->
        "  #{DateTime.to_iso8601(d.at)}  run #{d.run_id}  task #{d.task_id}  " <>
          "actual: #{d.actual}  scored: #{d.scored}  reason: #{d.reason}"
      end)

    Enum.join([header | skipped] ++ lines, "\n")
  end

  defp rate_text(nil), do: ""
  defp rate_text(rate), do: ", agreement #{Float.round(rate * 100, 1)}%"
end
