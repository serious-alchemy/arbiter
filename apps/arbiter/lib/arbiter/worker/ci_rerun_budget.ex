defmodule Arbiter.Worker.CiRerunBudget do
  @moduledoc """
  One per-SHA tally of the automatic CI re-runs a task's PR head has had
  (GitHub #1284).

  Every site that re-runs CI on its own is bounded by its own counter — the
  Watchdog's known-flake re-run (1 per head), the triage re-runs
  (`merge.ci.triage_rerun_budget`, 2), the cancelled-run re-runs (2), the
  not-the-merge-head hold re-run (1), the ReviewGate's CI-wait re-run and its
  no-change re-run — and the counters do not know about each other, so on one
  commit they add up. In the 7 days to 2026-11-05 vstim ran 99 pipelines on a
  commit that had already failed (10,438 runner-minutes; 42 passed the second
  time, 57 failed again). This module is the shared bound: all sites ask
  `check/3` before they re-run and call `record/3` once the forge accepted it.

  The tally lives on the ticket (`review_gate_state["ci_rerun_budget"]`), so a
  restarted Watchdog or a fresh ReviewGate inherits it. It holds the **newest
  head only**: a push gives the PR a new SHA, which starts again from zero.

  A refused `check/3` is returned to the caller as a failed re-run, which every
  site already handles by dispatching a fix pass briefed with the failing jobs
  (or, for cancelled runs, by escalating); `note_capped/4` writes one ticket note
  per head saying so.

  A pipeline the forge refused to run (failed, zero jobs — `Arbiter.Worker.CiUnrun`,
  bd-7eve8a) never reaches a re-run site, so it is never tallied.

  Manual re-runs (`ci_rerun` from the coordinator) are neither refused nor — when
  the head is not known — counted; a worker's own `ci_rerun` call is counted and
  refused at the cap, see `Arbiter.Worker.Watchdog.rerun_ci/2`.
  """

  alias Arbiter.Mergers
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Worker.ReviewCi

  require Logger

  # Why 2: of the 99 same-commit re-runs in the sample, 42 passed (a flake the
  # first re-run cleared), so one re-run is clearly worth its pipeline. A second
  # keeps the existing `triage_rerun_budget` (2) usable for an infra failure,
  # which a first re-run can miss. Beyond that every site has already seen the
  # head red twice and the third attempt is a coin flip against a 36-minute
  # failing partition; a fix pass is cheaper. Lower it per workspace/repo with
  # `merge.ci.max_reruns_per_sha` (0 turns automatic re-runs off).
  @default_limit 2

  @key "ci_rerun_budget"

  @type info :: %{
          count: non_neg_integer(),
          limit: non_neg_integer(),
          sources: %{String.t() => pos_integer()}
        }

  @doc "The default for `merge.ci.max_reruns_per_sha`."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc """
  Automatic re-runs allowed per head (`merge.ci.max_reruns_per_sha`, a repo
  entry overriding the workspace's). Anything but a non-negative integer is the
  default.
  """
  @spec limit(Workspace.t() | nil, String.t() | nil) :: non_neg_integer()
  def limit(%Workspace{} = workspace, repo) do
    case workspace |> Mergers.merge_config(repo) |> Map.get("ci") do
      %{"max_reruns_per_sha" => n} when is_integer(n) and n >= 0 -> n
      _ -> @default_limit
    end
  rescue
    _ -> @default_limit
  end

  def limit(_workspace, _repo), do: @default_limit

  @doc """
  `:ok` when `sha` may be re-run again, `{:capped, info}` when it has had
  `limit` re-runs already. An unknown `sha` or an unreadable ticket never refuses.
  """
  @spec check(String.t(), String.t() | nil, non_neg_integer()) :: :ok | {:capped, info()}
  def check(_task_id, sha, _limit) when sha in [nil, ""], do: :ok

  def check(task_id, sha, limit) do
    entry = entry_for(task_id, sha)

    if entry.count >= limit,
      do: {:capped, %{count: entry.count, limit: limit, sources: entry.sources}},
      else: :ok
  end

  @doc "Whether the cap note was already written for `sha`."
  @spec noted?(String.t(), String.t() | nil) :: boolean()
  def noted?(_task_id, sha) when sha in [nil, ""], do: true
  def noted?(task_id, sha), do: entry_for(task_id, sha).noted

  @doc "Re-runs `sha` has had. `0` for a head the ticket has no tally for."
  @spec count(String.t(), String.t() | nil) :: non_neg_integer()
  def count(_task_id, sha) when sha in [nil, ""], do: 0
  def count(task_id, sha), do: entry_for(task_id, sha).count

  @doc """
  Book one re-run of `sha` made by `source` (an atom: `:flake`, `:triage`,
  `:cancelled`, `:hold`, `:review_gate`, `:worker`...). Returns the new count.
  Replaces the tally of any older head. Best-effort: a failed write is logged.
  """
  @spec record(String.t(), String.t() | nil, atom() | String.t()) :: {:ok, non_neg_integer()}
  def record(_task_id, sha, _source) when sha in [nil, ""], do: {:ok, 0}

  def record(task_id, sha, source) do
    entry = entry_for(task_id, sha)
    source = to_string(source)
    count = entry.count + 1

    write(task_id, %{
      "sha" => sha,
      "count" => count,
      "sources" => Map.update(entry.sources, source, 1, &(&1 + 1)),
      "noted" => entry.noted
    })

    {:ok, count}
  end

  @doc """
  Append one note to the ticket saying the head hit the cap and which jobs are
  failing, once per head (`:already_noted` after that). The fix pass (or park)
  the refused re-run turns into is briefed with the same jobs.
  """
  @spec note_capped(String.t(), String.t() | nil, info(), [String.t()]) ::
          :noted | :already_noted | :skipped
  def note_capped(_task_id, sha, _info, _jobs) when sha in [nil, ""], do: :skipped

  def note_capped(task_id, sha, info, jobs) do
    entry = entry_for(task_id, sha)

    if entry.noted do
      :already_noted
    else
      write(task_id, %{
        "sha" => sha,
        "count" => entry.count,
        "sources" => entry.sources,
        "noted" => true
      })

      append_note(task_id, sha, info, jobs)
      :noted
    end
  end

  defp append_note(task_id, sha, info, jobs) do
    by =
      info.sources
      |> Enum.sort()
      |> Enum.map_join(", ", fn {source, n} -> "#{source} x#{n}" end)

    text =
      "## CI re-run cap reached (#{DateTime.to_iso8601(DateTime.utc_now())})\n\n" <>
        "re-run cap reached on head #{sha}: #{info.count} automatic re-run(s) already made " <>
        "(limit #{info.limit}, `merge.ci.max_reruns_per_sha`)" <>
        if(by == "", do: "", else: " [#{by}]") <>
        ". No further pipeline is started on this commit; a still-red head goes to a fix pass " <>
        "or, for cancelled runs, a coordinator escalation. Failing jobs: " <>
        if(jobs == [], do: "(none named)", else: Enum.join(jobs, ", ")) <> ".\n"

    Logger.warning("CiRerunBudget: task=#{task_id} head=#{sha}: #{String.trim(text)}")

    with {:ok, task} <- Ash.get(Issue, task_id),
         {:ok, _} <- Ash.update(task, %{append_notes: text}, action: :update) do
      :ok
    else
      other ->
        Logger.debug("CiRerunBudget: ticket note for #{task_id} not written: #{inspect(other)}")
        :ok
    end
  rescue
    _ -> :ok
  end

  defp entry_for(task_id, sha) do
    case Ash.get(Issue, task_id) do
      {:ok, %{review_gate_state: %{@key => %{"sha" => stored} = raw}}} when is_binary(stored) ->
        if stored == sha or ReviewCi.same_sha?(stored, sha), do: parse(raw), else: empty()

      _ ->
        empty()
    end
  rescue
    _ -> empty()
  end

  defp parse(raw) do
    %{
      count: if(is_integer(raw["count"]) and raw["count"] > 0, do: raw["count"], else: 0),
      sources:
        case raw["sources"] do
          %{} = m -> Map.new(m, fn {k, v} -> {to_string(k), v} end)
          _ -> %{}
        end,
      noted: raw["noted"] == true
    }
  end

  defp empty, do: %{count: 0, sources: %{}, noted: false}

  defp write(task_id, entry) do
    case PullRequest.record_review_gate(task_id, %{@key => entry}) do
      :ok -> :ok
      {:error, why} -> Logger.debug("CiRerunBudget: tally write failed: #{inspect(why)}")
    end
  rescue
    _ -> :ok
  end
end
