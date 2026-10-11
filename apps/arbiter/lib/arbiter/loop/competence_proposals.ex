defmodule Arbiter.Loop.CompetenceProposals do
  @moduledoc """
  Learned competence (bd-d5rdsc, R13 of `docs/design/paced-quota-routing-signals.md`
  §3.3, §7.1, §11): `SubjectStats` measurements become `:competence_matrix`
  `PendingWrite` candidates.

  The hand matrix (R6) is seeded by `Arbiter.Loop.CompetenceGenerator`, which
  turns a window of closed tasks into rows. This module runs the same
  generator over the Loop's own window and keeps only the rows that would move
  the live matrix: a measured `(provider, model, difficulty)` cell the live
  matrix has no cell-level row for, or one whose figures differ from the live
  row beyond a threshold. Each difficulty with such rows becomes ONE proposal
  carrying the changed rows, so a canary (`Arbiter.Loop.Canary`, matrix kind)
  can arm one difficulty at a time, exactly as the routing-tier canary arms one
  `D<n>` tier.

  A proposal is inert, as every `PendingWrite` is. Nothing here writes the
  matrix: an operator applies it (`Arbiter.Loop.Apply`), or the Stage 3 canary
  lands it after its arms have been measured (§7: "New numbers are adopted only
  through a canary").

  Pure. The caller supplies the measured tasks and the live rows.
  """

  alias Arbiter.Agents.Routing.Competence
  alias Arbiter.Loop.CompetenceGenerator
  alias Arbiter.Loop.SubjectStats

  # A measured figure moves the live cell when it differs by this share of the
  # larger of the two (run counts) or by this much (an approve rate).
  @run_change_share 0.2
  @approve_change 0.1

  @type candidate :: map()

  @doc "The relative change in a run count that makes a measured cell worth proposing."
  @spec run_change_share() :: float()
  def run_change_share, do: @run_change_share

  @doc """
  Matrix candidates for `tasks` (`SubjectStats.sample/1` output) against
  `live_rows` (`Competence.rows/0`).

  Options: `:workspace_id`, `:origin` (default `"loop.analyze"`), `:now` (the
  measurement date stamped on each row), `:min_n` (default
  `SubjectStats.min_n/0`).
  """
  @spec candidates([map()], [Competence.row()], keyword()) :: [candidate()]
  def candidates([], _live_rows, _opts), do: []

  def candidates(tasks, live_rows, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    min_n = Keyword.get(opts, :min_n, SubjectStats.min_n())

    tasks
    |> then(&CompetenceGenerator.generate(tasks: &1, until: now, min_n: min_n))
    |> Enum.filter(&changed?(&1, live_rows))
    |> Enum.group_by(& &1["match"]["difficulty"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {difficulty, rows} ->
      candidate(difficulty, rows, tasks, live_rows, opts)
    end)
  end

  @doc """
  Whether the measured `row` would move the live matrix: the live matrix has no
  cell-level (provider, model, difficulty) row for it, or a figure differs
  beyond the thresholds.
  """
  @spec changed?(Competence.row(), [Competence.row()]) :: boolean()
  def changed?(%{"match" => match} = row, live_rows) do
    choice = %{
      provider: match["provider"],
      model: match["model"],
      difficulty: match["difficulty"],
      issue_type: nil
    }

    case Competence.lookup(live_rows, choice) do
      %{rung: 1, row: live} -> differs?(row, live)
      _ -> true
    end
  end

  defp differs?(row, live) do
    run_differs?(row, live, "author_runs") or run_differs?(row, live, "review_runs") or
      approve_differs?(row["round_1_approve"], live["round_1_approve"])
  end

  defp run_differs?(row, live, key) do
    with a when is_number(a) <- row[key], b when is_number(b) <- live[key] do
      abs(a - b) / max(max(abs(a), abs(b)), 1.0e-9) >= @run_change_share
    else
      _ -> false
    end
  end

  defp approve_differs?(a, b) when is_number(a) and is_number(b), do: abs(a - b) >= @approve_change
  defp approve_differs?(_a, _b), do: false

  defp candidate(difficulty, rows, tasks, live_rows, opts) do
    refs = task_refs(rows, tasks)
    cells = Enum.map(rows, &cell_label/1)

    %{
      kind: :competence_matrix,
      scope: :fleet,
      category: "competence matrix D#{difficulty}",
      target: "competence_matrix",
      difficulty: difficulty,
      repo: nil,
      gist:
        "measured competence moves #{length(rows)} D#{difficulty} matrix cell(s): " <>
          Enum.join(cells, ", "),
      target_metric: "first-pass ReviewGate convergence at D#{difficulty}",
      baseline: baseline(rows, live_rows),
      incident_refs: refs,
      task_refs: refs,
      payload: %{
        "difficulty" => difficulty,
        "rows" => rows,
        "n" => rows |> Enum.map(& &1["n"]) |> Enum.sum(),
        "reason" => "measured"
      },
      diff: nil,
      origin: Keyword.get(opts, :origin, "loop.analyze"),
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end

  defp cell_label(%{"match" => m}), do: "#{m["provider"]}/#{m["model"]}"

  # What the live matrix says about the same cells, pre-registered with the
  # proposal so the goalposts cannot move after the apply.
  defp baseline(rows, live_rows) do
    rows
    |> Enum.map(fn %{"match" => m} ->
      live =
        Competence.lookup(live_rows, %{
          provider: m["provider"],
          model: m["model"],
          difficulty: m["difficulty"],
          issue_type: nil
        })

      "#{m["provider"]}/#{m["model"]} " <>
        if(live,
          do: "live rung #{live.rung}: #{fmt(live.author_runs)} author / #{fmt(live.review_runs)} review runs",
          else: "no live row"
        )
    end)
    |> Enum.join("; ")
  end

  defp fmt(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  # The ids of the closed tasks behind the changed rows, so the evidence bar
  # counts real, distinct tasks.
  defp task_refs(rows, tasks) do
    keys = MapSet.new(rows, fn %{"match" => m} -> {m["provider"], m["model"], m["difficulty"]} end)

    tasks
    |> Enum.filter(&MapSet.member?(keys, {canonical(&1.provider), to_string(&1.model), &1.difficulty}))
    |> Enum.map(& &1.task_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp canonical(provider) when provider in ["gemini", "agy", :gemini, :agy], do: "antigravity"
  defp canonical(provider), do: to_string(provider)
end
