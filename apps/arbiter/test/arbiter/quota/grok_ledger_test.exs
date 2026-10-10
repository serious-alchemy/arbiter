defmodule Arbiter.Quota.GrokLedgerTest do
  @moduledoc """
  bd-cwq8b0: grok's free tier has no pollable quota endpoint, so its headroom is
  a ledger estimate — the sum of grok `usage_events` over the trailing 24h
  against a configurable cap — and a server-reported `free-usage-exhausted` 429
  holds until that rolling window drains below the cap, not until a fixed time.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Gate.Throttle
  alias Arbiter.Quota.GrokLedger
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  @now ~U[2026-10-05 12:00:00.000000Z]

  setup do
    prev = Application.get_env(:arbiter, :grok_quota)
    Application.put_env(:arbiter, :grok_quota, cap_tokens: 500_000)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :grok_quota, prev),
        else: Application.delete_env(:arbiter, :grok_quota)
    end)

    :ok
  end

  # `hours_ago` is relative to @now. The row's total is in + cache_read +
  # cache_creation + out (cached tokens count against grok's cap).
  defp event!(hours_ago, attrs) do
    base = %{
      task_id: "bd-grok-#{System.unique_integer([:positive])}",
      source: :task,
      step: :work,
      provider: "grok",
      tokens_in: 0,
      tokens_out: 0,
      occurred_at: DateTime.add(@now, -round(hours_ago * 3600), :second)
    }

    Ash.create!(Event, Map.merge(base, attrs))
  end

  defp exhausted_run!(minutes_ago, actual, limit) do
    Ash.create!(Run, %{
      task_id: "bd-grok-run-#{System.unique_integer([:positive])}",
      kind: :implement,
      repo: "arbiter",
      provider: "grok",
      state: :finished,
      outcome: :failed,
      stop_category: "quota_exhausted",
      failure_reason:
        "grok free-tier usage exhausted for grok-4.7 — rolling 24h window, " <>
          "tokens (actual/limit): #{actual}/#{limit}",
      started_at: DateTime.add(@now, -(minutes_ago + 5) * 60, :second),
      completed_at: DateTime.add(@now, -minutes_ago * 60, :second)
    })
  end

  describe "cap/0" do
    test "defaults to 500K and is configurable" do
      Application.delete_env(:arbiter, :grok_quota)
      assert GrokLedger.cap() == 500_000

      Application.put_env(:arbiter, :grok_quota, cap_tokens: 120_000)
      assert GrokLedger.cap() == 120_000
    end

    test "a non-positive or non-integer cap falls back to the default" do
      Application.put_env(:arbiter, :grok_quota, cap_tokens: 0)
      assert GrokLedger.cap() == 500_000
      Application.put_env(:arbiter, :grok_quota, cap_tokens: "lots")
      assert GrokLedger.cap() == 500_000
    end
  end

  describe "used/1" do
    test "sums input, cache and output tokens of grok rows inside the trailing 24h" do
      event!(1, %{
        tokens_in: 29_112,
        tokens_out: 658,
        cache_read_tokens: 31_872,
        cache_creation_tokens: 10
      })

      # Outside the window, another provider, and a nil-token row.
      event!(25, %{tokens_in: 400_000})
      event!(1, %{provider: "claude", tokens_in: 400_000})
      event!(2, %{tokens_in: nil, tokens_out: nil})

      assert GrokLedger.used(now: @now) == 29_112 + 658 + 31_872 + 10
    end
  end

  describe "snapshot/1" do
    test "a quiet ledger reads 0% with no reset" do
      s = GrokLedger.snapshot(now: @now)
      assert %Snapshot{provider: "grok", window_label: "24h"} = s
      assert s.utilization == 0.0
      assert s.reset_at == nil
      assert s.status == nil
      assert s.captured_at == @now
    end

    test "utilization is used / cap" do
      event!(1, %{tokens_in: 125_000})
      assert %Snapshot{utilization: 0.25} = GrokLedger.snapshot(now: @now)
    end

    test "over the cap: reset_at is when enough old usage has aged out, not a fixed time" do
      # 300K at 20h ago ages out at +4h; 250K at 2h ago ages out at +22h.
      event!(20, %{tokens_in: 300_000})
      event!(2, %{tokens_in: 250_000})

      s = GrokLedger.snapshot(now: @now)
      assert s.utilization > 1.0
      assert s.status == "limit_reached"
      # Dropping the 20h-old row leaves 250K < 500K, so it lifts in 4h.
      assert s.reset_at == DateTime.add(@now, 4 * 3600 + 1, :second)
    end

    test "needs several rows to age out when one is not enough" do
      event!(22, %{tokens_in: 100_000})
      event!(10, %{tokens_in: 300_000})
      event!(1, %{tokens_in: 300_000})

      s = GrokLedger.snapshot(now: @now)
      # 700K; the 22h row leaves 600K (still over), the 10h row leaves 300K.
      assert s.reset_at == DateTime.add(@now, 14 * 3600 + 1, :second)
    end
  end

  describe "a free-usage-exhausted 429 (the server's own count)" do
    test "holds even when the ledger says there is headroom, then lifts as the window drains" do
      # The ledger saw only 100K, but the server said 604183/500000: the rest
      # is usage Arbiter did not see (an interactive session).
      event!(3, %{tokens_in: 100_000})
      exhausted_run!(30, 604_183, 500_000)

      s = GrokLedger.snapshot(now: @now)
      assert s.status == "limit_reached"
      assert s.utilization >= 1.0
      # The unseen part cannot be aged out by a ledger row, so it holds to
      # the end of the 24h window the 429 was reported in.
      assert s.reset_at == DateTime.add(@now, -30 * 60 + 24 * 3600 + 1, :second)
    end

    test "lifts earlier when the usage the ledger can see was what filled the cap" do
      event!(23, %{tokens_in: 350_000})
      event!(1, %{tokens_in: 154_183})
      exhausted_run!(30, 504_183, 500_000)

      s = GrokLedger.snapshot(now: @now)
      assert s.status == "limit_reached"
      # All 504,183 tokens were in the ledger: the 23h row ages out in 1h.
      assert s.reset_at == DateTime.add(@now, 3600 + 1, :second)
    end

    test "a 429 older than the window no longer holds" do
      exhausted_run!(25 * 60, 604_183, 500_000)
      s = GrokLedger.snapshot(now: @now)
      assert s.status == nil
      assert s.utilization == 0.0
    end

    test "the free Grok Build usage-limit wording (no counts) classifies and opens the hold" do
      text =
        "grok error: You've reached your free Grok Build usage limit for now. Get SuperGrok for much higher limits, or try again later: https://grok.com/supergrok?referrer=grok-build"

      reason = Arbiter.Worker.StopReason.classify(1, [text], "grok")
      assert reason.category == :quota_exhausted

      Ash.create!(Run, %{
        task_id: "bd-grok-build-limit",
        kind: :implement,
        repo: "arbiter",
        provider: "grok",
        state: :finished,
        outcome: :failed,
        stop_category: "quota_exhausted",
        failure_reason: reason.summary,
        started_at: DateTime.add(@now, -35 * 60, :second),
        completed_at: DateTime.add(@now, -30 * 60, :second)
      })

      s = GrokLedger.snapshot(now: @now)
      assert s.status == "limit_reached"
      assert s.reset_at == DateTime.add(@now, -30 * 60 + 24 * 3600 + 1, :second)
    end

    test "a run that stopped for another reason is not a marker" do
      Ash.create!(Run, %{
        task_id: "bd-grok-other",
        kind: :implement,
        repo: "arbiter",
        provider: "grok",
        state: :finished,
        outcome: :failed,
        stop_category: "crashed",
        failure_reason: "tokens (actual/limit): 604183/500000",
        started_at: DateTime.add(@now, -700, :second),
        completed_at: DateTime.add(@now, -600, :second)
      })

      assert GrokLedger.snapshot(now: @now).status == nil
    end
  end

  describe "the dispatch gate" do
    test "Quota.latest_for_provider/2 serves the ledger snapshot for grok and the gate holds on it" do
      event!(0, %{tokens_in: 480_000, occurred_at: DateTime.add(DateTime.utc_now(), -60, :second)})

      snapshot = Quota.latest_for_provider(Ecto.UUID.generate(), :grok)
      assert %Snapshot{provider: "grok"} = snapshot

      assert {:hold, %{phrase: phrase}} = Throttle.check(nil, snapshot, nil, [])
      assert phrase =~ "96%"
    end

    test "headroom under the cap lets it through, and the cap is configurable" do
      event!(1, %{tokens_in: 100_000})
      s = GrokLedger.snapshot(now: @now)
      assert Gate.gating_window(s, nil, now: @now) == nil

      Application.put_env(:arbiter, :grok_quota, cap_tokens: 110_000)
      s = GrokLedger.snapshot(now: @now)
      assert Gate.gating_window(s, nil, now: @now) != nil
    end
  end

  # Dispatch reads the real clock, so these rows are stamped against it. The
  # workspace has no grok account (none can exist), which is the point: the
  # gate must serve the ledger snapshot regardless.
  describe "Dispatch.dispatch/2 — a grok task on a workspace with no grok link" do
    alias Arbiter.Tasks.Issue
    alias Arbiter.Tasks.Workspace
    alias Arbiter.Workflows.DispatchQueue
    alias Arbiter.Workflows.DispatchQueueSupervisor

    setup do
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "grok-#{System.unique_integer([:positive])}",
          prefix: "gk#{System.unique_integer([:positive])}",
          config: %{"quota" => %{"on_exhaustion" => "throttle"}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "grok work", workspace_id: workspace.id})

      on_exit(fn ->
        if pid = DispatchQueueSupervisor.whereis(workspace.id) do
          Arbiter.ProcessTeardown.stop_child(DispatchQueueSupervisor, pid)
        end
      end)

      {:ok, workspace: workspace, task: task}
    end

    defp live_event!(minutes_ago, tokens_in) do
      Ash.create!(Event, %{
        task_id: "bd-grok-#{System.unique_integer([:positive])}",
        source: :task,
        step: :work,
        provider: "grok",
        tokens_in: tokens_in,
        tokens_out: 0,
        occurred_at: DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
      })
    end

    defp live_exhausted_run!(minutes_ago) do
      Ash.create!(Run, %{
        task_id: "bd-grok-run-#{System.unique_integer([:positive])}",
        kind: :implement,
        repo: "arbiter",
        provider: "grok",
        state: :finished,
        outcome: :failed,
        stop_category: "quota_exhausted",
        failure_reason:
          "grok free-tier usage exhausted for grok-4.7 — tokens (actual/limit): 604183/500000",
        started_at: DateTime.add(DateTime.utc_now(), -(minutes_ago + 5) * 60, :second),
        completed_at: DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
      })
    end

    defp dispatch_grok(task) do
      Arbiter.Worker.Dispatch.dispatch(task.id,
        force: true,
        repo: "r",
        start_driver: false,
        agent_type: :grok
      )
    end

    test "ledger usage over the cap holds the dispatch, and headroom lets it through", %{
      workspace: workspace,
      task: task
    } do
      over = live_event!(60, 520_000)

      assert {:error, {:quota_held, held_id}} = dispatch_grok(task)
      assert held_id == task.id
      assert DispatchQueue.held?(workspace.id, task.id)

      # The same usage, 25h old, is out of the rolling window: it proceeds.
      Ash.destroy!(over)
      live_event!(25 * 60, 520_000)

      assert {:ok, %{task: %{state: :active}}} = dispatch_grok(task)
    end

    test "a free-usage-exhausted 429 holds at the 429 time and lifts as the window drains", %{
      workspace: workspace,
      task: task
    } do
      # The ledger saw nothing; the server's own count says the cap is blown.
      live_exhausted_run!(30)

      assert {:error, {:quota_held, _}} = dispatch_grok(task)
      assert DispatchQueue.held?(workspace.id, task.id)

      # The hold lifts when the window rolls past the 429, not at a clock time.
      snapshot = GrokLedger.snapshot()
      assert snapshot.status == "limit_reached"
      assert DateTime.compare(snapshot.reset_at, DateTime.utc_now()) == :gt

      assert GrokLedger.snapshot(now: snapshot.reset_at).status == nil
    end

    test "a 429 older than the window no longer holds the dispatch", %{task: task} do
      live_exhausted_run!(25 * 60)

      assert {:ok, %{task: %{state: :active}}} = dispatch_grok(task)
    end
  end

  describe "headroom" do
    test "Headroom.binding/3 reads the ledger snapshot against the gate's ceiling" do
      event!(1, %{tokens_in: 100_000})
      snapshot = GrokLedger.snapshot(now: @now)

      assert %{headroom: headroom, window: "24h", used: 0.2} =
               Quota.Headroom.binding(snapshot, nil, now: @now)

      # The flat ceiling is 85%: 0.85 - 0.20.
      assert_in_delta headroom, 0.65, 1.0e-9
    end

    test "the 24h window has a known length for the paced gate" do
      assert Gate.window_seconds("24h") == GrokLedger.window_seconds()
    end
  end
end
