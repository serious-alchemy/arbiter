defmodule Arbiter.Agents.Routing.ShadowReport do
  @moduledoc """
  The shadow report (bd-adtnto, R5; `docs/design/paced-quota-routing-signals.md`
  §9.2 item 3): under `routing.provider_selection: scored` with
  `routing.scoring.mode: shadow`, `most_quota` dispatches and the scorer's
  choice is only recorded on `worker_runs.routing_decision["shadow"]`. This
  compares the two — the agreement rate over every decision that consulted the
  rank, and every disagreement with its reason — so an operator can read it
  before setting `enforce`.

  It keeps comparing after `enforce` (bd-dde4l7): there the scorer dispatches
  and the headroom ranking is the shadow (`shadow["policy"] == "headroom"`), so
  the report is split by mode and labelled by which policy was live and which
  was shadowed. A candidate competence matrix (`routing_decision["shadow_candidate"]`)
  is reported separately — live scorer vs candidate scorer, with the
  `(difficulty, issue_type)` cells where they differ.

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

  @type summary :: %{
          shadow_decisions: non_neg_integer(),
          comparable: non_neg_integer(),
          agree: non_neg_integer(),
          disagree: non_neg_integer(),
          agreement_rate: float() | nil,
          not_comparable: %{String.t() => non_neg_integer()},
          disagreements: [map()]
        }

  @type report :: %{
          required(:shadow_decisions) => non_neg_integer(),
          required(:comparable) => non_neg_integer(),
          required(:agree) => non_neg_integer(),
          required(:disagree) => non_neg_integer(),
          required(:agreement_rate) => float() | nil,
          required(:not_comparable) => %{String.t() => non_neg_integer()},
          required(:disagreements) => [map()],
          required(:modes) => %{String.t() => map()},
          required(:candidate) => map()
        }

  @doc """
  The runs in the window that carry a shadow or a candidate record, as `t:row/0`s, oldest
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
    |> Enum.filter(&recorded?(&1.routing_decision))
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

  defp recorded?(%{"shadow" => %{}}), do: true
  defp recorded?(%{"shadow_candidate" => %{}}), do: true
  defp recorded?(_), do: false

  defp maybe_workspace(query, nil), do: query
  defp maybe_workspace(query, ws_id), do: Ash.Query.filter(query, workspace_id == ^ws_id)

  @doc """
  Summarise `rows` (`t:row/0`); rows without a shadow record are ignored.

  The top-level counts cover every shadow record. `:modes` splits them by the
  mode that dispatched (`"shadow"`: headroom live, scorer shadowed; `"enforce"`:
  scorer live, headroom shadowed), each with its own agreement rate and
  disagreements. `:candidate` is the live-vs-candidate-matrix comparison.
  """
  @spec build([row()]) :: report()
  def build(rows) do
    shadowed = Enum.filter(rows, &match?(%{decision: %{"shadow" => %{}}}, &1))

    shadowed
    |> summarise()
    |> Map.put(:modes, %{
      "shadow" => mode_summary(shadowed, "shadow", "headroom", "scorer"),
      "enforce" => mode_summary(shadowed, "enforce", "scorer", "headroom")
    })
    |> Map.put(:candidate, candidate_summary(rows))
  end

  defp summarise(shadowed) do
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

  defp mode_summary(shadowed, mode, live, shadowed_policy) do
    shadowed
    |> Enum.filter(&(mode_of(&1) == mode))
    |> summarise()
    |> Map.merge(%{live: live, shadowed: shadowed_policy})
  end

  # Records from before `scoring_mode` was a dispatch label are shadow-mode ones.
  defp mode_of(%{decision: decision}), do: decision["scoring_mode"] || "shadow"

  defp shadow(%{decision: %{"shadow" => shadow}}), do: shadow

  defp disagreement(%{decision: decision} = row) do
    shadow = shadow(row)
    mode = mode_of(row)
    shadowed = pick_label(shadow["pick"])

    %{
      run_id: row.run_id,
      task_id: row.task_id,
      workspace_id: row.workspace_id,
      at: row.at,
      mode: mode,
      live_policy: if(mode == "enforce", do: "scorer", else: "headroom"),
      shadow_policy: shadow["policy"] || "scorer",
      outcome: decision["outcome"],
      actual: pick_label(decision),
      shadowed: shadowed,
      # The scorer's pick: the shadow's in `shadow` mode, the dispatched one in `enforce`.
      scored: if(mode == "enforce", do: pick_label(decision), else: shadowed),
      reason: shadow["reason"]
    }
  end

  defp candidate_summary(rows) do
    recorded = Enum.filter(rows, &match?(%{decision: %{"shadow_candidate" => %{}}}, &1))
    {comparable, other} = Enum.split_with(recorded, &(candidate(&1)["comparable"] == true))
    {agree, disagree} = Enum.split_with(comparable, &(candidate(&1)["agrees"] == true))

    %{
      decisions: length(recorded),
      comparable: length(comparable),
      agree: length(agree),
      disagree: length(disagree),
      agreement_rate: if(comparable != [], do: length(agree) / length(comparable)),
      not_comparable: other |> Enum.frequencies_by(& &1.decision["outcome"]),
      cells: candidate_cells(comparable),
      disagreements: Enum.map(disagree, &candidate_disagreement/1)
    }
  end

  defp candidate(%{decision: %{"shadow_candidate" => candidate}}), do: candidate

  # The (difficulty, issue_type) cells where live and candidate pick differently,
  # worst first.
  defp candidate_cells(comparable) do
    comparable
    |> Enum.group_by(&{candidate(&1)["difficulty"], candidate(&1)["issue_type"]})
    |> Enum.map(fn {{difficulty, issue_type}, cell_rows} ->
      disagree = Enum.count(cell_rows, &(candidate(&1)["agrees"] == false))

      %{
        difficulty: difficulty,
        issue_type: issue_type,
        comparable: length(cell_rows),
        disagree: disagree,
        disagreement_rate: disagree / length(cell_rows)
      }
    end)
    |> Enum.filter(&(&1.disagree > 0))
    |> Enum.sort_by(&{-&1.disagreement_rate, -&1.disagree, &1.difficulty, &1.issue_type})
  end

  defp candidate_disagreement(%{decision: decision} = row) do
    candidate = candidate(row)

    %{
      run_id: row.run_id,
      task_id: row.task_id,
      workspace_id: row.workspace_id,
      at: row.at,
      mode: mode_of(row),
      outcome: decision["outcome"],
      difficulty: candidate["difficulty"],
      issue_type: candidate["issue_type"],
      live: pick_label(candidate["live_pick"]),
      candidate: pick_label(candidate["pick"])
    }
  end

  defp pick_label(%{} = pick) do
    [pick["account_slug"], pick["model"]] |> Enum.reject(&is_nil/1) |> Enum.join(" / ")
  end

  defp pick_label(_), do: "(none)"

  @doc "Render a `t:report/0` as plain text."
  @spec format(report()) :: String.t()
  def format(%{shadow_decisions: 0, candidate: %{decisions: 0}}) do
    "routing shadow report: no shadow decisions in the window " <>
      "(needs routing.provider_selection: scored; the headroom baseline is recorded in " <>
      "either routing.scoring.mode)"
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
          "[#{d.mode}]  actual: #{d.actual}  #{d.shadow_policy}: #{d.shadowed}  reason: #{d.reason}"
      end)

    Enum.join(
      [header | skipped] ++ mode_lines(report.modes) ++ lines ++ candidate_lines(report.candidate),
      "\n"
    )
  end

  defp mode_lines(modes) do
    for mode <- ["enforce", "shadow"], %{shadow_decisions: n} = m = modes[mode], n > 0 do
      "  #{mode} (#{m.live} live, #{m.shadowed} shadow): #{m.comparable} comparable, " <>
        "#{m.agree} agree, #{m.disagree} disagree#{rate_text(m.agreement_rate)}"
    end
  end

  defp candidate_lines(%{decisions: 0}), do: []

  defp candidate_lines(c) do
    header =
      "candidate matrix vs live: #{c.decisions} decisions, #{c.comparable} comparable, " <>
        "#{c.agree} agree, #{c.disagree} disagree#{rate_text(c.agreement_rate)}"

    skipped =
      case Enum.sort(c.not_comparable) do
        [] ->
          []

        counts ->
          ["  not comparable: " <> Enum.map_join(counts, ", ", fn {k, v} -> "#{k} #{v}" end)]
      end

    cells =
      Enum.map(c.cells, fn cell ->
        "  cell D#{cell.difficulty} #{cell.issue_type || "(untyped)"}: " <>
          "#{cell.disagree} of #{cell.comparable} differ " <>
          "(#{Float.round(cell.disagreement_rate * 100, 1)}%)"
      end)

    lines =
      Enum.map(c.disagreements, fn d ->
        "  #{DateTime.to_iso8601(d.at)}  run #{d.run_id}  task #{d.task_id}  " <>
          "D#{d.difficulty} #{d.issue_type || "(untyped)"}  live: #{d.live}  candidate: #{d.candidate}"
      end)

    [header | skipped] ++ cells ++ lines
  end

  defp rate_text(nil), do: ""
  defp rate_text(rate), do: ", agreement #{Float.round(rate * 100, 1)}%"
end
