defmodule Arbiter.Loop.Replay.Evidence do
  @moduledoc """
  Offline replay evidence, summarised (R15, bd-c7lx65;
  `docs/design/paced-quota-routing-signals.md` §7.2): "recorded as its own
  source, with its own weight, and it never reaches the live matrix without a
  canary".

  `summarize/2` turns scored replays (`Arbiter.Loop.ReplayRun`) into one row
  per competence cell, keyed as the matrix's finest rung is (provider, model,
  difficulty at dispatch, issue type): `n`, the round-1 approve rate (the share
  that converged), how many had the repo's tests run and the share that
  passed, and the mean overlap with the merged change. Every row says
  `"source" => "replay"` and carries `"weight"`, how much one replayed task
  counts against one live task when a reader blends the two (default
  `weight/0`; the design leaves the value open, O10). Refused, unscored, failed and
  running replays are not evidence.

  This module only reads. Nothing here, nor anywhere else, writes replay
  evidence into the competence matrix, `worker_runs` or `review_gate_rounds`:
  a new model's first matrix row still goes through a canary.
  """

  require Ash.Query

  alias Arbiter.Loop.ReplayRun

  @weight 0.5
  @default_window_days 30
  @latest 10

  @type cell :: %{String.t() => term()}
  @type report :: %{
          since: DateTime.t(),
          until: DateTime.t(),
          counts: %{atom() => non_neg_integer()},
          cells: [cell()],
          latest: [ReplayRun.t()]
        }

  @doc "The default weight of one replayed task against one live one."
  @spec weight() :: float()
  def weight, do: @weight

  @doc "Scored replays, one row per cell. Options: `:weight`."
  @spec summarize([ReplayRun.t()], keyword()) :: [cell()]
  def summarize(runs, opts \\ []) do
    weight = Keyword.get(opts, :weight, @weight)

    runs
    |> Enum.filter(&(&1.state == :scored))
    |> Enum.group_by(&{&1.provider, &1.model, &1.difficulty, &1.issue_type})
    |> Enum.map(fn {{provider, model, difficulty, type}, rows} ->
      converged = Enum.count(rows, &(&1.converged == true))
      tested = Enum.filter(rows, &(&1.tests in [:passed, :failed, :timeout]))

      %{
        "source" => "replay",
        "weight" => weight,
        "match" => %{
          "provider" => provider,
          "model" => model,
          "difficulty" => difficulty,
          "issue_type" => type
        },
        "n" => length(rows),
        "tasks" => rows |> Enum.uniq_by(& &1.task_id) |> length(),
        "converged" => converged,
        "round_1_approve" => converged / length(rows),
        "tested_n" => length(tested),
        "tests_passed" => ratio(Enum.count(tested, &(&1.tests == :passed)), length(tested)),
        "file_overlap" => mean(rows, :file_overlap),
        "line_overlap" => mean(rows, :line_overlap)
      }
    end)
    |> Enum.sort_by(fn %{"match" => m} ->
      {m["provider"], m["model"], m["difficulty"] || -1, m["issue_type"] || ""}
    end)
  end

  @doc """
  The replays recorded in a window: counts by state, the evidence cells, and
  the latest few. Options: `:since` / `:until` (default the last
  #{@default_window_days} days), `:workspace_id`, `:weight`.
  """
  @spec report(keyword()) :: report()
  def report(opts \\ []) do
    until = Keyword.get_lazy(opts, :until, &DateTime.utc_now/0)
    since = Keyword.get(opts, :since) || DateTime.add(until, -@default_window_days * 86_400)

    runs =
      ReplayRun
      |> Ash.Query.filter(started_at >= ^since and started_at < ^until)
      |> then(fn query ->
        case Keyword.get(opts, :workspace_id) do
          nil -> query
          ws -> Ash.Query.filter(query, workspace_id == ^ws)
        end
      end)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.read!()

    %{
      since: since,
      until: until,
      counts: Enum.frequencies_by(runs, & &1.state),
      cells: summarize(runs, Keyword.take(opts, [:weight])),
      latest: Enum.take(runs, @latest)
    }
  end

  @doc "`report/1` as text, for `Arbiter.Release.replay_report/1` and the mix task."
  @spec format(report()) :: String.t()
  def format(%{latest: []} = report) do
    "No offline replays recorded between #{day(report.since)} and #{day(report.until)}.\n"
  end

  def format(report) do
    total = report.counts |> Map.values() |> Enum.sum()

    states =
      ReplayRun.states()
      |> Enum.map_join(", ", &"#{Map.get(report.counts, &1, 0)} #{&1}")

    """
    Offline replays (R15), #{day(report.since)} to #{day(report.until)}: #{total} recorded (#{states}).

    #{cells(report.cells)}
    Latest:
    #{Enum.map_join(report.latest, "\n", &latest_line/1)}
    """
  end

  @doc "A one-line account of one `Arbiter.Loop.Replay.run/1` result."
  @spec describe(term()) :: String.t()
  def describe({_tag, %ReplayRun{} = run}), do: latest_line(run)
  def describe({:error, reason}), do: "replay not started: #{inspect(reason)}"
  def describe(other), do: inspect(other)

  @doc """
  `Arbiter.Loop.Replay.Subject.candidates/1` as text: each closed ticket, and
  whether it can be replayed (or why not).
  """
  @spec format_candidates([{map(), {:ok, map()} | {:error, term()}}]) :: String.t()
  def format_candidates([]), do: "No closed, completed tickets match.\n"

  def format_candidates(candidates) do
    Enum.map_join(candidates, "", fn {issue, resolution} ->
      head =
        "- #{issue.id} D#{issue.difficulty || "?"} #{issue.issue_type} #{inspect(issue.title)}"

      case resolution do
        {:ok, subject} ->
          "#{head}: replayable at #{short(subject.base_sha)} " <>
            "(known-good #{short(subject.known_good_sha)}, #{subject.provenance})\n"

        {:error, reason} ->
          "#{head}: not replayable, #{inspect(reason)}\n"
      end
    end)
  end

  # ---- text ------------------------------------------------------------------

  defp cells([]), do: "No scored replays in this window.\n"

  defp cells(cells) do
    weight = cells |> List.first() |> Map.fetch!("weight")

    rows =
      Enum.map_join(cells, "\n", fn c ->
        m = c["match"]

        "| #{m["provider"]} | #{m["model"]} | #{m["difficulty"]} | #{m["issue_type"]} | #{c["n"]} | " <>
          "#{pct(c["round_1_approve"])} (#{c["converged"]}/#{c["n"]}) | " <>
          "#{tests(c)} | #{num(c["file_overlap"])} | #{num(c["line_overlap"])} |"
      end)

    """
    Replay evidence by cell: its own source (weight #{weight}), never read into the live competence matrix.

    | provider | model | D | type | n | round-1 approve | tests passed | file overlap | line overlap |
    |---|---|---|---|---|---|---|---|---|
    #{rows}
    """
  end

  defp tests(%{"tested_n" => 0}), do: "-"

  defp tests(%{"tested_n" => n, "tests_passed" => share}),
    do: "#{pct(share)} (#{round(share * n)}/#{n})"

  defp latest_line(%ReplayRun{} = run) do
    "- #{stamp(run.started_at)} #{run.task_id} on #{run.model}: #{run.state}#{outcome(run)}"
  end

  defp outcome(%ReplayRun{state: :scored, converged: converged} = run) do
    ", #{if converged, do: "converged", else: "not converged"} " <>
      "(verdict #{run.verdict || "none"}, tests #{run.tests || "not run"}, " <>
      "overlap #{num(run.file_overlap)}/#{num(run.line_overlap)})" <>
      if(run.reason, do: "; " <> run.reason, else: "")
  end

  defp outcome(%ReplayRun{reason: reason}) when is_binary(reason), do: ", " <> reason
  defp outcome(_run), do: ""

  defp ratio(_count, 0), do: nil
  defp ratio(count, total), do: count / total

  defp mean(rows, field) do
    case Enum.filter(Enum.map(rows, &Map.get(&1, field)), &is_number/1) do
      [] -> nil
      values -> Enum.sum(values) / length(values)
    end
  end

  defp pct(nil), do: "-"
  defp pct(share), do: "#{round(share * 100)}%"

  defp num(nil), do: "-"
  defp num(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short(_), do: "?"

  defp day(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp stamp(%DateTime{} = at),
    do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601() |> String.replace("T", " ")

  defp stamp(_), do: "?"
end
