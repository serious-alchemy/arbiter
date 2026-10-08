defmodule Arbiter.Worker.ReviewGateCiGateTest do
  @moduledoc """
  bd-cut6uv / #228 — CI-gated review: ReviewGate dispatches a reviewer only
  after CI is green on the exact head SHA it is about to review.

  Real git (a bare origin and a linked worktree), a real author `Worker`, the
  real gate, and `Arbiter.Test.StubMerger` standing in for the forge, answering
  from a scripted pipeline and the live tip of the bare origin's branch — so a
  commit pushed mid-wait really moves the head the forge reports.

  The reviewer fixture (`review_ci_probe.sh`) counts its own passes in the
  common git dir; "the reviewer was never paid for" is `passes == 0`.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.CircuitBreaker
  alias Arbiter.Loop.FlakeEvent
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, SlotGate, Workspace}
  alias Arbiter.Tasks.Lifecycle.Projection
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate

  @probe Path.expand("../../fixtures/review_ci_probe.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)
  @echo_done Path.expand("../../fixtures/echo_with_done.sh", __DIR__)
  @pr "#1"

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)
    StubMerger.reset()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-ci-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{
      repo: repo,
      tmp: tmp,
      ws: new_ws(%{"review" => %{"required" => true, "require_ci_green" => true}})
    }
  end

  # ---- AC1: the reviewer waits for green on the exact head ------------------

  describe "the gate (AC1)" do
    test "holds the reviewer back while CI is pending and dispatches it on green", ctx do
      rig = rig(ctx, "feature/ci-1")
      forge = start_forge(ctx, rig, [:running])

      gate = start_gate(rig, ctx, command: [@probe, "HOLD"])

      wait_until(fn -> StubMerger.get_count(@pr) >= 3 end)
      assert awaiting_ci?(gate)
      assert passes(rig) == 0

      # While it waits, the ticket says so.
      wait = Ash.get!(Issue, rig.task.id).review_gate_state["ci_wait"]
      assert wait["sha"] == rig.head

      set_pipeline(forge, [:success])
      wait_until(fn -> passes(rig) == 1 end, 20_000)
      assert reviewed_head(rig) == rig.head

      # The reviewer was told CI passed on this very sha, and not to run the suite.
      prompt = :sys.get_state(gate).current_prompt
      assert prompt =~ "CI passed on #{rig.head}"
      assert prompt =~ "Do not run the full test suite."

      # The marker is gone with the wait.
      assert Ash.get!(Issue, rig.task.id).review_gate_state["ci_wait"] == nil
      stop_gate(gate)
    end

    test "CI green on a different commit is not green: a push after CI started blocks the review",
         ctx do
      rig = rig(ctx, "feature/ci-2")
      forge = start_forge(ctx, rig, [:running])

      gate = start_gate(rig, ctx, command: [@probe, "HOLD"])
      wait_until(fn -> StubMerger.get_count(@pr) >= 2 end)
      assert awaiting_ci?(gate)

      # A commit lands on origin after CI started on the old head. The forge
      # still reports the OLD head — green there.
      pushed = push_other_commit(ctx, rig)
      refute pushed == rig.head
      set_head(forge, rig.head)
      set_pipeline(forge, [:success])

      polls = StubMerger.get_count(@pr)
      wait_until(fn -> StubMerger.get_count(@pr) >= polls + 3 end)
      assert passes(rig) == 0, "green on #{rig.head} must not release a review of #{pushed}"
      assert awaiting_ci?(gate)

      # CI now reports the new head, pending, then green.
      set_head(forge, nil)
      set_pipeline(forge, [:running, :running, :success])

      wait_until(fn -> passes(rig) == 1 end, 20_000)
      assert reviewed_head(rig) == pushed
      assert :sys.get_state(gate).current_prompt =~ "CI passed on #{pushed}"
      stop_gate(gate)
    end
  end

  # ---- RW8: the primary's own worker cap ----------------------------------------

  describe "the primary's worker cap at 0 (RW8)" do
    setup do
      on_exit(fn -> Arbiter.Settings.set_nodes_local_max_workers(nil) end)
      :ok
    end

    test "holds the reviewer (nothing spawned, no verdict) and starts it once the cap rises",
         ctx do
      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)
      rig = rig(ctx, "feature/rw8-hold")
      start_forge(ctx, rig, [:success])

      gate = start_gate(rig, ctx, local_capacity_retry_ms: 25)

      wait_until(fn -> :sys.get_state(gate).local_hold != nil end)
      assert :sys.get_state(gate).local_hold.info.phrase =~ "held — local capacity 0"
      assert passes(rig) == 0
      assert Process.alive?(gate)

      # Held, not failed: no verdict was written to the ticket.
      assert Ash.get!(Issue, rig.task.id).review_gate_state["verdict"] == nil

      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)
      wait_until(fn -> passes(rig) == 1 end, 20_000)
      stop_gate(gate)
    end

    test "a fix round held at cap 0 stays held past the reviewer's timer, then starts on resume",
         ctx do
      rig = rig(ctx, "feature/rw8-fix-hold")
      start_forge(ctx, rig, [:success])

      # A reviewer that waits for the flag, then answers REQUEST_CHANGES, so the
      # test can drop the cap to 0 while the reviewer is still running.
      flag = Path.join(ctx.tmp, "rw8-reviewer-go")
      wrapper = Path.join(ctx.tmp, "rw8-reviewer.sh")

      File.write!(wrapper, """
      #!/bin/sh
      until [ -f "#{flag}" ]; do sleep 0.05; done
      exec "#{@probe}" RC_SUITE
      """)

      File.chmod!(wrapper, 0o755)

      gate =
        start_gate(rig, ctx,
          command: [wrapper],
          revise_command: [@revise_commit],
          rounds: 3,
          timeout_ms: 1_500,
          local_capacity_retry_ms: 25
        )

      ref = Process.monitor(gate)
      wait_until(fn -> :sys.get_state(gate).phase == :reviewing end)

      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)
      File.write!(flag, "go")

      wait_until(fn -> :sys.get_state(gate).local_hold != nil end)
      held = :sys.get_state(gate)
      assert held.phase == :revising
      assert held.local_hold.info.phrase =~ "held — local capacity 0"
      assert remote_head(ctx, rig) == rig.head

      # The reviewer's own timer (1.5s) fires inside this window. It must be
      # stale: a hold is not a reviewer timeout.
      refute_receive {:DOWN, ^ref, :process, ^gate, _}, 2_500
      still = :sys.get_state(gate)
      assert still.local_hold != nil
      refute still.reported?

      assert Arbiter.ReviewGate.Round
             |> Ash.read!()
             |> Enum.filter(&(&1.task_id == rig.task.id and &1.verdict == :timed_out)) == []

      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)

      # The fix round's implementer ran (the fixture commits) and the gate pushed it.
      wait_until(fn -> remote_head(ctx, rig) != rig.head end, 20_000)
      stop_gate(gate)
    end

    test "with no override the gate is unaffected", ctx do
      rig = rig(ctx, "feature/rw8-nohold")
      start_forge(ctx, rig, [:success])

      gate = start_gate(rig, ctx, local_capacity_retry_ms: 25)
      wait_until(fn -> passes(rig) == 1 end, 20_000)
      stop_gate(gate)
    end
  end

  # ---- AC2: red CI reruns once ----------------------------------------------

  describe "red CI (AC2)" do
    test "red then green on the rerun is a flake: recorded, and no fix pass runs", ctx do
      rig = rig(ctx, "feature/ci-3")

      StubMerger.set_failing_checks(@pr, [
        %{name: "unit tests", summary: "1) boom", url: "https://ci/1", files: []}
      ])

      start_forge(ctx, rig, [:failed, :running, :success])

      start_gate(rig, ctx, revise_command: [@revise_commit], rounds: 3)

      wait_until(fn -> passes(rig) == 1 end, 20_000)

      assert [{_ref, _opts}] = StubMerger.ci_reruns()

      assert [%FlakeEvent{ci_job: "unit tests", repo: "trib/repo"}] =
               FlakeEvent |> Ash.read!() |> Enum.filter(&(&1.task_id == rig.task.id))

      # No fix pass: the implementer fixture would have committed.
      assert remote_head(ctx, rig) == rig.head
      assert Ash.get!(Issue, rig.task.id).review_gate_state["verdict"] != "request_changes"
    end

    test "red then red dispatches the existing fix path, then waits for CI on the fix", ctx do
      rig = rig(ctx, "feature/ci-4")

      StubMerger.set_failing_checks(@pr, [
        %{name: "unit tests", summary: "1) boom", url: "https://ci/1", files: []}
      ])

      start_forge(ctx, rig, [:failed, :running, :failed, :success])

      gate =
        start_gate(rig, ctx,
          revise_command: [@revise_commit],
          rounds: 3,
          command: [@probe, "HOLD"]
        )

      # The fix pass commits and the gate pushes it; the reviewer then reads THAT head.
      wait_until(fn -> passes(rig) == 1 end, 30_000)
      fixed = remote_head(ctx, rig)
      refute fixed == rig.head

      assert length(StubMerger.ci_reruns()) == 1
      assert FlakeEvent |> Ash.read!() |> Enum.filter(&(&1.task_id == rig.task.id)) == []
      assert reviewed_head(rig) == fixed
      assert :sys.get_state(gate).current_prompt =~ "CI passed on #{fixed}"
      stop_gate(gate)
    end

    test "a CI-red fix round with no diff reruns CI; green re-reviews the head instead of parking",
         ctx do
      rig = rig(ctx, "feature/ci-noop-green")

      StubMerger.set_failing_checks(@pr, [
        %{name: "unit tests", summary: "1) boom", url: "https://ci/1", files: []}
      ])

      # red, rerun red -> fix round (no diff) -> red, the gate's own rerun -> green
      start_forge(ctx, rig, [:failed, :running, :failed, :failed, :running, :success])

      gate =
        start_gate(rig, ctx, revise_command: [@echo_done], rounds: 4, command: [@probe, "HOLD"])

      wait_until(fn -> passes(rig) == 1 end, 30_000)

      # The fix round changed nothing, and the head it left is what got reviewed.
      assert remote_head(ctx, rig) == rig.head
      assert reviewed_head(rig) == rig.head
      assert length(StubMerger.ci_reruns()) == 2

      assert [%FlakeEvent{ci_job: "unit tests"}] =
               FlakeEvent |> Ash.read!() |> Enum.filter(&(&1.task_id == rig.task.id))

      refute Ash.get!(Issue, rig.task.id).attention_cause == :commit_gate_no_changes
      stop_gate(gate)
    end

    test "a CI-red fix round with no diff parks, naming the jobs, when CI stays red", ctx do
      rig = rig(ctx, "feature/ci-noop-red")

      StubMerger.set_failing_checks(@pr, [
        %{name: "unit tests", summary: "1) boom", url: "https://ci/1", files: []}
      ])

      # red, rerun red -> one fix round (no diff) -> red, the gate's own rerun red -> park
      start_forge(ctx, rig, [:failed, :running, :failed, :failed, :running, :failed])

      gate = start_gate(rig, ctx, revise_command: [@echo_done], rounds: 3)
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 30_000

      assert passes(rig) == 0
      assert Ash.get!(Issue, rig.task.id).attention_cause == :commit_gate_no_changes

      bodies = gate_messages(ctx, rig) |> Enum.map_join("\n", &"#{&1.subject}\n#{&1.body}")
      assert bodies =~ "Failing jobs: unit tests"
    end

    test "the fix-round prompt for red CI names ci_rerun and flake_record", ctx do
      state = %{
        task_id: rig(ctx, "feature/ci-prompt").task.id,
        workspace_id: ctx.ws.id,
        branch: "feature/ci-prompt",
        target_branch: "main",
        round: 1,
        thread: [],
        ci_fix_pending: %{sha: "abc", checks: []}
      }

      prompt = ReviewGate.revise_prompt(state, "CI is red")
      assert prompt =~ "ci_rerun"
      assert prompt =~ "flake_record"
    end

    test "the revise-round implementer gets a freshly written .mcp.json and token", ctx do
      rig = rig(ctx, "feature/ci-mcp")
      File.rm(Path.join(rig.worktree, ".mcp.json"))

      state = %{
        task_id: rig.task.id,
        workspace_id: ctx.ws.id,
        worktree_path: rig.worktree,
        repo: "trib/repo"
      }

      opts = ReviewGate.implementer_mcp_opts(state, :implementer, Arbiter.Agents.Claude)

      assert path = opts[:mcp_config]
      assert File.exists?(path)
      assert Path.basename(path) == ".mcp.json"
      assert is_binary(opts[:arb_token])

      assert ReviewGate.implementer_mcp_opts(state, :reviewer, Arbiter.Agents.Claude) == []
    end

    test "red CI at the round cap escalates instead of reviewing", ctx do
      rig = rig(ctx, "feature/ci-5")
      start_forge(ctx, rig, [:failed, :running, :failed])

      gate = start_gate(rig, ctx, revise_command: [@revise_commit], rounds: 1)
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 20_000

      assert passes(rig) == 0
      assert remote_head(ctx, rig) == rig.head
    end
  end

  # ---- #360: cancelled checks are infrastructure, never a fix round -----------

  describe "cancelled CI (#360)" do
    test "cancelled then green on the re-run proceeds to the reviewer, no fix round", ctx do
      rig = rig(ctx, "feature/ci-cancel-1")
      start_forge(ctx, rig, [:canceled, :running, :success])

      start_gate(rig, ctx, revise_command: [@revise_commit], rounds: 3)

      wait_until(fn -> passes(rig) == 1 end, 20_000)

      assert length(StubMerger.ci_reruns()) == 1
      assert FlakeEvent |> Ash.read!() |> Enum.filter(&(&1.task_id == rig.task.id)) == []
      # No fix round: the implementer fixture would have committed.
      assert remote_head(ctx, rig) == rig.head
    end

    test "cancelled past the re-run cap escalates once as CI infrastructure and never fixes",
         ctx do
      rig = rig(ctx, "feature/ci-cancel-2")
      start_forge(ctx, rig, [:canceled])

      start_gate(rig, ctx, revise_command: [@revise_commit], rounds: 3)

      wait_until(fn -> passes(rig) == 1 end, 20_000)

      assert length(StubMerger.ci_reruns()) == 2
      assert remote_head(ctx, rig) == rig.head

      assert [%{subject: subject}] =
               gate_messages(ctx, rig) |> Enum.filter(&(&1.subject =~ "cancelled"))

      assert subject =~ "not failed"
    end
  end

  # ---- AC3: a waiting ticket holds no slot ------------------------------------

  describe "waiting on CI (AC3)" do
    # bd-dtdeff: the release changes no phase, so this event is the Autopilot's
    # only cue to re-plan against the freed provider slot.
    test "announces the released slot so the Autopilot re-plans", ctx do
      rig = rig(ctx, "feature/ci-slot-released")
      start_forge(ctx, rig, [:running])
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "events")

      gate = start_gate(rig, ctx, command: [@probe, "HOLD"])
      wait_until(fn -> awaiting_ci?(gate) end)

      task_id = rig.task.id
      assert_receive {:event, %{topic: "worker_slot_released", task_id: ^task_id}}, 2_000
    end

    test "holds no scheduler slot and no agent, and shows its state", ctx do
      rig = rig(ctx, "feature/ci-6")
      start_forge(ctx, rig, [:running])

      # The author is on a provider account (its ReviewGate holds it, no agent).
      account =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "rg-ci-#{System.unique_integer([:positive])}"
        })

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ctx.ws.id,
        provider: :claude,
        provider_account_id: account.id
      })

      assert Concurrency.live_count(account) == 1

      gate = start_gate(rig, ctx, command: [@probe, "HOLD"])
      wait_until(fn -> awaiting_ci?(gate) end)

      # Waiting on CI releases the account: no agent is live for the ticket.
      wait_until(fn -> Concurrency.live_count(account) == 0 end)

      issue = Ash.get!(Issue, rig.task.id)

      # No agent is live for the ticket: the author's own session is over and no
      # reviewer was spawned.
      refute Worker.active?(Worker.state(rig.author))
      assert passes(rig) == 0

      # The scheduler's slot count drops it, as it does a merging ticket.
      refute SlotGate.holds_slot?(issue)
      assert issue.state == :active

      cleared = %{issue | review_gate_state: Map.delete(issue.review_gate_state, "ci_wait")}
      assert SlotGate.holds_slot?(cleared)

      # And the board / `arb ticket show` projection names it.
      view = Projection.view(issue)
      assert view.step == :awaiting_ci
      assert view.ci_wait.sha == rig.head

      assert Projection.payload(view).ci_wait["label"] =~
               "waiting on CI #{String.slice(rig.head, 0, 12)}"

      # And the account is held again once the wait is over.
      stop_gate(gate)
      wait_until(fn -> Concurrency.live_count(account) == 1 end)
    end
  end

  # ---- AC4: the reviewer prompt and the partial-verification carve-out --------

  describe "partial verification (AC4)" do
    test "a disclosure only about the full suite does not re-prompt when CI is green", ctx do
      rig = rig(ctx, "feature/ci-7")
      start_forge(ctx, rig, [:success])

      gate = start_gate(rig, ctx, command: [@probe, "RC_SUITE"])
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 20_000

      assert passes(rig) == 1
    end

    test "any other partial disclosure still re-prompts, CI green or not", ctx do
      rig = rig(ctx, "feature/ci-8")
      start_forge(ctx, rig, [:success])

      gate = start_gate(rig, ctx, command: [@probe, "RC_OTHER"])
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 20_000

      assert passes(rig) == 2
    end

    test "without the gate the suite-only disclosure re-prompts exactly as before", ctx do
      ws = new_ws(%{"review" => %{"required" => true, "require_ci_green" => false}})
      rig = rig(Map.put(ctx, :ws, ws), "feature/ci-9")

      gate = start_gate(rig, Map.put(ctx, :ws, ws), command: [@probe, "RC_SUITE"])
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 20_000

      assert passes(rig) == 2
      assert StubMerger.get_count(@pr) == 0
    end
  end

  # ---- AC5: off, and no CI result ------------------------------------------------

  describe "off, and falling back (AC5)" do
    test "with the setting off the reviewer is dispatched at once and CI is never read", ctx do
      ws = new_ws(%{"review" => %{"required" => true, "require_ci_green" => false}})
      ctx = Map.put(ctx, :ws, ws)
      rig = rig(ctx, "feature/ci-10")
      start_forge(ctx, rig, [:failed])

      gate = start_gate(rig, ctx)
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 20_000

      assert passes(rig) == 1
      assert StubMerger.get_count(@pr) == 0
    end

    test "a poll timeout falls back to a reviewer that runs the tests, and records why", ctx do
      rig = rig(ctx, "feature/ci-11")
      start_forge(ctx, rig, [:running])

      gate = start_gate(rig, ctx, ci_max_polls: 3, command: [@probe, "HOLD"])

      wait_until(fn -> passes(rig) == 1 end, 20_000)

      prompt = :sys.get_state(gate).current_prompt
      refute prompt =~ "Do not run the full test suite."
      assert prompt =~ "CI could not vouch for this head"
      assert prompt =~ "within 3 polls"

      assert Enum.any?(gate_messages(ctx, rig), &(&1.body =~ "CI did not gate this review"))
      assert Ash.get!(Issue, rig.task.id).review_gate_state["ci_wait"] == nil
      stop_gate(gate)
    end

    test "no PR to read CI from falls back at once", ctx do
      rig = rig(ctx, "feature/ci-12")

      gate = start_gate(rig, ctx, pr_ref: nil, command: [@probe, "HOLD"])
      wait_until(fn -> passes(rig) == 1 end, 20_000)

      assert StubMerger.get_count(@pr) == 0
      assert :sys.get_state(gate).current_prompt =~ "no PR"
      stop_gate(gate)
    end
  end

  # ---- the author's liveness check (AC3) ------------------------------------------

  describe "the author's liveness check" do
    test "does not stall out a gate that is waiting on CI by design", ctx do
      rig = rig(ctx, "feature/ci-13")
      start_forge(ctx, rig, [:running])

      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], ci_max_polls: 500)
      wait_until(fn -> awaiting_ci?(gate) end)

      # The author probes its gate every 50ms and would stop one with nothing in
      # flight after 200ms. A CI wait has nothing in flight and must survive it.
      ref = Process.monitor(rig.author)

      :sys.replace_state(rig.author, fn s ->
        meta =
          Map.merge(s.meta, %{
            review_gate_pid: gate,
            review_gate_ref: Process.monitor(gate),
            review_gate_liveness_ms: 50,
            review_gate_stall_ms: 200
          })

        %{s | meta: meta}
      end)

      send(rig.author, {:__review_gate_liveness__, gate})

      # Several liveness ticks, well past the stall limit.
      probes_before = StubMerger.get_count(@pr)
      wait_until(fn -> StubMerger.get_count(@pr) >= probes_before + 40 end, 10_000)
      Process.sleep(600)

      assert Process.alive?(gate)
      assert awaiting_ci?(gate)
      assert %{state: :waiting, waiting_on: :review_gate} = Worker.state(rig.author)
      refute_received {:DOWN, ^ref, :process, _, _}
      stop_gate(gate)
    end
  end

  # ---- boot: a server restart during the wait (bd-2gc809) ---------------------

  describe "a server restart during the CI wait" do
    test "re-arms as a slotless CI wait: no worker, no slot, attention reads waiting-on-CI",
         ctx do
      rig = rig(ctx, "feature/ci-14")
      start_forge(ctx, rig, [:running])
      restart_during_wait(ctx, rig)

      # Restarted: nothing resident, but the ticket still carries the marker.
      assert Worker.whereis(rig.task.id) == nil
      assert Ash.get!(Issue, rig.task.id).review_gate_state["ci_wait"]["sha"] == rig.head

      assert {:ok, gate} = ReviewGate.rearm_ci_wait(rig.task.id, gate_opts())
      wait_until(fn -> awaiting_ci?(gate) end)

      issue = Ash.get!(Issue, rig.task.id)
      refute SlotGate.holds_slot?(issue)
      assert issue.state == :active
      assert issue.review_gate_state["ci_wait"]["sha"] == rig.head
      assert Worker.whereis(rig.task.id) == nil
      assert passes(rig) == 0
      assert implement_runs(rig) == 1

      view = Projection.view(issue)
      assert view.step == :awaiting_ci
      assert view.ci_wait.sha == rig.head
      refute view.attention in [:run_crashed, :worker_stopped]

      assert Projection.payload(view).ci_wait["label"] =~
               "waiting on CI #{String.slice(rig.head, 0, 12)}"

      stop_gate(gate)
    end

    test "CI already green on the head: the reviewer is dispatched, the implementer is not resumed",
         ctx do
      rig = rig(ctx, "feature/ci-15")
      forge = start_forge(ctx, rig, [:running])
      restart_during_wait(ctx, rig)
      set_pipeline(forge, [:success])

      assert {:ok, gate} = ReviewGate.rearm_ci_wait(rig.task.id, gate_opts())
      wait_until(fn -> passes(rig) == 1 end, 20_000)

      assert reviewed_head(rig) == rig.head
      assert :sys.get_state(gate).current_prompt =~ "CI passed on #{rig.head}"
      assert Worker.whereis(rig.task.id) == nil
      assert implement_runs(rig) == 1
      assert Ash.get!(Issue, rig.task.id).review_gate_state["ci_wait"] == nil
      stop_gate(gate)
    end

    test "CI red on the head takes the existing red path (rerun, then the fix round)", ctx do
      rig = rig(ctx, "feature/ci-16")

      StubMerger.set_failing_checks(@pr, [
        %{name: "unit tests", summary: "1) boom", url: "https://ci/1", files: []}
      ])

      forge = start_forge(ctx, rig, [:running])
      restart_during_wait(ctx, rig)
      set_pipeline(forge, [:failed, :running, :failed, :success])

      assert {:ok, gate} =
               ReviewGate.rearm_ci_wait(
                 rig.task.id,
                 gate_opts(revise_command: [@revise_commit], rounds: 3)
               )

      wait_until(fn -> passes(rig) == 1 end, 30_000)
      fixed = remote_head(ctx, rig)
      refute fixed == rig.head
      assert length(StubMerger.ci_reruns()) == 1
      assert reviewed_head(rig) == fixed
      assert Worker.whereis(rig.task.id) == nil
      stop_gate(gate)
    end

    test "the head moved while the server was down: waits on the head that is there", ctx do
      rig = rig(ctx, "feature/ci-17")
      start_forge(ctx, rig, [:running])
      restart_during_wait(ctx, rig)
      pushed = push_other_commit(ctx, rig)

      assert {:ok, gate} = ReviewGate.rearm_ci_wait(rig.task.id, gate_opts())
      wait_until(fn -> awaiting_ci?(gate) end)

      assert Ash.get!(Issue, rig.task.id).review_gate_state["ci_wait"]["sha"] == pushed
      assert passes(rig) == 0
      stop_gate(gate)
    end

    test "a ticket with no marker, or no worktree, is not re-armed", ctx do
      rig = rig(ctx, "feature/ci-18")
      assert {:error, :no_ci_wait} = ReviewGate.rearm_ci_wait(rig.task.id, gate_opts())

      start_forge(ctx, rig, [:running])
      restart_during_wait(ctx, rig)
      File.rm_rf!(rig.wt)
      assert {:error, :no_worktree} = ReviewGate.rearm_ci_wait(rig.task.id, gate_opts())
    end
  end

  describe "Reconciler.reconcile_ci_waits/1" do
    alias Arbiter.Workers.Reconciler

    test "re-arms a waiting ticket and keeps the resume sweep off it", ctx do
      rig = rig(ctx, "feature/ci-19")
      start_forge(ctx, rig, [:running])
      restart_during_wait(ctx, rig)
      me = self()

      rearm = fn issue ->
        result = ReviewGate.rearm_ci_wait(issue.id, gate_opts())
        send(me, {:rearmed, result})
        result
      end

      assert {:ok, %{rearmed: 1, failed: 0}} =
               Reconciler.reconcile_ci_waits(rearm_fun: rearm)

      assert_received {:rearmed, {:ok, gate}}

      assert {:ok, %{resumed: 0, escalated: 0}} =
               Reconciler.reconcile_resumable_tasks(
                 resume_fun: fn issue -> flunk("resumed #{issue.id}") end
               )

      wait_until(fn -> awaiting_ci?(gate) end)
      stop_gate(gate)
    end

    test "a wait that cannot be re-armed is cleared so the ordinary resume path takes it",
         ctx do
      rig = rig(ctx, "feature/ci-20")
      start_forge(ctx, rig, [:running])
      restart_during_wait(ctx, rig)

      assert {:ok, %{rearmed: 0, failed: 1}} =
               Reconciler.reconcile_ci_waits(rearm_fun: fn _ -> {:error, :no_worktree} end)

      assert Ash.get!(Issue, rig.task.id).review_gate_state["ci_wait"] == nil
      me = self()

      assert {:ok, %{resumed: 1}} =
               Reconciler.reconcile_resumable_tasks(
                 resume_fun: fn issue ->
                   send(me, {:resumed, issue.id})
                   {:ok, %{}}
                 end
               )

      assert_received {:resumed, id}
      assert id == rig.task.id
    end

    test "is a no-op off the primary instance", _ctx do
      assert {:ok, :skipped} = Reconciler.reconcile_ci_waits(primary?: false)
    end
  end

  # ---- git rig -------------------------------------------------------------

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # A feature branch with one commit, checked out in its own worktree and
  # already pushed (so the head the gate waits on is the head origin carries).
  defp rig(ctx, branch) do
    {:ok, task} =
      Ash.create(Issue, %{title: "ci-gate task", workspace_id: ctx.ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    git!(["checkout", "-q", "-b", branch], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "feature work"], ctx.repo)
    git!(["checkout", "-q", "main"], ctx.repo)

    wt = Path.join(ctx.tmp, "wt-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: ctx.repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["push", "-q", "-u", "origin", branch], wt)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", ctx.repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    %{
      task: task,
      branch: branch,
      wt: wt,
      head: sha(wt, "HEAD"),
      author: start_author(task, ctx, branch, wt)
    }
  end

  defp remote_head(ctx, rig),
    do: sha(Path.join(ctx.tmp, "origin.git"), "refs/heads/" <> rig.branch)

  # Another actor pushes a commit to the branch on origin.
  defp push_other_commit(ctx, rig) do
    other = Path.join(ctx.tmp, "other-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", Path.join(ctx.tmp, "origin.git"), other])
    git!(["config", "user.email", "o@example.com"], other)
    git!(["config", "user.name", "O"], other)
    git!(["config", "commit.gpgsign", "false"], other)
    git!(["checkout", "-q", rig.branch], other)
    File.write!(Path.join(other, "theirs.txt"), "theirs\n")
    git!(["add", "theirs.txt"], other)
    git!(["commit", "-q", "-m", "theirs"], other)
    git!(["push", "-q", "origin", rig.branch], other)
    sha(other, "HEAD")
  end

  defp common_dir(rig) do
    {dir, 0} = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], rig.wt)
    String.trim(dir)
  end

  defp passes(rig) do
    case File.read(Path.join(common_dir(rig), "review_ci_passes")) do
      {:ok, n} ->
        case Integer.parse(String.trim(n)) do
          {count, ""} -> count
          _ -> 0
        end

      _ ->
        0
    end
  end

  # The commit the reviewer's own checkout was at.
  defp reviewed_head(rig),
    do: Path.join(common_dir(rig), "review_ci_reviewed_head") |> File.read!() |> String.trim()

  defp gate_opts(extra \\ []) do
    Keyword.merge(
      [
        timeout_ms: 15_000,
        rounds: 1,
        ci_adapter: StubMerger,
        ci_poll_ms: 25,
        ci_max_polls: 40,
        command: [@probe, "HOLD"]
      ],
      extra
    )
  end

  defp implement_runs(rig) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^rig.task.id and kind == :implement)
    |> Ash.read!()
    |> length()
  end

  # Wait on CI under a real gate, then kill the gate and its author outright —
  # no terminate/2, so nothing clears the ticket's marker: what a deploy leaves.
  # The head is also recorded on the PR the way the author's hand-off does.
  defp restart_during_wait(ctx, rig) do
    :ok = Arbiter.Tasks.PullRequest.record_review_gate(rig.task.id, %{pr_ref: @pr})
    gate = start_gate(rig, ctx, command: [@probe, "HOLD"])
    wait_until(fn -> awaiting_ci?(gate) end)

    for pid <- [gate, rig.author] do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    # The registry drops the killed author asynchronously; a restart starts empty.
    wait_until(fn -> Worker.whereis(rig.task.id) == nil end)
  end

  defp stop_gate(gate) do
    ref = Process.monitor(gate)
    GenServer.stop(gate, :normal)
    assert_receive {:DOWN, ^ref, :process, ^gate, _}, 5_000
  end

  # ---- app rig -------------------------------------------------------------

  defp new_ws(config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-ci-#{System.unique_integer([:positive])}",
        prefix: "rc",
        config: Map.put(config, "review_gate", %{"max_fix_rounds" => 0})
      })

    ws
  end

  defp start_author(task, ctx, branch, wt) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ctx.ws.id,
        meta: %{
          branch: branch,
          repo_path: ctx.repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    author
  end

  defp start_gate(rig, ctx, opts \\ []) do
    {:ok, gate} =
      ReviewGate.start(
        [
          author: rig.author,
          task_id: rig.task.id,
          workspace_id: ctx.ws.id,
          repo: "trib/repo",
          worktree_path: rig.wt,
          branch: rig.branch,
          target_branch: "main",
          timeout_ms: 15_000,
          rounds: 1,
          pr_ref: @pr,
          ci_adapter: StubMerger,
          ci_poll_ms: 25,
          ci_max_polls: 40,
          command: [@probe, "APPROVE"]
        ]
        |> Keyword.merge(opts)
      )

    gate
  end

  # The forge: answers from a scripted pipeline and, unless pinned, the live tip
  # of the origin branch.
  defp start_forge(ctx, rig, script) do
    agent =
      start_supervised!(%{
        id: make_ref(),
        start: {Agent, :start_link, [fn -> %{head: nil, script: script} end]}
      })

    StubMerger.queue_get(@pr, [
      fn ->
        Agent.get_and_update(agent, fn %{script: [pipeline | rest]} = st ->
          next = if rest == [], do: [pipeline], else: rest
          head = st.head || remote_head(ctx, rig)
          {%{head_sha: head, pipeline: pipeline}, %{st | script: next}}
        end)
      end
    ])

    agent
  end

  defp set_pipeline(forge, script), do: Agent.update(forge, &%{&1 | script: script})
  defp set_head(forge, head), do: Agent.update(forge, &%{&1 | head: head})

  defp awaiting_ci?(gate), do: :sys.get_state(gate).phase == :awaiting_ci

  defp gate_messages(ctx, rig) do
    Message
    |> Ash.Query.filter(workspace_id == ^ctx.ws.id)
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == rig.task.id))
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end
end
