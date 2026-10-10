defmodule Arbiter.TrustFixtures do
  @moduledoc """
  Rows for the earned-trust tests (G18, `Arbiter.Loop.Trust`): closed tickets
  with their main implementer runs and first review round, guardrail events at
  chosen times, and subject rules. Runs, rounds and events are written with raw
  SQL so their timestamps are the fixture's, not the clock's.
  """

  alias Arbiter.Guardrails.Subjects
  alias Arbiter.Repo
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-10-10 12:00:00.000000Z]

  @doc "The fold's `now` in every trust test."
  def now, do: @now

  @doc "A trust cutover before every fixture event, so each one is acted on."
  def cutover, do: ~U[2026-01-01 00:00:00.000000Z]

  def workspace! do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "trust-#{n}", prefix: "tr#{n}"})
    ws
  end

  @doc "A subject rule, written with operator authority."
  def rule!(attrs) do
    {:ok, row} = Subjects.put(attrs, :operator)
    row
  end

  @doc """
  A ticket with one main implementer run of `subject` (`{provider, model}`) and
  its first review round. Returns the run id.

  Options: `:at` (the run's start), `:difficulty` (1), `:repo` ("arbiter"),
  `:stop` (the run's `stop_category`), `:failure` (its `failure_reason`),
  `:harness` (`harness_version`), `:round1` (`true` approved, `false` rejected —
  a second, approved round follows —, `nil` none), `:open` (the ticket stays
  active), `:adapter` (`worker_runs.provider`, default the subject's),
  `:decision` (record the subject in `guardrail_decision`) and `:served` (the
  model the run reported, `worker_runs.model`, when it differs from the
  subject's).
  """
  def task!(ws, id, subject, opts \\ []) do
    at = Keyword.get(opts, :at, ~U[2026-10-01 10:00:00Z])
    difficulty = Keyword.get(opts, :difficulty, 1)

    issue!(ws, id, difficulty, if(opts[:open], do: nil, else: DateTime.add(at, 4 * 3600)))
    run_id = run!(ws, id, subject, Keyword.put(opts, :started_at, at))

    case Keyword.get(opts, :round1, true) do
      nil ->
        :ok

      true ->
        round!(id, 1, true, DateTime.add(at, 3600))

      false ->
        round!(id, 1, false, DateTime.add(at, 3600))
        round!(id, 2, true, DateTime.add(at, 7200))
    end

    run_id
  end

  @doc "A ticket in `ws`, closed as completed at `closed_at` (`nil`: left active)."
  def issue!(ws, id, difficulty, closed_at) do
    created = iso(~U[2026-08-01 00:00:00Z])

    Repo.query!(
      """
      INSERT INTO issues (id, workspace_id, title, issue_type, difficulty, priority,
                          tracker_type, state, created_at, updated_at)
      VALUES (?1, ?2, ?1, 'feature', ?3, 2, 'none', 'active', ?4, ?4)
      """,
      [id, ws.id, difficulty, created]
    )

    if closed_at do
      Repo.query!(
        """
        UPDATE issues SET state = 'closed', close_reason = 'completed', closed_at = ?2,
                          updated_at = ?2
        WHERE id = ?1
        """,
        [id, iso(closed_at)]
      )
    end

    :ok
  end

  @doc "A run of `subject`; `kind`/`role` default to a main implementer run. Returns its id."
  def run!(ws, task_id, {provider, model}, opts) do
    id = Ecto.UUID.generate()
    started = Keyword.fetch!(opts, :started_at)

    decision =
      if opts[:decision] do
        Jason.encode!(%{
          "eligible" => true,
          "role" => "implementer",
          "subject" => %{"provider" => provider, "model" => model}
        })
      end

    Repo.query!(
      """
      INSERT INTO worker_runs (id, task_id, base_task_id, workspace_id, repo, kind, role, model,
                               provider, difficulty_at_dispatch, state, outcome, stop_category,
                               failure_reason, harness_version, guardrail_decision, started_at,
                               inserted_at, updated_at)
      VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'finished', 'succeeded', ?10, ?11, ?12, ?13,
              ?14, ?14, ?14)
      """,
      [
        id,
        task_id,
        ws.id,
        Keyword.get(opts, :repo, "arbiter"),
        Keyword.get(opts, :kind, "implement"),
        Keyword.get(opts, :role, "base"),
        Keyword.get(opts, :served, model),
        Keyword.get(opts, :adapter, provider),
        Keyword.get(opts, :difficulty, 1),
        opts[:stop],
        opts[:failure],
        opts[:harness],
        decision,
        iso(started)
      ]
    )

    id
  end

  def round!(task_id, round, converged, at) do
    Repo.query!(
      """
      INSERT INTO review_gate_rounds (id, task_id, round, role, converged, inserted_at)
      VALUES (?1, ?2, ?3, 'review', ?4, ?5)
      """,
      [Ecto.UUID.generate(), task_id, round, if(converged, do: 1, else: 0), iso(at)]
    )
  end

  @doc "A guardrail event on `run_id`, recorded at `at`. Returns its id."
  def event!(run_id, task_id, {provider, model}, kind, severity, at) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO guardrail_events (id, run_id, task_id, provider, model, kind, severity, source,
                                    detail, fingerprint, inserted_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'transcript_scan', ?6, ?1, ?8)
      """,
      [id, run_id, task_id, provider, model, to_string(kind), to_string(severity), iso(at)]
    )

    id
  end

  defp iso(%DateTime{} = dt),
    do: dt |> Map.put(:microsecond, {elem(dt.microsecond, 0), 6}) |> DateTime.to_iso8601()
end
