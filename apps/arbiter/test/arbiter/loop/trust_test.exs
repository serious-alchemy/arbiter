defmodule Arbiter.Loop.TrustTest do
  @moduledoc """
  G18 (bd-7i9pxn, `docs/design/guardrail-profiles.md` §6.2–6.5): the trust
  records `Arbiter.Loop.Trust` folds from `guardrail_events` and
  `Arbiter.Loop.SubjectStats`, one row per `(provider, model)` subject.

  Every expected count below is read off the fixture table next to it, not off
  the module under test.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.TrustFixtures

  alias Arbiter.Guardrails.Eligibility
  alias Arbiter.Guardrails.Subjects
  alias Arbiter.Guardrails.TrustRecord
  alias Arbiter.Loop.Trust
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  require Ash.Query

  @codex {"codex", "gpt-5.1-codex"}
  @opus {"claude", "claude-opus-4-6"}

  setup do
    %{ws: workspace!()}
  end

  describe "the fold (§6.2, §6.5)" do
    # | ticket | runs (start)             | repo    | round 1  | events       | stop      | clean      |
    # |--------|--------------------------|---------|----------|--------------|-----------|------------|
    # | a1     | 1 (09-20)                | arbiter | approved |              |           | yes        |
    # | a2     | 1 (09-21)                | arbiter | rejected | minor on run |           | no: round 1 |
    # | a3     | 1 (09-22)                | arbiter | approved | major on run |           | no: event  |
    # | a4     | 1 (09-23)                | arbiter | approved |              | spend_cap | no: cap    |
    # | a5     | 1 (09-24), ticket open   | arbiter |          |              |           | no: open   |
    # | a6     | 2 (09-25 killed, 09-26)  | arbiter | approved |              | killed    | yes, yes   |
    # | a7     | 1 (09-27)                | arbiter | approved |              | stalled   | no: stuck  |
    # | a8     | 1 (09-28, harness 0.50)  | mesaana | approved |              |           | yes        |
    # | a-old  | 1 (08-20)                | arbiter | approved |              |           | outside    |
    setup %{ws: ws} do
      rule!(%{provider: "codex", tier: :quarantine})
      rule!(%{provider: "claude", tier: :privileged})

      task!(ws, "a1", @codex, at: ~U[2026-09-20 10:00:00Z])
      a2 = task!(ws, "a2", @codex, at: ~U[2026-09-21 10:00:00Z], round1: false)
      a3 = task!(ws, "a3", @codex, at: ~U[2026-09-22 10:00:00Z])
      task!(ws, "a4", @codex, at: ~U[2026-09-23 10:00:00Z], stop: "spend_cap")
      task!(ws, "a5", @codex, at: ~U[2026-09-24 10:00:00Z], open: true, round1: nil)

      task!(ws, "a6", @codex, at: ~U[2026-09-25 10:00:00Z], stop: "killed")
      run!(ws, "a6", @codex, started_at: ~U[2026-09-26 10:00:00Z])

      task!(ws, "a7", @codex, at: ~U[2026-09-27 10:00:00Z], stop: "stalled")

      task!(ws, "a8", @codex,
        at: ~U[2026-09-28 10:00:00Z],
        repo: "mesaana",
        harness: "0.50.0"
      )

      task!(ws, "a-old", @codex, at: ~U[2026-08-20 10:00:00Z])

      event!(a2, "a2", @codex, :permission_denial, :minor, ~U[2026-09-21 11:00:00Z])
      event!(a3, "a3", @codex, :credential_read, :major, ~U[2026-09-22 11:00:00Z])

      task!(ws, "c1", @opus, at: ~U[2026-09-20 10:00:00Z])

      {:ok, _} = Trust.tick(now: now(), cutover: cutover(), workers: [])
      :ok
    end

    test "writes one row per subject" do
      assert [{"claude", "claude-opus-4-6"}, {"codex", "gpt-5.1-codex"}] =
               TrustRecord |> Ash.read!() |> Enum.map(&{&1.provider, &1.model}) |> Enum.sort()
    end

    test "counts the window's main implementer runs and the clean ones" do
      record = Trust.get(@codex)

      assert record.tier == :quarantine
      assert record.runs == 9
      assert record.clean_runs == 4
      assert record.clean_tickets == 3
      assert record.clean_repos == 2
    end

    test "counts the window's guardrail events by severity, newest first in recent_events" do
      record = Trust.get(@codex)

      assert {record.critical_events, record.major_events, record.minor_events} == {0, 1, 1}

      assert [%{"kind" => "credential_read", "severity" => "major"}, %{"severity" => "minor"}] =
               record.recent_events
    end

    test "round-1 quality comes from SubjectStats, attributed to the first run's subject" do
      record = Trust.get(@codex)

      # a1 a2 a3 a4 a6 a7 a8 are closed and reviewed; only a2's first round failed.
      assert record.reviewed == 7
      assert_in_delta record.round1_approve_rate, 6 / 7, 1.0e-9
    end

    test "records the last harness and model version" do
      record = Trust.get(@codex)

      assert record.harness_version == "0.50.0"
      assert record.model_version == "gpt-5.1-codex"
      assert record.last_run_at == ~U[2026-09-28 10:00:00.000000Z]
    end

    test "is not eligible below the §6.3 thresholds, and says which ones fail" do
      record = Trust.get(@codex)

      assert record.eligible_for == nil
      assert %{"to" => "probation", "criteria" => criteria} = record.eligibility

      unmet = for %{"met" => false, "name" => name} <- criteria, do: name
      assert "clean_runs" in unmet
      assert "clean_tickets" in unmet
      assert "no_critical_or_major" in unmet
    end
  end

  describe "automatic suspension (§6.3)" do
    setup %{ws: ws} do
      rule!(%{provider: "codex", tier: :probation})
      %{run_id: task!(ws, "s1", @codex, at: ~U[2026-10-09 10:00:00Z])}
    end

    test "a critical event suspends the subject: it leaves eligibility and the coordinator is paged",
         %{ws: ws, run_id: run_id} do
      event!(run_id, "s1", @codex, :public_upload_attempt, :critical, ~U[2026-10-09 11:00:00Z])

      assert {:ok, %{actions: [%{action: :suspended, subject: "codex/gpt-5.1-codex"}]}} =
               Trust.tick(now: now(), cutover: cutover(), workers: [])

      record = Trust.get(@codex)
      assert record.suspended_at == now()

      assert %{"kind" => "public_upload_attempt", "run_id" => ^run_id, "prior_tier" => "probation"} =
               record.suspension

      # An overlay: the rule keeps its tier until the coordinator confirms.
      assert record.tier == :probation
      assert record.eligible_for == nil

      assert {:error, why} = evaluate(ws, @codex)
      assert why =~ "suspended"

      assert [page] = pages(:trust_suspended)
      assert page.subject =~ "codex/gpt-5.1-codex"
      assert page.body =~ "arb trust confirm"
      assert page.body =~ "arb trust dismiss"
    end

    test "the subject's runs in flight park", %{ws: ws, run_id: run_id} do
      {pid, _task_id} = live_worker(ws, @codex)
      {other, _} = live_worker(ws, @opus)

      event!(run_id, "s1", @codex, :hidden_channel_attempt, :critical, ~U[2026-10-09 11:00:00Z])
      {:ok, %{actions: actions}} = Trust.tick(now: now(), cutover: cutover())

      assert %{state: :finished, outcome: :failed, meta: meta} = Worker.state(pid)
      assert meta.stop_reason.category == :trust_suspended
      assert %{state: :working} = Worker.state(other)
      assert [%{action: :suspended, parked: [_]}] = actions
    end

    test "an event recorded before the trust cutover never suspends", %{run_id: run_id} do
      event!(run_id, "s1", @codex, :public_upload_attempt, :critical, ~U[2026-10-09 11:00:00Z])

      assert {:ok, %{actions: []}} =
               Trust.tick(now: now(), cutover: ~U[2026-10-09 12:00:00Z], workers: [])

      assert %{suspended_at: nil, critical_events: 1} = Trust.get(@codex)
      assert pages(:trust_suspended) == []
    end

    test "a second critical event while suspended adds to the suspension without a second page",
         %{run_id: run_id} do
      event!(run_id, "s1", @codex, :public_upload_attempt, :critical, ~U[2026-10-09 11:00:00Z])
      {:ok, _} = Trust.tick(now: now(), cutover: cutover(), workers: [])

      event!(run_id, "s1", @codex, :self_grant_attempt, :critical, ~U[2026-10-10 12:30:00Z])

      {:ok, %{actions: []}} =
        Trust.tick(now: ~U[2026-10-10 13:00:00.000000Z], cutover: cutover(), workers: [])

      assert %{suspension: %{"events" => [_, _]}} = Trust.get(@codex)
      assert [_] = pages(:trust_suspended)
    end
  end

  describe "subjects" do
    test "a run is its dispatch decision's subject, and so are its events", %{ws: ws} do
      rule!(%{provider: "antigravity", tier: :probation})

      agy = {"antigravity", "gemini-3.8-flash-low"}

      run_id =
        task!(ws, "g1", agy,
          at: ~U[2026-09-20 10:00:00Z],
          adapter: "gemini",
          decision: true
        )

      adapter_subject = {"gemini", "gemini-3.8-flash-low"}
      event!(run_id, "g1", adapter_subject, :credential_read, :major, ~U[2026-09-20 11:00:00Z])

      {:ok, _} = Trust.tick(now: now(), cutover: cutover(), workers: [])

      assert %TrustRecord{tier: :probation, runs: 1, major_events: 1} = Trust.get(agy)
      assert Trust.get({"gemini", "gemini-3.8-flash-low"}) == nil
    end

    test "with no subject rule configured the record has no tier and nothing is acted on", %{
      ws: ws
    } do
      run_id = task!(ws, "u1", @codex, at: ~U[2026-09-20 10:00:00Z])
      event!(run_id, "u1", @codex, :public_upload_attempt, :critical, ~U[2026-10-09 10:00:00Z])

      assert {:ok, %{actions: []}} = Trust.tick(now: now(), cutover: cutover(), workers: [])

      assert %TrustRecord{tier: nil, critical_events: 1, suspended_at: nil} = Trust.get(@codex)
      assert Subjects.list() == []
    end
  end

  # ---- helpers ----------------------------------------------------------------

  defp evaluate(ws, {provider, model}, difficulty \\ 1) do
    Eligibility.evaluate(%{
      provider: provider,
      model: model,
      role: :implementer,
      difficulty: difficulty,
      workspace: ws
    })
  end

  defp pages(kind) do
    Message
    |> Ash.Query.filter(escalation_kind == ^kind)
    |> Ash.read!()
  end

  # A worker with a live agent port whose dispatch decision names `subject`.
  defp live_worker(ws, {provider, model}) do
    task_id = "bd-tr-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: ws.id, meta: %{})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    :ok =
      Worker.report(pid, :guardrail_decision, %{
        "eligible" => true,
        "tier" => "probation",
        "role" => "implementer",
        "subject" => %{"provider" => provider, "model" => model}
      })

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        command: ["sh", "-c", "sleep 30"]
      )

    {pid, task_id}
  end
end
