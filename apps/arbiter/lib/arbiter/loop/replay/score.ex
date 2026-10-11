defmodule Arbiter.Loop.Replay.Score do
  @moduledoc """
  Scores one offline replay against the known-good result (R15, bd-c7lx65;
  `docs/design/paced-quota-routing-signals.md` §7.2). Pure.

    * **The main score is round-1 convergence** (`converged?/1`): the scoring
      reviewer's first verdict against the ticket's acceptance criteria, read
      exactly as the live ReviewGate records `review_gate_rounds.converged` for
      a first round: an APPROVE, on a non-empty net diff, whose CRITERIA
      breakdown marks nothing `[NOT MET]` when the ticket states criteria (and
      has a breakdown at all). It is the same signal `Loop.SubjectStats` and
      `Loop.Canary.Metrics` read as the round-1 approve rate. One difference is
      deliberate: the live gate re-prompts a malformed verdict once, a replay
      does not, because a second reviewer run would spend quota the replay was
      not admitted for.
    * **The repo's tests** count beside it, recorded by `Arbiter.Loop.Replay`.
    * **Diff overlap with the merged change** (`overlap/2`) is a weak secondary
      signal: the Jaccard index of the touched files and of the added lines. A
      different, equally good solution can score low on it.
  """

  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Worker.ReviewVerification

  @type verdict :: :approve | :request_changes | :no_verdict
  @type change :: %{files: [String.t()], patch: String.t()}
  @type overlap :: %{files: float() | nil, lines: float() | nil}

  # Added lines this short are structure (`end`, `}`, `]);`), shared by any two
  # changes in the same language, so they would inflate the line overlap.
  @min_line_length 4

  @doc """
  The reviewer's verdict from its output lines, with the findings (the text from
  the verdict line on). The first `VERDICT:` line wins, as in the live gate
  (`Arbiter.Worker.ReviewGate.parse_verdict/1`), so pass the reviewer's own
  output, never the prompt (whose protocol example would match).
  """
  @spec verdict([String.t()]) :: {verdict(), String.t()}
  def verdict(lines) when is_list(lines) do
    case ReviewGate.parse_verdict(lines) do
      {:approve, findings} -> {:approve, findings}
      {:request_changes, findings} -> {:request_changes, findings}
      _ -> {:no_verdict, ""}
    end
  end

  @doc """
  Whether a first-round verdict converged, by the live gate's rule (see the
  moduledoc). `net_diff_empty?` is whether the committed change nets to nothing
  against the replay's base.
  """
  @spec converged?(%{
          verdict: verdict(),
          findings: String.t() | nil,
          acceptance: String.t() | nil,
          net_diff_empty?: boolean()
        }) :: boolean()
  def converged?(%{verdict: :approve, net_diff_empty?: false} = score) do
    not criteria?(score.acceptance) or
      (ReviewVerification.criteria_present?(score.findings) and
         not ReviewVerification.unmet_criteria?(score.findings))
  end

  def converged?(_score), do: false

  @doc "Whether the ticket states acceptance criteria, as the live gate decides it."
  @spec criteria?(String.t() | nil) :: boolean()
  def criteria?(acceptance),
    do: is_binary(acceptance) and String.trim(acceptance) not in ["", "(none)"]

  @doc """
  The overlap of the replay's change with the known-good one: the Jaccard index
  of the touched files and of the added lines. `nil` for a side neither change
  has anything on; `0.0` when only one does.
  """
  @spec overlap(change(), change()) :: overlap()
  def overlap(replay, known_good) do
    %{
      files: jaccard(MapSet.new(replay.files), MapSet.new(known_good.files)),
      lines: jaccard(added_lines(replay.patch), added_lines(known_good.patch))
    }
  end

  @doc """
  The added lines of a unified diff, trimmed, without the `+++` file headers,
  blank lines or lines too short to be more than structure.
  """
  @spec added_lines(String.t()) :: MapSet.t(String.t())
  def added_lines(patch) when is_binary(patch) do
    patch
    |> String.split("\n")
    |> Enum.flat_map(fn
      "+++" <> _ -> []
      "+" <> line -> [String.trim(line)]
      _ -> []
    end)
    |> Enum.filter(&(String.length(&1) >= @min_line_length))
    |> MapSet.new()
  end

  defp jaccard(a, b) do
    union = MapSet.union(a, b)

    case MapSet.size(union) do
      0 -> nil
      n -> MapSet.size(MapSet.intersection(a, b)) / n
    end
  end
end
