defmodule Arbiter.Guardrails.SpendPatrolTest do
  @moduledoc """
  G19 (docs/design/guardrail-profiles.md §3.3): the per-tier spend caps. A live
  implementer run whose recorded `guardrail_decision` carries a `park` cap is
  stopped with the typed `:spend_cap` cause once its tokens or wall-clock pass it;
  a `page` cap pages the coordinator and stops nothing.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Events
  alias Arbiter.Guardrails.SpendPatrol
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  require Ash.Query

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "spend-patrol-#{System.unique_integer([:positive])}",
        prefix: "sp#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp decision(overrides \\ %{}) do
    Map.merge(
      %{
        "eligible" => true,
        "tier" => "quarantine",
        "role" => "implementer",
        "subject" => %{
          "provider" => "antigravity",
          "model" => "gemini-3-flash",
          "family" => "google"
        },
        "spend" => %{"action" => "park", "tokens" => 3_000_000, "wall_clock_s" => 1_800}
      },
      overrides
    )
  end

  # A worker with a live agent port, carrying `decision` in its meta.
  defp live_worker(ws, decision, opts \\ []) do
    task_id = "bd-sp-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: ws.id, meta: %{})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    if decision, do: :ok = Worker.report(pid, :guardrail_decision, decision)

    if Keyword.get(opts, :live, true) do
      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: System.tmp_dir!(),
          command: ["sh", "-c", "sleep 30"]
        )
    end

    {pid, task_id}
  end

  defp ledger!(ws, task_id, attrs) do
    base = %{
      task_id: task_id,
      base_task_id: task_id,
      source: :task,
      step: :work,
      role: "base",
      workspace_id: ws.id,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp escalations(task_id, kind) do
    Message
    |> Ash.Query.filter(task_ref == ^task_id and escalation_kind == ^kind)
    |> Ash.read!()
  end

  describe "check/2 (pure)" do
    test "nil under both caps, the tripped cap past one" do
      spend = %{"action" => "park", "tokens" => 1_000, "wall_clock_s" => 60}

      assert nil == SpendPatrol.check(spend, %{tokens: 999, wall_clock_s: 59})

      assert %{cap: :tokens, limit: 1_000, measured: 1_001} =
               SpendPatrol.check(spend, %{tokens: 1_001, wall_clock_s: 59})

      assert %{cap: :wall_clock_s, limit: 60, measured: 61} =
               SpendPatrol.check(spend, %{tokens: 0, wall_clock_s: 61})
    end

    test "a nil cap is no cap" do
      assert nil ==
               SpendPatrol.check(
                 %{"action" => "park", "tokens" => nil, "wall_clock_s" => nil},
                 %{tokens: 10_000_000_000, wall_clock_s: 10_000_000}
               )
    end
  end

  describe "sweep/1 — park" do
    test "parks a quarantine run past its wall-clock cap, with the spend_cap cause", %{ws: ws} do
      {pid, task_id} = live_worker(ws, decision())

      assert [%{task_id: ^task_id, action: :parked, cap: :wall_clock_s}] =
               SpendPatrol.sweep(now: later(65 * 60))

      assert %{state: :finished, outcome: :failed, meta: meta} = Worker.state(pid)
      assert meta.stop_reason.category == :spend_cap
      assert [_] = escalations(task_id, :worker_stopped)
    end

    # §6.1: a spend-cap park is a major guardrail event for quarantine and
    # probation (the park tiers), so `Loop.Trust` counts it: two within 14 days
    # demote the subject, and one blocks a promotion.
    test "a park is a major spend_cap guardrail event on the run's subject", %{ws: ws} do
      {pid, task_id} = live_worker(ws, decision())
      %{run_id: run_id} = Worker.state(pid)
      assert is_binary(run_id)

      assert [%{action: :parked}] = SpendPatrol.sweep(now: later(65 * 60))

      assert [event] = Events.for_run(run_id)
      assert event.kind == :spend_cap
      assert event.severity == :major
      assert event.source == :spend_patrol
      assert event.task_id == task_id
      assert {event.provider, event.model} == {"antigravity", "gemini-3-flash"}
      assert event.detail =~ "wall-clock"
      assert event.detail =~ "quarantine"

      # A second sweep finds nothing live to park, and records nothing more.
      assert [] = SpendPatrol.sweep(now: later(70 * 60))
      assert [_] = Events.for_run(run_id)
    end

    test "leaves a run under its caps alone", %{ws: ws} do
      {pid, _task_id} = live_worker(ws, decision())

      assert [] = SpendPatrol.sweep(now: later(60))
      assert %{state: :working} = Worker.state(pid)
    end

    test "parks on settled ledger tokens of the subject's provider (the bd-bxwsvo run)", %{
      ws: ws
    } do
      {pid, task_id} = live_worker(ws, decision())
      ledger!(ws, task_id, %{provider: "antigravity", tokens_in: 7_000_000, tokens_out: 700_000})

      assert [%{task_id: ^task_id, action: :parked, cap: :tokens, measured: 7_700_000}] =
               SpendPatrol.sweep(now: later(60))

      assert %{state: :finished, meta: %{stop_reason: %{category: :spend_cap}}} =
               Worker.state(pid)
    end

    test "another provider's tokens on the same ticket do not count", %{ws: ws} do
      {pid, task_id} = live_worker(ws, decision())
      ledger!(ws, task_id, %{provider: "claude", tokens_in: 9_000_000, tokens_out: 0})

      assert [] = SpendPatrol.sweep(now: later(60))
      assert %{state: :working} = Worker.state(pid)
    end

    test "a parked run is not parked twice", %{ws: ws} do
      {_pid, _task_id} = live_worker(ws, decision())
      assert [_] = SpendPatrol.sweep(now: later(65 * 60))
      assert [] = SpendPatrol.sweep(now: later(66 * 60))
    end
  end

  describe "the ticker" do
    test "a tick sweeps: a run over its token cap is parked", %{ws: ws} do
      {pid, task_id} = live_worker(ws, decision())
      ledger!(ws, task_id, %{provider: "antigravity", tokens_in: 8_000_000})

      patrol = start_supervised!({SpendPatrol, name: nil, enabled: false})
      send(patrol, :tick)
      _ = :sys.get_state(patrol)

      assert %{state: :finished, meta: %{stop_reason: %{category: :spend_cap}}} =
               Worker.state(pid)
    end
  end

  describe "the production decision" do
    setup do
      Application.put_env(:arbiter, :guardrail_subject_rules, [
        %{match: %{provider: "claude"}, tier: :privileged},
        %{match: %{provider: "codex"}, tier: :quarantine}
      ])

      on_exit(fn -> Application.delete_env(:arbiter, :guardrail_subject_rules) end)
    end

    test "a quarantine decision built by Gate.decision/5 is enforced as built", %{ws: ws} do
      issue = Ash.create!(Arbiter.Tasks.Issue, %{title: "d1", workspace_id: ws.id, difficulty: 1})
      decision = Arbiter.Guardrails.Gate.decision(issue, ws, :codex, "gpt-5")
      assert decision["tier"] == "quarantine"

      {pid, task_id} = live_worker(ws, decision)
      ledger!(ws, task_id, %{provider: "codex", tokens_in: 7_000_000, tokens_out: 700_000})

      assert [%{action: :parked, cap: :tokens, tier: :quarantine}] =
               SpendPatrol.sweep(now: later(60))

      assert %{state: :finished, meta: %{stop_reason: %{category: :spend_cap}}} =
               Worker.state(pid)
    end
  end

  describe "sweep/1 — what it leaves alone" do
    test "a run with no guardrail decision", %{ws: ws} do
      {pid, _} = live_worker(ws, nil)
      assert [] = SpendPatrol.sweep(now: later(10_000))
      assert %{state: :working} = Worker.state(pid)
    end

    test "a run whose agent is not live (parked at the review gate)", %{ws: ws} do
      {pid, _} = live_worker(ws, decision(), live: false)
      assert [] = SpendPatrol.sweep(now: later(10_000))
      assert %{state: :working} = Worker.state(pid)
    end

    test "a reviewer run", %{ws: ws} do
      {pid, _} = live_worker(ws, decision(%{"role" => "reviewer"}))
      assert [] = SpendPatrol.sweep(now: later(10_000))
      assert %{state: :working} = Worker.state(pid)
    end

    test "a tier with no caps (trusted default)", %{ws: ws} do
      spend = %{"action" => "page", "tokens" => nil, "wall_clock_s" => nil}
      {pid, _} = live_worker(ws, decision(%{"tier" => "trusted", "spend" => spend}))
      assert [] = SpendPatrol.sweep(now: later(100_000))
      assert %{state: :working} = Worker.state(pid)
    end
  end

  describe "sweep/1 — page" do
    test "an operator-set cap on a page tier pages once and stops nothing", %{ws: ws} do
      spend = %{"action" => "page", "tokens" => nil, "wall_clock_s" => 600}
      {pid, task_id} = live_worker(ws, decision(%{"tier" => "trusted", "spend" => spend}))

      assert [%{task_id: ^task_id, action: :paged, cap: :wall_clock_s}] =
               SpendPatrol.sweep(now: later(1_200))

      assert %{state: :working, run_id: run_id} = Worker.state(pid)
      assert [_] = escalations(task_id, :spend_cap_exceeded)

      # Still over on the next sweep: the open page is refreshed, not duplicated.
      SpendPatrol.sweep(now: later(1_300))
      assert [_] = escalations(task_id, :spend_cap_exceeded)

      # A page tier's cap is not a guardrail event (§6.1: major for the park
      # tiers only).
      assert Events.for_run(run_id) == []
    end
  end
end
