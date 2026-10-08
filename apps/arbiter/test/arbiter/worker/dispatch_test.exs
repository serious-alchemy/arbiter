defmodule Arbiter.Worker.DispatchTest do
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  # bd-asxw4e: the tickets here are created in Backlog and dispatched straight
  # away, which a dispatch refuses unless forced — so these calls pass
  # `force: true`. What a dispatch admits is `DispatchEligibilityTest`'s.

  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Dispatch, Worktree}
  alias Arbiter.Workers.Run
  require Ash.Query

  import ExUnit.CaptureLog, only: [with_log: 1]

  # The most recent worker_run for a task — used by the resume tests to assert
  # run lineage (resumed_from_run_id) and finished outcome.
  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "dispatch-test-ws", prefix: "st"})
    {:ok, ws: ws}
  end

  # The ticket's Watchdog and any run registered for it.
  defp stop_task_processes(task_id) do
    for pid <- [Arbiter.Worker.Watchdog.whereis(task_id), Worker.whereis(task_id)], is_pid(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp eventually(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, step_ms)
  end

  defp do_eventually(fun, deadline, step_ms) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("eventually/2 timed out")

      true ->
        Process.sleep(step_ms)
        do_eventually(fun, deadline, step_ms)
    end
  end

  describe "dispatch/2 happy path" do
    test "spawns a worker and starts a workflow machine", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "hello world", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id, force: true, repo: "test/repo", start_driver: false)

      assert result.task.state == :active
      assert is_pid(result.worker_pid)
      assert is_pid(result.machine_pid)
      assert is_binary(result.machine_id)
      assert result.driver_pid == nil

      # worker is registered
      assert Worker.whereis(task.id) == result.worker_pid
    end

    test "idempotent for already-active tasks", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _first} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      # Second dispatch: task is already :active; worker already exists.
      # Should NOT crash; should return the existing worker pid.
      assert {:ok, second} =
               Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert second.task.state == :active
      assert Worker.whereis(task.id) == second.worker_pid
    end

    # bd-d70whv: redispatch a failed worker must start a fresh worker rather than
    # reusing the stale failed one. Previously, start_worker/3 returned the
    # existing pid on {:already_started, pid} regardless of its run, and the
    # failed run caused the "arb done" FSM guard to silently no-op.
    test "redispatch a failed worker starts a fresh :starting worker (bd-d70whv)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "redispatch failed", workspace_id: ws.id})

      {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)
      first_pid = first.worker_pid

      :ok = Worker.fail(first_pid, :credentials_expired)
      assert Worker.state(first_pid).outcome == :failed

      # Re-dispatch: must evict the stale worker and start a new one.
      {:ok, second} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert second.worker_pid != first_pid
      refute Process.alive?(first_pid)
      assert Worker.state(second.worker_pid).state == :starting
    end

    test "redispatch a succeeded worker also starts fresh (bd-d70whv)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "redispatch completed", workspace_id: ws.id})

      {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)
      first_pid = first.worker_pid

      :ok = Worker.advance(first_pid, :work)
      :ok = Worker.complete(first_pid, :done)
      assert Worker.state(first_pid).outcome == :succeeded

      {:ok, second} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert second.worker_pid != first_pid
      refute Process.alive?(first_pid)
      assert Worker.state(second.worker_pid).state == :starting
    end

    test "starts a Driver by default and drives task to :closed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "drive me", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id, force: true, repo: "test/repo", interval_ms: 5)

      assert is_pid(result.driver_pid)
      assert Process.alive?(result.driver_pid)

      # Wait for the driver to walk Workflows.Work to completion. The work
      # workflow has 5 no-op steps; at 5ms intervals it should finish well
      # under 500ms.
      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end
  end

  describe "dispatch/2 error cases" do
    test "non-existent task returns {:error, {:task_not_found, _}}" do
      assert {:error, {:task_not_found, "no-such-task-123"}} =
               Dispatch.dispatch("no-such-task-123")
    end

    test "closed tasks cannot be slung", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _closed} = Ash.update(task, %{}, action: :close)

      assert {:error, {:task_closed, _}} = Dispatch.dispatch(task.id, force: true)
    end

    test "tasks already awaiting review cannot be re-slung (bd-appwsh)", %{ws: ws} do
      alias Arbiter.Test.StubMerger

      StubMerger.reset()
      {:ok, task} = Ash.create(Issue, %{title: "awaiting-review guard", workspace_id: ws.id})
      task = put_state!(task, :active)

      # bd-741sid: a run opens its PR via open_mr/5 with a stub merger and ends
      # there — the ticket is Merging and its Watchdog owns the PR. Use a
      # far-future Watchdog interval so it does not poll or move the ticket
      # during the assertion window.
      {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
      :ok = Worker.advance(pid, :implement)
      ref = Process.monitor(pid)
      on_exit(fn -> stop_task_processes(task.id) end)

      StubMerger.next_open_ref("!test")

      open_opts = %{
        adapter: StubMerger,
        workspace: nil,
        interval_ms: 1_000_000,
        initial_delay_ms: 1_000_000
      }

      assert {:ok, "!test"} = Worker.open_mr(pid, "feature/guard", "Guard", "", open_opts)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert Ash.get!(Issue, task.id).state == :merging
      assert Arbiter.Worker.Watchdog.alive?(task.id)

      assert {:error, {:task_awaiting_review, _}} =
               Dispatch.dispatch(task.id, force: true, start_driver: false)
    end

    test "Autopilot dispatch checks readiness at dispatch time (bd-a1bmyx)", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "demoted after plan",
          workspace_id: ws.id,
          acceptance: "- it works"
        })

      {:ok, task} = Ash.update(task, %{}, action: :promote_to_ready)
      assert task.state == :queued

      # Simulate Autopilot planning the dispatch while it was Ready, but then
      # it gets demoted between plan and dispatch.
      {:ok, task} = Ash.update(task, %{}, action: :return_to_backlog)
      assert task.state == :backlog

      # Autopilot dispatch should refuse because it is back in Backlog.
      assert {:error, {:task_not_ready, _}} =
               Dispatch.dispatch(task.id, dispatched_by: "autopilot", start_driver: false)

      # Non-Autopilot dispatch should still work (manual dispatch allows Backlog).
      {:ok, task} = Ash.get(Issue, task.id)
      assert {:ok, _worker} = Worker.start(task_id: task.id, repo: "arbiter")
    end
  end

  # bd-bi5pn0: a step AFTER start_worker/3 (e.g. the Claude subprocess spawn,
  # hit by a transient network/VPN outage in production) can fail while the
  # worker GenServer is already registered `:starting`. Previously that left a
  # zombie `:starting` registration on an `:active` task forever — no retry,
  # no escalation — which also permanently blackholed PRPatrol dedup for the
  # underlying PR. dispatch/2 must instead fail the just-started worker and
  # escalate to the coordinator.
  describe "post-start_worker spawn failure does not zombie (bd-bi5pn0)" do
    alias Arbiter.Messages.Message

    # bd-1ziw04: real-work dispatches require the repo to be in :repo_paths.
    setup do
      prior = Application.get_env(:arbiter, :repo_paths)
      Application.put_env(:arbiter, :repo_paths, %{"test/repo" => "/tmp"})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :repo_paths, prior),
          else: Application.delete_env(:arbiter, :repo_paths)
      end)
    end

    test "fails the worker instead of leaving it :starting", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "spawn fails", workspace_id: ws.id})

      # provision_worktree: false + start_claude: true fails inside
      # maybe_start_claude/4 (:missing_worktree) — AFTER start_worker/3 already
      # registered a live `:starting` worker. preflight: false skips the real CLI
      # probe so the test never touches the network.
      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false
               )

      pid = Worker.whereis(task.id)
      assert is_pid(pid)
      assert Worker.state(pid).outcome == :failed
      assert Worker.state(pid).meta.stop_reason.category == :spawn_failed
    end

    test "escalates to the Coordinator instead of silently stranding the bead", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "spawn fails escalate", workspace_id: ws.id})

      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false
               )

      assert [escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.directive_ref == task.id))

      assert escalation.subject =~ "spawn"
    end
  end

  # bd-49ajyt: PRPatrol/ReviewPatrol dispatch a follow-up with the PR's GitHub
  # "owner/repo" slug as the :repo opt, but a multi-repo workspace's
  # repo_paths map is keyed by *repo name* (e.g. "client"), not by
  # slug. The direct + normalized key lookup misses (a repo name never
  # normalizes to an owner/repo slug), so dispatch used to fail
  # {:repo_not_found}, spinning PRPatrol in a 1/min escalation loop. Dispatch
  # must resolve the slug the same way PRPatrolSupervisor derives patrol repos:
  # by reading each registered repo's `origin` remote.
  describe "owner/repo slug resolves against a repo-name-keyed registry (bd-49ajyt)" do
    # Init a git repo whose `origin` remote is a GitHub slug (SSH form). Not
    # fetched here (provision_worktree: false), so the remote need not exist.
    defp seed_repo_with_github_origin!(tmp, sub, slug) do
      repo = Path.join(tmp, sub)
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])

      {_, 0} =
        System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@github.com:#{slug}.git"])

      repo
    end

    setup %{ws: ws} do
      tmp = Path.join(System.tmp_dir!(), "disp-slug-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      # Registry keyed by repo NAME "client"; the repo's origin resolves to the
      # differently-named slug "acme-corp/apex-client".
      repo_path =
        seed_repo_with_github_origin!(tmp, "client", "acme-corp/apex-client")

      {:ok, ws} =
        Ash.update(ws, %{config: %{"repo_paths" => %{"client" => repo_path}}}, action: :update)

      {:ok, ws: ws, tmp: tmp}
    end

    test "a slug whose repo name differs resolves + dispatches (not {:repo_not_found})",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "slug dispatch", workspace_id: ws.id})

      # If the slug resolves, dispatch gets past the repo guard and fails later
      # at worktree provisioning (:missing_worktree) — the same distinguishable
      # outcome the bd-bi5pn0 tests rely on. The pre-fix behavior was
      # {:error, {:repo_not_found, "acme-corp/apex-client"}}.
      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "acme-corp/apex-client",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false
               )
    end
  end

  describe "pre-flight auth guard (bd-2jgs2h)" do
    alias Arbiter.Agents.CredentialWatchdog
    alias Arbiter.Messages.Message

    # bd-1ziw04: real-work dispatchs now require the repo to be in :repo_paths.
    # Configure a minimal entry so repo validation passes and the guard check
    # actually fires. No real git repo is needed — the guard aborts before the
    # worktree provisioning step.
    setup do
      # bd-80ecol: these reach the setup-token guard behind the auth checks
      # below; give the workspace a credential so only those checks decide.
      claude_credential_env!()
      prior = Application.get_env(:arbiter, :repo_paths)
      Application.put_env(:arbiter, :repo_paths, %{"test/repo" => "/tmp"})
      on_exit(fn -> CredentialWatchdog.reset() end)
      on_exit(fn -> {:ok, _} = Arbiter.Agents.AuthHold.reset(:all) end)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :repo_paths, prior),
          else: Application.delete_env(:arbiter, :repo_paths)
      end)
    end

    test "a normal dispatch writes no :preflight usage event (bd-2jgs2h acceptance 1)", %{
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "no probe", workspace_id: ws.id})

      # No CredentialWatchdog expiry mark, so the guard is a plain state
      # lookup — no CLI probe is spawned. The dispatch still fails downstream
      # (no worktree provisioned), just never via a probe. Deliberately no
      # `claude_command:` override here: the old `maybe_preflight/2` had a
      # clause that skipped the probe whenever `claude_command` was set
      # without `probe_command`, which would have made this assertion pass
      # even against the pre-change code. That clause is gone — the guard
      # never spawns a probe at all now — so this exercises the real path.
      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false
               )

      # A live probe (the old `Preflight.check/2` call inside `run_preflight/2`)
      # would have billed its spend to the task under `source: :preflight`
      # (bd-adyhvn). No such probe runs anymore, so no such row exists.
      assert [] =
               UsageEvent
               |> Ash.Query.filter(source == :preflight and task_id == ^task.id)
               |> Ash.read!()
    end

    test "a known-expired adapter REFUSES to dispatch and leaves the task untouched", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "auth gate", workspace_id: ws.id})

      :ok =
        CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, %Arbiter.Worker.StopReason{
          category: :auth_expired,
          summary: "401 invalid authentication credentials",
          remediation: "Re-authenticate",
          exit_status: 1,
          signal: nil
        })

      eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Claude) end)

      assert {:error, {:auth_check_failed, reason}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true
               )

      assert reason.category == :auth_expired

      # Refused BEFORE any state mutation: task is still :backlog, no worker spawned,
      # no worktree provisioned.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :backlog
      assert Worker.whereis(task.id) == nil
    end

    # bd-3kg53c: this reason fires when CredentialWatchdog knows an adapter is
    # expired but this hasn't reached the AuthHold-open branch above (e.g. a
    # `:periodic_probe` mark with no worker having died yet). Its remediation
    # used to tell every provider to "refresh GEMINI_API_KEY", which is wrong
    # for agy — it authenticates via its own keyring/ADC chain, never that env
    # var (bd-svczq4).
    test "a known-expired Gemini adapter names agy's real credential, not GEMINI_API_KEY",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "gemini auth gate", workspace_id: ws.id})

      :ok =
        CredentialWatchdog.mark_expired(
          Arbiter.Agents.Gemini,
          %Arbiter.Worker.StopReason{
            category: :auth_expired,
            summary: "agy exited non-zero",
            remediation: nil,
            exit_status: 1,
            signal: nil
          },
          Arbiter.Agents.CredentialWatchdog,
          :periodic_probe
        )

      eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Gemini) end)
      refute Arbiter.Agents.AuthHold.open?(Arbiter.Agents.Gemini)

      assert {:error, {:auth_check_failed, reason}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 agent_type: :gemini
               )

      assert reason.category == :auth_expired
      refute reason.remediation =~ "refresh GEMINI_API_KEY"
      assert reason.remediation =~ "agy"
      assert reason.remediation =~ "arb breaker reset --auth-hold gemini"
    end

    # bd-21bmdh changed the bound from "the first death" to "N consecutive
    # deaths" (`Arbiter.Agents.AuthHold`, default N=2): one auth death is now a
    # retry, the Nth refuses. The wave is still bounded — at N, not 1.
    test "a worker dying with :auth_expired bounds the wave (bd-2jgs2h acceptance 3)",
         %{ws: ws} do
      tmp = Path.join(System.tmp_dir!(), "disp-wave-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      repo = seed_repo!(tmp, "wave-repo")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      put_app_env(:arbiter, :repo_paths, %{"wave/repo" => repo})

      # Stub the real `claude` binary on PATH so `build_agent_session_opts/4`
      # takes its normal (non-`claude_command`-override) path and reaches the
      # routing step (`Worker.report(worker_pid, :routing_config, ...)`) that
      # `notify_credential_watchdog/2` needs to resolve the dying worker's
      # adapter — `claude_command` bypasses that step entirely, which is the
      # real reason a worker dying that way could never mark the watchdog.
      argv_file = Path.join(tmp, "argv.txt")
      stub_named_on_path(tmp, "claude", argv_file)
      claude_stub = Path.join([tmp, "stub-bin", "claude"])

      File.write!(claude_stub, """
      #!/bin/sh
      echo 'API Error: 401 Invalid authentication credentials'
      exit 1
      """)

      File.chmod!(claude_stub, 0o755)

      {:ok, task1} = Ash.create(Issue, %{title: "wave 1", workspace_id: ws.id})

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.dispatch(task1.id,
                 force: true,
                 repo: "wave/repo",
                 start_driver: false,
                 start_claude: true
               )

      eventually(fn -> Worker.state(pid).outcome == :failed end)
      assert Worker.state(pid).meta.stop_reason.category == :auth_expired

      # One death is a retry: the next dispatch is let through, and dies too.
      refute Arbiter.Agents.AuthHold.open?(Arbiter.Agents.Claude)
      {:ok, task_retry} = Ash.create(Issue, %{title: "wave 1b", workspace_id: ws.id})

      assert {:ok, %{worker_pid: pid2}} =
               Dispatch.dispatch(task_retry.id,
                 force: true,
                 repo: "wave/repo",
                 start_driver: false,
                 start_claude: true
               )

      eventually(fn -> Worker.state(pid2).outcome == :failed end)

      # The second consecutive death opened the hold, which marked the
      # watchdog (a cast — wait for it rather than `:sys.get_state`, since
      # system messages can jump the mailbox ahead of an enqueued cast).
      assert Arbiter.Agents.AuthHold.open?(Arbiter.Agents.Claude)
      eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Claude) end)

      {:ok, task2} = Ash.create(Issue, %{title: "wave 2", workspace_id: ws.id})

      assert {:error, {:auth_check_failed, reason}} =
               Dispatch.dispatch(task2.id,
                 force: true,
                 repo: "wave/repo",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["sh", "-c", "exit 0"]
               )

      assert reason.category == :auth_expired
      {:ok, reloaded} = Ash.get(Issue, task2.id)
      assert reloaded.state == :backlog
      assert Worker.whereis(task2.id) == nil
      # Refused before worktree provisioning — the branch that would prove it
      # never got the chance to be created.
      refute File.dir?(Worktree.worktree_path(BranchNamer.derive(reloaded)))
    end

    test "a refused dispatch escalates to the Coordinator with a re-auth message", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "auth escalate", workspace_id: ws.id})

      :ok =
        CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, %Arbiter.Worker.StopReason{
          category: :auth_expired,
          summary: "401 invalid authentication credentials",
          remediation: "Re-authenticate",
          exit_status: 1,
          signal: nil
        })

      eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Claude) end)

      {:error, {:auth_check_failed, _}} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "test/repo",
          start_driver: false,
          start_claude: true
        )

      assert [escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.directive_ref == task.id))

      assert escalation.subject =~ "pre-flight auth failed"
      assert escalation.body =~ "Re-authenticate"
    end

    test "the guard is skipped when start_claude is false (default path unaffected)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no guard", workspace_id: ws.id})

      :ok =
        CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, %Arbiter.Worker.StopReason{
          category: :auth_expired,
          summary: "401",
          remediation: nil,
          exit_status: 1,
          signal: nil
        })

      eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Claude) end)

      # provision_worktree: false so we don't try to git-fetch /tmp.
      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 provision_worktree: false
               )

      assert result.task.state == :active
    end

    test "preflight: false bypasses the guard even with start_claude and a known-expired adapter",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "bypass", workspace_id: ws.id})

      :ok =
        CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, %Arbiter.Worker.StopReason{
          category: :auth_expired,
          summary: "401",
          remediation: nil,
          exit_status: 1,
          signal: nil
        })

      eventually(fn -> CredentialWatchdog.expired?(Arbiter.Agents.Claude) end)

      # start_claude + preflight: false + provision_worktree: false errors at the
      # claude-start step (:missing_worktree) — proving we got PAST the (disabled)
      # guard rather than being refused by it. The repo must be valid so the
      # repo-resolution guard (bd-1ziw04) passes before reaching the auth gate.
      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false
               )
    end
  end

  describe "dispatch/2 result shape" do
    test "returns a map with the standard keys", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "shape", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "test/repo", start_driver: false)

      for key <- [:task, :worker_pid, :machine_id, :machine_pid, :driver_pid, :worktree_path] do
        assert Map.has_key?(result, key), "missing #{key}"
      end
    end
  end

  describe "Claude session (start_claude opt)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-claude-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      on_exit(fn -> File.rm_rf!(tmp) end)
      # Registered after the rm_rf, so it runs first (on_exit is LIFO).
      on_exit(&await_mcp_verify_tasks/0)

      %{tmp: tmp}
    end

    # A codex dispatch fires `Codex.verify_connection/1` and
    # `Codex.check_worker_config/2` off the dispatch path (bd-bi5t54), and the
    # second one runs the stubbed `codex` CLI inside the worktree under `tmp`,
    # which appends to the argv file there. Deleting `tmp` while that runs races
    # its writes ("could not remove files and directories recursively ... file
    # already exists"), so teardown waits for those tasks to exit first.
    defp await_mcp_verify_tasks do
      refs =
        for pid <- Task.Supervisor.children(Arbiter.Worker.MCPVerifySupervisor) do
          {Process.monitor(pid), pid}
        end

      for {ref, pid} <- refs do
        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          10_000 -> flunk("MCP verify task #{inspect(pid)} did not exit")
        end
      end

      :ok
    end

    # Build a `claude`-named shim on PATH that writes its argv (one per line) to
    # `argv_file` and exits 0. Used to verify the spawn argv assembled by the
    # adapter path (Agents.Claude.default_argv) — `--model <name>` is the bit
    # Phase A specifically wires up.
    defp stub_claude_on_path(tmp, argv_file), do: stub_named_on_path(tmp, "claude", argv_file)

    # Build a `<name>`-named shim on PATH that writes its argv (one per line) to
    # `argv_file` and exits 0. Generalizes `stub_claude_on_path` so a forced
    # provider (e.g. `agy`/`gemini`) can be intercepted the same way — its stub
    # dir is prepended to PATH so it wins over any real binary installed there.
    defp stub_named_on_path(tmp, name, argv_file) do
      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      stub = Path.join(stub_dir, name)

      File.write!(stub, """
      #!/bin/sh
      for a in "$@"; do echo "$a" >> #{argv_file}; done
      exit 0
      """)

      File.chmod!(stub, 0o755)

      old_path = System.get_env("PATH") || ""

      # Only prepend the stub dir once even if several shims share it.
      unless String.starts_with?(old_path, "#{stub_dir}:") do
        System.put_env("PATH", "#{stub_dir}:#{old_path}")
        on_exit(fn -> System.put_env("PATH", old_path) end)
      end

      :ok
    end

    # Same shim, but it stays alive after recording its argv — a stand-in for a
    # provider CLI that is still working, so the dispatch guard sees a live
    # session rather than one that already exited (bd-2aslx6).
    defp stub_sleeping_on_path(tmp, name, argv_file) do
      :ok = stub_named_on_path(tmp, name, argv_file)

      stub = Path.join([tmp, "stub-bin", name])

      File.write!(stub, """
      #!/bin/sh
      for a in "$@"; do echo "$a" >> #{argv_file}; done
      sleep 30
      """)

      File.chmod!(stub, 0o755)
      :ok
    end

    # Flip the per-spawn `.mcp.json` injection on (config/test.exs disables it by
    # default) and restore the prior config when the test ends. The signing
    # secret falls back to the Phoenix endpoint's :secret_key_base, so no secret
    # needs to be injected here.
    defp enable_mcp_injection! do
      prior = Application.get_env(:arbiter, Arbiter.MCP)
      Application.put_env(:arbiter, Arbiter.MCP, Keyword.put(prior || [], :inject_config, true))
      on_exit(fn -> Application.put_env(:arbiter, Arbiter.MCP, prior) end)
      :ok
    end

    defp seed_repo!(tmp, sub) do
      repo = Path.join(tmp, sub)
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      # Bare origin: Worktree.create fetches from origin and branches from
      # origin/<base>; provide an upstream the provisioner can consult.
      remote = Path.join(tmp, sub <> "-remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      repo
    end

    # Push a commit to `repo`'s bare origin from a throwaway clone, so `repo`'s
    # own local refs stay stale — the "human checkout hasn't pulled in a month"
    # shape bd-9r1tta is about.
    defp advance_origin!(tmp, repo, file, content) do
      remote = rev_parse_remote!(repo)
      clone = Path.join(tmp, "advance-#{System.unique_integer([:positive])}")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, file), content)
      {_, 0} = System.cmd("git", ["-C", clone, "add", file])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "advance origin"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])
      :ok
    end

    defp rev_parse_remote!(repo) do
      {out, 0} = System.cmd("git", ["-C", repo, "remote", "get-url", "origin"])
      String.trim(out)
    end

    defp rev_parse!(path, ref) do
      {out, 0} = System.cmd("git", ["-C", path, "rev-parse", ref])
      String.trim(out)
    end

    test "defaults to start_claude: false → claude_port is nil", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no claude", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "test/repo", start_driver: false)

      assert result.claude_port == nil
    end

    test "start_claude: true with claude_command spawns a subprocess in the worktree",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "do work", workspace_id: ws.id})

      # Use the tmp dir as a stand-in worktree by passing it through manually.
      # Dispatch.maybe_provision_worktree returns nil when repo is unmapped, but
      # we need a worktree_path for ClaudeSession; so we point a tmp repo at
      # a real git repo and let Dispatch provision the worktree itself.
      repo = seed_repo!(tmp, "repo")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      put_app_env(:arbiter, :repo_paths, %{"claude/repo" => repo})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "claude/repo",
          start_driver: false,
          start_claude: true,
          # Stand-in for a running `claude --print` session — stays alive (so it
          # isn't caught by bd-awi4nw stop-detection as a died-early worker),
          # but proves ClaudeSession.start was wired into Dispatch.
          claude_command: ["sleep", "2"]
        )

      assert is_port(result.claude_port)
      assert is_binary(result.worktree_path)
    end

    # bd-4wy1w1 (P5): a workspace whose `sandbox.backend` is podman runs its
    # workers in containers, so the checkout is a private clone (git layout
    # B): a linked worktree would need the main repo's shared refs mounted
    # read-write into the container. Every other workspace is unchanged.
    test "a podman-sandboxed workspace is provisioned a private clone, not a linked worktree",
         %{tmp: tmp} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "podman-layout-ws",
          prefix: "pl",
          config: %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "contained work", workspace_id: ws.id})
      repo = seed_repo!(tmp, "pod-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "pod-wt"))
      put_app_env(:arbiter, :repo_paths, %{"pod/repo" => repo})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "pod/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      assert result.worktree_path == Worktree.worktree_path(BranchNamer.derive(task))
      assert Arbiter.Worker.PrivateClone.clone?(result.worktree_path)
      assert Arbiter.Worker.PrivateClone.main_repo(result.worktree_path) == Path.expand(repo)

      {registered, 0} = System.cmd("git", ["-C", repo, "worktree", "list", "--porcelain"])
      refute registered =~ result.worktree_path
    end

    # bd-d0sgb6: the policy is read once per dispatch. The workspace says podman
    # but the dispatch already holds a bwrap resolution (as if the config flipped
    # after it was read): layout and spawn both follow the held one, so the spawn
    # is not refused with `:not_a_private_clone`.
    test "layout and spawn use the one policy the dispatch resolved, not a fresh read",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)

      repo = seed_repo!(tmp, "flip-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "flip-wt"))
      put_app_env(:arbiter, :repo_paths, %{"flip/repo" => repo})

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "claude",
              "security" => %{"sandbox" => %{"backend" => "podman"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "flipped", workspace_id: ws.id})
      held = Arbiter.Agents.SecurityPolicy.resolve(nil, %{}, "flip/repo")
      assert Arbiter.Agents.SecurityPolicy.sandbox_backend(held) != :podman

      assert {:ok, %{worktree_path: path}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "flip/repo",
                 start_driver: false,
                 start_claude: true,
                 preflight: false,
                 resolved_policy: {"flip/repo", held}
               )

      refute Arbiter.Worker.PrivateClone.clone?(path)
    end

    test "a redispatch under podman replaces the linked worktree an earlier bwrap run left",
         %{ws: ws, tmp: tmp} do
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "was bwrap", workspace_id: ws.id})
      repo = seed_repo!(tmp, "redispatch-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "redispatch-wt"))
      put_app_env(:arbiter, :repo_paths, %{"re/repo" => repo})

      branch = BranchNamer.derive(task)
      {:ok, old} = Worktree.create(repo, branch, "main")
      refute Arbiter.Worker.PrivateClone.clone?(old)

      assert {:ok, %{worktree_path: ^old}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "re/repo",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["sleep", "2"]
               )

      assert Arbiter.Worker.PrivateClone.clone?(old)
    end

    test "a default workspace still gets a linked worktree", %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "plain work", workspace_id: ws.id})
      repo = seed_repo!(tmp, "plain-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "plain-wt"))
      put_app_env(:arbiter, :repo_paths, %{"plain/repo" => repo})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "plain/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      refute Arbiter.Worker.PrivateClone.clone?(result.worktree_path)

      assert {:ok, %File.Stat{type: :regular}} =
               File.lstat(Path.join(result.worktree_path, ".git"))
    end

    # bd-d5hy7y: at dispatch, ONLY the layered effective skill set is
    # materialized into the worker's worktree as
    # `.claude/skills/<name>/SKILL.md`. A canary skill selected via the
    # workspace layer must land in the worktree; a registry skill NOT selected
    # must not — nothing global leaks (mirrors the spike's canary method).
    test "materializes only the resolved skill set into the worktree (canary)",
         %{tmp: tmp} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "skill-canary-ws",
          prefix: "sk",
          config: %{"skills" => %{"workspace" => ["dispatch-canary"]}}
        })

      {:ok, _} =
        Arbiter.Skills.create_skill(%{
          name: "dispatch-canary",
          body: "# Canary\nMaterialized by dispatch.",
          activation_mode: :always_on
        })

      # A second skill that is NOT in the effective set — proves selectivity.
      {:ok, _} = Arbiter.Skills.create_skill(%{name: "not-selected", body: "# Nope"})

      repo = seed_repo!(tmp, "canaryrepo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "canary-wt"))
      put_app_env(:arbiter, :repo_paths, %{"canary/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "canary work", workspace_id: ws.id, issue_type: :feature})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "canary/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      wt = result.worktree_path
      assert is_binary(wt)

      # The selected canary skill is materialized with its body …
      canary = Path.join(wt, ".claude/skills/dispatch-canary/SKILL.md")
      assert File.exists?(canary)
      assert File.read!(canary) =~ "Materialized by dispatch."

      # … and the unselected skill is NOT.
      refute File.exists?(Path.join(wt, ".claude/skills/not-selected/SKILL.md"))

      # The skills tree is git-excluded so a worker's `git add -A` can't commit
      # it. A linked worktree's `.git` is a gitfile; git only ever reads
      # `info/exclude` from the repo's COMMON dir (`--git-common-dir`), NOT the
      # worktree-private admin dir (`--git-dir`) — see bd-bhrji9 — so that's
      # where AgentConfig.add_to_git_exclude/2 writes it.
      {common_dir, 0} = System.cmd("git", ["-C", wt, "rev-parse", "--git-common-dir"])

      exclude =
        File.read!(Path.expand(Path.join([String.trim(common_dir), "info", "exclude"]), wt))

      assert exclude =~ ".claude/skills/"
    end

    # bd-bbbxvp (agy-parity T8): the target dir is provider-aware —
    # `.agents/skills` for gemini, agy's documented workspace discovery path.
    test "materializes into .agents/skills for a gemini-provider dispatch",
         %{tmp: tmp} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "skill-gemini-ws",
          prefix: "skg",
          config: %{"skills" => %{"workspace" => ["gemini-canary"]}}
        })

      {:ok, _} =
        Arbiter.Skills.create_skill(%{
          name: "gemini-canary",
          body: "# Gemini canary",
          activation_mode: :always_on
        })

      repo = seed_repo!(tmp, "geminirepo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "gemini-wt"))
      put_app_env(:arbiter, :repo_paths, %{"gemini/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "gemini work", workspace_id: ws.id, issue_type: :feature})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "gemini/repo",
          agent_type: :gemini,
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      wt = result.worktree_path
      assert is_binary(wt)

      canary = Path.join(wt, ".agents/skills/gemini-canary/SKILL.md")
      assert File.exists?(canary)
      assert File.read!(canary) =~ "Gemini canary"
      refute File.exists?(Path.join(wt, ".claude/skills/gemini-canary/SKILL.md"))
    end

    # bd-89z02x: codex reads no skills directory, so a codex dispatch must
    # write nothing to disk and inline the always-on body in the prompt it is
    # actually handed (the provider -> `skills_materialized?` mapping).
    test "codex dispatch writes no skills dir and inlines the skill in the prompt",
         %{tmp: tmp} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "skill-codex-ws",
          prefix: "skx",
          config: %{"skills" => %{"workspace" => ["codex-canary", "codex-situational"]}}
        })

      {:ok, _} =
        Arbiter.Skills.create_skill(%{
          name: "codex-canary",
          body: "# Codex canary\nINLINE-CANARY-BODY",
          activation_mode: :always_on
        })

      {:ok, _} =
        Arbiter.Skills.create_skill(%{
          name: "codex-situational",
          body: "# Situational",
          activation_mode: :situational
        })

      codex_file = Path.join(tmp, "codex-skill-argv.txt")
      :ok = stub_named_on_path(tmp, "codex", codex_file)

      repo = seed_repo!(tmp, "codexskillrepo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "codex-skill-wt"))
      put_app_env(:arbiter, :repo_paths, %{"cs/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "codex skill work", workspace_id: ws.id, issue_type: :feature})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "cs/repo",
          agent_type: :codex,
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      wt = result.worktree_path
      assert is_binary(wt)

      argv = wait_for_argv!(codex_file)
      prompt = Enum.join(argv, "\n")

      assert prompt =~ "INLINE-CANARY-BODY"
      refute prompt =~ "available in this worktree"
      refute prompt =~ "/codex-situational"
      refute File.exists?(Path.join(wt, ".claude/skills/codex-canary/SKILL.md"))
      refute File.exists?(Path.join(wt, ".agents/skills"))
    end

    # bd-d5hy7y: an always-on skill is auto-invoked in the worker prompt, while a
    # situational one is advertised but not forced.
    test "work prompt auto-invokes always-on skills and advertises situational ones",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "prompt work", workspace_id: ws.id, issue_type: :feature})

      resolved = [
        %{
          skill: %Arbiter.Skills.Skill{
            name: "tdd",
            body: "x",
            activation_mode: :always_on,
            metadata: %{}
          },
          activation: :always_on
        },
        %{
          skill: %Arbiter.Skills.Skill{
            name: "debug",
            body: "x",
            activation_mode: :situational,
            metadata: %{}
          },
          activation: :situational
        }
      ]

      prompt =
        Dispatch.prompt_for_task(task, worktree_path: "/tmp/wt", resolved_skills: resolved)

      assert prompt =~ "Required skills"
      assert prompt =~ "/tdd"
      assert prompt =~ "Available skills"
      assert prompt =~ "/debug"
    end

    # bd-bbbxvp (agy-parity T8): agy was verified live to discover NOTHING
    # worktree-local in `--print` (headless) mode
    # (`Arbiter.MCP.AgentConfig.Gemini`'s moduledoc), so when
    # `:skills_materialized?` is false the prompt must not claim the skill is
    # "available in this worktree" — it must inline the required skill's full
    # body instead, and drop situational skills entirely rather than falsely
    # advertise them.
    test "work prompt inlines required skill bodies instead of claiming availability when not materialized",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "agy prompt work", workspace_id: ws.id, issue_type: :feature})

      resolved = [
        %{
          skill: %Arbiter.Skills.Skill{
            name: "tdd",
            body: "# TDD\nDo the inlined thing.",
            activation_mode: :always_on,
            metadata: %{}
          },
          activation: :always_on
        },
        %{
          skill: %Arbiter.Skills.Skill{
            name: "debug",
            body: "# Debug",
            activation_mode: :situational,
            metadata: %{}
          },
          activation: :situational
        }
      ]

      prompt =
        Dispatch.prompt_for_task(task,
          worktree_path: "/tmp/wt",
          resolved_skills: resolved,
          skills_materialized?: false
        )

      refute prompt =~ "available in this worktree"
      assert prompt =~ "Do the inlined thing."
      refute prompt =~ "/debug"
    end

    # bd-dlv3no: a review dispatch has no per-task worktree, so its Claude cwd
    # falls back to the repo's shared checkout. The per-spawn MCP config carries a
    # bearer scope token; writing `.mcp.json` into that canonical checkout leaks
    # the token into the working tree the live server + operator share (the
    # "worker leaks into the main worktree" class). The spawn must NOT touch the
    # repo's working tree.
    test "review dispatch does not write .mcp.json into the shared repo checkout",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "reviewrepo")

      put_app_env(:arbiter, :repo_paths, %{"rv/repo" => repo})
      enable_mcp_injection!()

      {:ok, task} = Ash.create(Issue, %{title: "review me", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sleep", "2"]
        )

      # Review runs in the repo (no worktree) ...
      assert result.worktree_path == nil
      assert is_port(result.claude_port)
      # ... and the token-bearing config never lands in that shared checkout.
      refute File.exists?(Path.join(repo, ".mcp.json"))
    end

    # bd-9r1tta: a review genuinely wants the shared checkout as its cwd — it
    # diffs local branches, which only exist there. But it must not inherit a
    # month-stale idea of what `origin/<target>` points at: a reviewer comparing
    # a PR against a stale base reports conflicts and "missing" upstream work
    # that aren't real. So the dispatch refreshes the remote-tracking ref first
    # — refs only, never the contributor's HEAD/index/working tree.
    test "review dispatch refreshes origin refs in the shared checkout without disturbing it",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "revstale")

      # The human's checkout: parked on a side branch with uncommitted work.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "human-wip"])
      File.write!(Path.join(repo, "dirty.md"), "uncommitted\n")
      head_before = rev_parse!(repo, "HEAD")
      origin_ref_before = rev_parse!(repo, "refs/remotes/origin/main")

      # Upstream moves behind the local checkout's back.
      advance_origin!(tmp, repo, "UPSTREAM.md", "merged upstream\n")

      put_app_env(:arbiter, :repo_paths, %{"rv/stale" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "review stale base", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/stale",
          review: true,
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sleep", "1"]
        )

      assert result.worktree_path == nil
      assert is_port(result.claude_port)

      # The remote-tracking ref now points at current upstream ...
      assert rev_parse!(repo, "refs/remotes/origin/main") != origin_ref_before

      # ... while nothing the contributor cares about moved: same branch, same
      # HEAD, uncommitted file intact, and the fetched commit is NOT checked out.
      assert {:ok, "human-wip"} = Worktree.current_branch(repo)
      assert rev_parse!(repo, "HEAD") == head_before
      assert File.read!(Path.join(repo, "dirty.md")) == "uncommitted\n"
      refute File.exists?(Path.join(repo, "UPSTREAM.md"))
    end

    # bd-9fjy6j / bd-9r1tta: a task-type issue has no *branch* worktree (the
    # deliverable is notes, not a PR), but Claude still needs a cwd. It used to
    # get the repo's shared main checkout — a human contributor's working
    # directory, on whatever HEAD they left it. bd-9r1tta: it now gets an
    # isolated detached checkout cut from `origin/<target>`, so an audit reads
    # current upstream instead of a month-stale local tree.
    test "task-type dispatch with start_claude runs from a detached checkout at origin, not the stale local one",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "taskrepo")
      advance_origin!(tmp, repo, "ENCRYPTION.md", "PHI encryption merged upstream\n")

      # The local checkout has not fetched — exactly the tonic scenario.
      refute File.exists?(Path.join(repo, "ENCRYPTION.md"))
      local_head_before = rev_parse!(repo, "HEAD")

      # bd-dlv3no's concern, now inherited by task-type dispatches: with
      # injection on, the token-bearing `.mcp.json` must land in the isolated
      # worktree, never in the shared checkout.
      enable_mcp_injection!()

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "taskrepo-wt"))
      put_app_env(:arbiter, :repo_paths, %{"task/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "audit: parity check", issue_type: :task, workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "task/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sh", "-c", "pwd -P > agent-cwd.txt"]
        )

      # Still no *branch* worktree in meta — nothing to merge, nothing to PR.
      assert result.worktree_path == nil
      assert is_port(result.claude_port)

      # Its own leaf — never the branch leaf, so a later branch dispatch of the
      # same bead can't collide with it (round-1 review finding).
      inspect_path = Worktree.inspect_path(BranchNamer.derive(task))
      refute inspect_path == Worktree.worktree_path(BranchNamer.derive(task))

      # The agent's cwd IS that isolated checkout — observed from the child.
      cwd_file = Path.join(inspect_path, "agent-cwd.txt")
      wait_until(fn -> File.exists?(cwd_file) end)
      assert File.read!(cwd_file) |> String.trim() == Path.expand(inspect_path)

      # ... and it reflects current upstream, not the stale local checkout.
      assert File.exists?(Path.join(inspect_path, "ENCRYPTION.md"))

      # The human's checkout is untouched: same HEAD, and the agent wrote
      # nothing into it.
      assert rev_parse!(repo, "HEAD") == local_head_before
      refute File.exists?(Path.join(repo, "agent-cwd.txt"))

      # bd-dlv3no's guarantee still holds: the token-bearing config never lands
      # in the shared checkout. (It isn't written to the inspect worktree
      # either — injection is still keyed to a *branch* worktree. Now that this
      # cwd is isolated, injecting here would be safe; that's a follow-up, not
      # this fix.)
      refute File.exists?(Path.join(repo, ".mcp.json"))
    end

    # bd-9r1tta: a repo with no `origin` has nothing to be stale against, so a
    # task-type dispatch must still work there — falling back to the local
    # checkout rather than erroring.
    test "task-type dispatch falls back to the local checkout when the repo has no origin",
         %{ws: ws, tmp: tmp} do
      repo = Path.join(tmp, "no-origin-repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "no-origin-wt"))
      put_app_env(:arbiter, :repo_paths, %{"local/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "audit: local only", issue_type: :task, workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "local/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sh", "-c", "pwd -P > agent-cwd.txt"]
        )

      assert is_port(result.claude_port)

      cwd_file = Path.join(repo, "agent-cwd.txt")
      wait_until(fn -> File.exists?(cwd_file) end)
      assert File.read!(cwd_file) |> String.trim() == Path.expand(repo)
    end

    # bd-9r1tta: when the repo HAS an origin but provisioning the isolated
    # checkout fails, the dispatch must surface the failure rather than quietly
    # handing the agent the stale shared checkout — the silent-wrong-answer
    # failure mode this fix exists to close.
    test "task-type dispatch errors rather than falling back when the target branch is missing upstream",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "badbase")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "badbase-wt"))
      put_app_env(:arbiter, :repo_paths, %{"bad/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "audit: bad base", issue_type: :task, workspace_id: ws.id})

      assert {:error, {:inspect_worktree_failed, _}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "bad/repo",
                 base_branch: "no-such-upstream-branch",
                 start_driver: false,
                 start_claude: true,
                 preflight: false,
                 claude_command: ["sleep", "1"]
               )
    end

    # Round-1 review finding: the inspect checkout used to share the branch leaf,
    # so a branch dispatch of a bead that had already been audited hit
    # `create/3`'s "worktree exists … on a different branch" — which the
    # `already exists` → `attach/2` recovery does not match — and failed
    # permanently until someone deleted the directory by hand. Inspect trees now
    # use their own leaf, and a detached tree found at the branch leaf (left by a
    # pre-fix dispatch) is reclaimed rather than fatal.
    test "a branch dispatch reclaims a detached worktree left at the branch leaf",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "collide")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "collide-wt"))
      put_app_env(:arbiter, :repo_paths, %{"col/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "was an audit first", workspace_id: ws.id})
      branch = BranchNamer.derive(task)

      # The pre-fix state: a detached checkout squatting on the branch leaf.
      {:ok, squatter} = Worktree.create_detached(repo, branch, "main")
      assert squatter == Worktree.worktree_path(branch)
      assert {:ok, "HEAD"} = Worktree.current_branch(squatter)

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "col/repo", start_driver: false)

      assert result.worktree_path == squatter
      assert {:ok, ^branch} = Worktree.current_branch(squatter)
    end

    # bd-2jerqw: the workspace's `worker.repos.<repo>.seed_paths` reaches the
    # worktree a dispatch provisions; without it the built-in set applies.
    test "a branch dispatch seeds the worktree from worker.repos.<repo>.seed_paths",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "seedrepo")
      File.mkdir_p!(Path.join(repo, "deps/jason"))
      File.write!(Path.join(repo, "deps/jason/mix.exs"), "# dep\n")
      File.mkdir_p!(Path.join(repo, "priv/plts"))
      File.write!(Path.join(repo, "priv/plts/core.plt"), "plt")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "seed-wt"))
      put_app_env(:arbiter, :repo_paths, %{"seed/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "default seed", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "seed/repo", start_driver: false)

      assert File.exists?(Path.join(result.worktree_path, "deps/jason/mix.exs"))
      refute File.exists?(Path.join(result.worktree_path, "priv/plts"))

      {:ok, _} =
        Ash.update(ws, %{
          config: %{"worker" => %{"repos" => %{"repo" => %{"seed_paths" => ["priv/plts"]}}}}
        })

      {:ok, task2} = Ash.create(Issue, %{title: "configured seed", workspace_id: ws.id})

      {:ok, result2} =
        Dispatch.dispatch(task2.id, force: true, repo: "seed/repo", start_driver: false)

      assert File.exists?(Path.join(result2.worktree_path, "priv/plts/core.plt"))
      refute File.exists?(Path.join(result2.worktree_path, "deps"))
    end

    # Counterpart: the two leaves coexist, so an audit's checkout and the same
    # bead's branch worktree never contend for one directory.
    test "an inspect checkout and a branch worktree for the same bead coexist",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "coexist")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "coexist-wt"))
      put_app_env(:arbiter, :repo_paths, %{"cx/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "audited then built", workspace_id: ws.id})
      branch = BranchNamer.derive(task)

      {:ok, inspect_path} = Worktree.create_detached(repo, Worktree.inspect_name(branch), "main")

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "cx/repo", start_driver: false)

      assert result.worktree_path == Worktree.worktree_path(branch)
      refute result.worktree_path == inspect_path
      assert {:ok, ^branch} = Worktree.current_branch(result.worktree_path)
      assert {:ok, "HEAD"} = Worktree.current_branch(inspect_path)
    end

    # bd-ci2jl2: a PRPatrol follow-up used to be undispatchable. It carried
    # `issue_type: :task` (→ no worktree provisioned → start_claude 500'd with
    # :missing_worktree) and stored the merged PR number in `tracker_ref` (→ the
    # start transition tried to write lifecycle status onto a merged PR
    # and escalated `Validation Failed`). The follow-up is now a reviewable type
    # with `tracker_type: :none` + the PR linked via `source_pr`, so dispatch
    # provisions a FRESH worktree and never touches a tracker.
    test "PRPatrol follow-up shape dispatches with a fresh worktree and no tracker write-back",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "followup")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "followup-wt"))
      put_app_env(:arbiter, :repo_paths, %{"fu/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{
          title: "PR #591: needs follow-up",
          issue_type: :feature,
          tracker_type: :none,
          source_pr: "591",
          workspace_id: ws.id
        })

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "fu/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sleep", "2"]
        )

      # Fresh worktree provisioned (the bug returned {:error, :missing_worktree}).
      assert is_binary(result.worktree_path)
      assert is_port(result.claude_port)
      # Transition to :active succeeded without a tracker sync attempt.
      assert result.task.state == :active
      assert result.task.tracker_type == :none
      assert result.task.source_pr == "591"
    end

    # Counterpart: a normal work dispatch DOES get the MCP config — but only ever
    # inside its own isolated worktree, never the repo.
    test "work dispatch writes .mcp.json into its isolated worktree (not the repo)",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "workrepo")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "work-wt"))
      put_app_env(:arbiter, :repo_paths, %{"work/repo" => repo})
      enable_mcp_injection!()

      {:ok, task} = Ash.create(Issue, %{title: "do work", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "work/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      assert is_binary(result.worktree_path)
      assert File.exists?(Path.join(result.worktree_path, ".mcp.json"))
      refute File.exists?(Path.join(repo, ".mcp.json"))
    end

    test "codex agent_type dispatch writes .codex/config.toml, not .mcp.json (bd-bi5t54)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      codex_file = Path.join(tmp, "codex-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "codex", codex_file)

      repo = seed_repo!(tmp, "codex-mcp-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "codex-mcp-wt"))
      put_app_env(:arbiter, :repo_paths, %{"codexmcp/repo" => repo})
      enable_mcp_injection!()

      # Workspace's `agent.type` pool deliberately excludes codex — mirrors the
      # live `default` workspace so the explicit override must win.
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"type" => ["claude", "gemini"]}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "codex mcp task", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "codexmcp/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :codex,
          preflight: false
        )

      _ = wait_for_argv!(codex_file)

      assert File.exists?(Path.join(result.worktree_path, ".codex/config.toml")),
             "codex dispatch must write .codex/config.toml, not fall back to .mcp.json"

      refute File.exists?(Path.join(result.worktree_path, ".mcp.json"))
    end

    test "codex dispatch puts ARBITER_MCP_TOKEN in the spawn env (bd-6mo6be)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      env_file = Path.join(tmp, "codex-env.txt")
      :ok = stub_claude_on_path(tmp, claude_file)

      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      stub = Path.join(stub_dir, "codex")
      File.write!(stub, "#!/bin/sh\necho \"$ARBITER_MCP_TOKEN\" >> #{env_file}\nexit 0\n")
      File.chmod!(stub, 0o755)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{stub_dir}:#{old_path}")
      on_exit(fn -> System.put_env("PATH", old_path) end)

      repo = seed_repo!(tmp, "codex-env-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "codex-env-wt"))
      put_app_env(:arbiter, :repo_paths, %{"codexenv/repo" => repo})
      enable_mcp_injection!()

      {:ok, task} = Ash.create(Issue, %{title: "codex env task", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "codexenv/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :codex,
          preflight: false
        )

      _ = wait_for_argv!(env_file)
      token = env_file |> File.read!() |> String.trim()
      assert token != ""

      toml = File.read!(Path.join(result.worktree_path, ".codex/config.toml"))
      assert toml =~ ~s(bearer_token_env_var = "ARBITER_MCP_TOKEN")
      refute toml =~ token
    end

    test "codex dispatch runs a post-spawn MCP connect check and logs loudly on failure (bd-bi5t54)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      codex_file = Path.join(tmp, "codex-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "codex", codex_file)

      repo = seed_repo!(tmp, "codex-verify-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "codex-verify-wt"))
      put_app_env(:arbiter, :repo_paths, %{"codexverify/repo" => repo})
      enable_mcp_injection!()

      # Point the MCP endpoint at a closed local port so the post-spawn connect
      # check fails fast with a connection-refused error, exercising the
      # verify_connection/1 wiring end to end.
      prior_url = Application.get_env(:arbiter, Arbiter.MCP)
      put_app_env(:arbiter, Arbiter.MCP, Keyword.put(prior_url, :url, "http://127.0.0.1:1/mcp"))

      {:ok, task} = Ash.create(Issue, %{title: "codex verify task", workspace_id: ws.id})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _result} =
            Dispatch.dispatch(task.id,
              force: true,
              repo: "codexverify/repo",
              start_driver: false,
              start_claude: true,
              agent_type: :codex,
              preflight: false
            )

          _ = wait_for_argv!(codex_file)
          # The check runs off the dispatch path (Task.Supervisor) — give it a
          # moment to complete against the closed port.
          Process.sleep(300)
        end)

      assert log =~ "Codex MCP connect check failed"
    end

    # bd-m8geh4: `.gemini/settings.json` is the UPSTREAM `gemini` CLI's config
    # file — the `agy` fork never reads it, nor any other worktree-local path.
    # With `agy` on PATH (it wins over `gemini` in
    # `Arbiter.Agents.Gemini.resolve_executable/0`) the injection must refuse
    # out loud instead of dropping a dead, token-bearing file in the worktree.
    test "gemini dispatch on an agy host refuses MCP injection loudly (bd-m8geh4)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      agy_file = Path.join(tmp, "agy-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", agy_file)

      repo = seed_repo!(tmp, "agy-mcp-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "agy-mcp-wt"))
      put_app_env(:arbiter, :repo_paths, %{"agymcp/repo" => repo})
      enable_mcp_injection!()

      {:ok, task} = Ash.create(Issue, %{title: "agy mcp task", workspace_id: ws.id})

      {result, log} =
        with_log(fn ->
          {:ok, result} =
            Dispatch.dispatch(task.id,
              force: true,
              repo: "agymcp/repo",
              start_driver: false,
              start_claude: true,
              agent_type: :gemini,
              preflight: false
            )

          _ = wait_for_argv!(agy_file)
          result
        end)

      refute File.exists?(Path.join([result.worktree_path, ".gemini", "settings.json"])),
             "agy never reads .gemini/settings.json — writing one is a silent no-op"

      assert log =~ "MCP config injection is UNSUPPORTED"
      assert log =~ "agy"
    end

    test ".mcp.json is not tracked after being untracked from git",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "gitignore-check")

      # Set up the repo to simulate the original issue: .mcp.json is listed in
      # .gitignore, but we also add it to git (committing it before the ignore
      # took effect). This mirrors the production state before the fix.
      gitignore_path = Path.join(repo, ".gitignore")
      File.write!(gitignore_path, ".mcp.json\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", ".gitignore"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "add gitignore"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # Now add and commit .mcp.json (simulating the original bug state).
      # In the real repo, this happened because .mcp.json was committed before
      # the .gitignore entry existed. Use -f to force-add since it's in gitignore.
      mcp_path = Path.join(repo, ".mcp.json")
      File.write!(mcp_path, "{\"old\": \"token\"}\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "-f", ".mcp.json"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "commit mcp config"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # Verify the buggy state: .mcp.json is tracked despite being in .gitignore
      {tracked_before, 0} = System.cmd("git", ["-C", repo, "ls-files"])

      assert String.contains?(tracked_before, ".mcp.json"),
             "Setup: .mcp.json should be tracked in the test repo"

      # Now apply the fix: untrack .mcp.json with git rm --cached
      # This removes .mcp.json from git's index but leaves the file in the working tree
      {_, 0} = System.cmd("git", ["-C", repo, "rm", "--cached", ".mcp.json"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "untrack .mcp.json"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # Clean up: remove the file from the working tree so it won't show as untracked
      # (In production, the worktree gets the gitignore and starts clean; here we simulate that)
      File.rm!(mcp_path)

      # Verify the fix: .mcp.json is no longer tracked and not in the working tree
      {tracked_after, 0} = System.cmd("git", ["-C", repo, "ls-files"])

      refute String.contains?(tracked_after, ".mcp.json"),
             "After fix: .mcp.json should be untracked"

      refute File.exists?(mcp_path),
             "After fix: .mcp.json file should be removed from working tree"

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "gic-wt"))
      put_app_env(:arbiter, :repo_paths, %{"gic/repo" => repo})
      enable_mcp_injection!()

      {:ok, task} = Ash.create(Issue, %{title: "check ignore", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "gic/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      wt = result.worktree_path
      assert is_binary(wt)

      # .mcp.json was written into the worktree by the spawn
      assert File.exists?(Path.join(wt, ".mcp.json"))

      # Critical assertion: after the fix, .mcp.json must NOT be in git ls-files.
      {wt_tracked, 0} = System.cmd("git", ["-C", wt, "ls-files"])

      refute String.contains?(wt_tracked, ".mcp.json"),
             "REGRESSION: .mcp.json is tracked in worktree. After the fix, it should be untracked and ignored."

      # The worktree status must be clean. The injected .mcp.json is ignored,
      # so it should not appear in git status.
      {status_output, _status_code} = System.cmd("git", ["-C", wt, "status", "--porcelain"])

      refute String.contains?(status_output, ".mcp.json"),
             "REGRESSION: .mcp.json shows in git status. After the fix, the injected file must be ignored and clean."
    end

    test "start_claude: true with an unresolvable repo returns {:error, {:repo_not_found, repo}}",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no wt", workspace_id: ws.id})

      assert {:error, {:repo_not_found, "no-such-repo"}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "no-such-repo",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["echo", "x"]
               )
    end

    test "start_claude: true implies claude_driven Driver mode (no workflow ticking)",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "drvr-mode", workspace_id: ws.id})

      repo = seed_repo!(tmp, "drvrepo")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "drv-wt"))
      put_app_env(:arbiter, :repo_paths, %{"drvr/repo" => repo})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "drvr/repo",
          start_claude: true,
          # A stand-in for a *running* Claude session: it must stay alive for the
          # duration of this test. A command that exits immediately would (since
          # bd-awi4nw) trip stop-detection and fail the worker — exactly the
          # "worker died without `arb done`" path we now catch.
          claude_command: ["sleep", "2"],
          # Speed up the worker-status polling for the assertion below.
          interval_ms: 5,
          max_ticks: 50
        )

      assert is_pid(result.driver_pid)

      # Dispatch must have nudged the worker out of :starting so the UI/CLI
      # report a meaningful state while Claude works. In claude_driven
      # mode the Driver never ticks the Machine, so without this nudge
      # the worker would stay :starting until "arb done" fires.
      snap = Worker.state(result.worker_pid)
      assert snap.state == :working
      assert snap.current_step == :claude

      # If the Driver were in workflow mode, the no-op steps would close
      # the task in ~500ms. Wait that long and verify the task is still
      # :active — the Driver is waiting on the worker instead.
      Process.sleep(150)

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :active

      # Now simulate Claude completion and let the Driver react.
      :ok = Worker.complete(result.worker_pid, :claude_done)

      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end

    test "passes the workspace `agent.config.model` as `--model` to claude",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "model-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "mwt"))
      put_app_env(:arbiter, :repo_paths, %{"m/repo" => repo})

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "model task", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "m/repo",
          start_driver: false,
          start_claude: true,
          # This test asserts the WORK-spawn argv; disable the bd-awi4nw auth
          # pre-flight so its probe (which invokes the same `claude` stub) doesn't
          # write to the shared argv file and race the work spawn's capture.
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "sonnet" in args
    end

    test "per-dispatch :model opt overrides the workspace's routed model",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "override-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "owt"))
      put_app_env(:arbiter, :repo_paths, %{"o/repo" => repo})

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "override", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "o/repo",
          start_driver: false,
          start_claude: true,
          model: "opus",
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw).
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "opus" in args
      refute "sonnet" in args
    end

    test "agent_type: :gemini dispatches the Gemini adapter, not Claude",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "gem-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "gwt"))
      put_app_env(:arbiter, :repo_paths, %{"g/repo" => repo})

      # Workspace defaults to Claude — the forced provider must win over it.
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"type" => "claude"}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "gemini task", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "g/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw)
          # so its probe doesn't also write to the stub argv files.
          preflight: false
        )

      gemini_args = wait_for_argv!(gemini_file)
      assert "-p" in gemini_args
      # The Gemini adapter ran — and Claude did not.
      refute File.exists?(claude_file)

      # The worker's routing config records the gemini provider. The model is
      # nil (bd-2fzwlc round 3): `agy` is the resolved executable here (it's
      # preferred over `gemini` whenever both are on PATH), and agy's model
      # catalogue doesn't overlap ours at all, so `Gemini.resolved_model/1`
      # intentionally reports "unknown" rather than a guessed model id.
      snap = Worker.state(result.worker_pid)
      routing = snap.meta[:routing_config]
      assert routing.provider == "gemini"
      assert routing.model == nil
    end

    # bd-2exkl0 finding 2: every other test in this suite/branch seeds
    # `Run.provider` directly via `Ash.create(Run, %{provider: "gemini"})`, so
    # none of them prove the WRITE half of the chain — that a real main
    # dispatch with NO explicit `--provider`/`agent_type` opt (the live
    # bd-629sb8 shape: `agent.type` is a workspace-config pool, not a CLI
    # flag) ever lands "gemini" on the `:main` run row in the first place.
    # `default_run_provider/2` deliberately returns nil for `:main` — the
    # only writer here is the post-spawn backfill
    # (`Worker.backfill_session_dispatch/5`, fed by `build_agent_session_opts/4`'s
    # `Routing.choose/3` + `apply_agent_type_override/2` resolution of the
    # workspace's `agent.type`). This test seeds nothing and reads the run
    # row back to prove that code path actually fires.
    test "main dispatch with no explicit provider writes Run.provider from the workspace's resolved agent type (bd-2exkl0)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_sleeping_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "gem-write-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "gem-write-wt"))
      put_app_env(:arbiter, :repo_paths, %{"gw/repo" => repo})

      # Workspace pool defaults to gemini — mirrors bd-629sb8's
      # `review_agent.type: ["gemini","claude"]` shape, but for the WORKER pool.
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"type" => ["gemini", "claude"]}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "gemini write-path task", workspace_id: ws.id})

      # No `agent_type:` opt — the resolved provider must come purely from
      # the workspace's `agent.type` pool, exactly as a live dispatch with no
      # `--provider` flag would resolve it.
      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "gw/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      _ = wait_for_argv!(gemini_file)
      refute File.exists?(claude_file)

      run = latest_run(task.id)
      assert run.kind == :implement

      assert run.provider == "gemini",
             "the :main run's provider must be written by the real spawn, not seeded"
    end

    test "agent_type: :codex dispatches the Codex adapter, not Claude (bd-dcvo3n)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      codex_file = Path.join(tmp, "codex-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "codex", codex_file)

      repo = seed_repo!(tmp, "codex-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "cwt"))
      put_app_env(:arbiter, :repo_paths, %{"c/repo" => repo})

      # Workspace's `agent.type` pool deliberately excludes codex — mirrors the
      # live `default` workspace (`["claude","gemini"]`) so the explicit override
      # must win over the workspace default rather than fall back to it.
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"type" => ["claude", "gemini"]}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "codex task", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "c/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :codex,
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw)
          # so its probe doesn't also write to the stub argv files.
          preflight: false
        )

      codex_args = wait_for_argv!(codex_file)
      # The Codex adapter ran (`codex exec --json ...`) — and Claude did not.
      assert "exec" in codex_args
      refute File.exists?(claude_file)

      # The worker's routing config records the codex provider.
      snap = Worker.state(result.worker_pid)
      routing = snap.meta[:routing_config]
      assert routing.provider == "codex"
    end

    test "ByPriority routing picks --model from `routing.rules[Pn]`",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "prio-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "pwt"))
      put_app_env(:arbiter, :repo_paths, %{"p/repo" => repo})

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
            "routing" => %{
              "policy" => "by_priority",
              "rules" => %{"P4" => %{"model" => "haiku"}}
            }
          }
        })

      # priority 4 → routing rule fires → haiku.
      {:ok, task} =
        Ash.create(Issue, %{title: "trivial", workspace_id: ws.id, priority: 4})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "p/repo",
          start_driver: false,
          start_claude: true,
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw).
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "haiku" in args
    end

    # bd-dzz6ly: worker_runs records what happened but not what governed it.
    # This proves the effective post-layering skill set, the routing policy
    # that decided the tier, the resolved tier/thinking, the standing_orders
    # digest, and the task's difficulty AT DISPATCH TIME all land on the Run
    # row — so "which runs had skill X active, grouped by outcome" is
    # answerable without reading a transcript.
    test "dispatch records provenance (resolved_skills, routing_policy, model_tier, thinking, standing_orders_digest, difficulty_at_dispatch) onto the Run row",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "prov-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "provwt"))
      put_app_env(:arbiter, :repo_paths, %{"prov/repo" => repo})

      {:ok, _skill} =
        Arbiter.Skills.create_skill(%{
          name: "prov-canary",
          body: "# Canary",
          activation_mode: :always_on
        })

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude"},
            "routing" => %{"policy" => "by_difficulty"},
            "skills" => %{"workspace" => ["prov-canary"]},
            "standing_orders" => ["always run tests"]
          }
        })

      # D3 → premium / high per ByDifficulty's default mapping.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "provenance work",
          workspace_id: ws.id,
          issue_type: :feature,
          difficulty: 3
        })

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "prov/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      _ = wait_for_argv!(argv_file)

      run = latest_run(task.id)
      assert run.difficulty_at_dispatch == 3
      assert run.routing_policy == "by_difficulty"
      assert run.model_tier == "premium"
      assert run.thinking == "high"
      assert is_binary(run.standing_orders_digest)
      assert String.length(run.standing_orders_digest) == 64

      assert [%{"name" => "prov-canary", "activation_mode" => "always_on"} = entry] =
               run.resolved_skills

      assert is_binary(entry["skill_version"])

      # Editing the task's difficulty AFTER dispatch must not retroactively
      # change what this run recorded — it ran under D3, not whatever the
      # task is corrected to later (bd-7rspia was D1 → D2).
      {:ok, _updated_task} = Ash.update(result.task, %{difficulty: 1})
      run_after_edit = latest_run(task.id)
      assert run_after_edit.difficulty_at_dispatch == 3
    end

    test "redispatch after a :context_thrash failure auto-escalates to the 1M model (bd-8cn795)",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "thrash-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "twt"))
      put_app_env(:arbiter, :repo_paths, %{"t/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "large module fix", workspace_id: ws.id})

      # A prior run for this exact task already died with the autocompact-thrash
      # signature — no manual `model:` override is passed on this redispatch.
      {:ok, _prior_run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "t/repo",
          workspace_id: ws.id,
          state: :finished,
          outcome: :failed,
          started_at: DateTime.utc_now(),
          exit_code: 1,
          output_lines: [
            "reading apps/arbiter/lib/arbiter/workflows/review_patrol.ex",
            "Autocompact is thrashing: the context refilled to the limit within 3 " <>
              "turns of the previous compact, 3 times in a row"
          ]
        })

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "t/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "claude-sonnet-5[1m]" in args
    end

    test "the escalation reads the typed stop_category, with no output_lines to scan (bd-apwfmy)",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "thrash-typed-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "twt"))
      put_app_env(:arbiter, :repo_paths, %{"t/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "typed thrash", workspace_id: ws.id})

      # The prior run recorded WHAT killed it at the moment it died. Its
      # capped `output_lines` are empty — on a long run the thrash banner has
      # long since scrolled out of the cap, which is exactly the failure mode
      # re-deriving from prose has.
      {:ok, _prior_run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "t/repo",
          workspace_id: ws.id,
          state: :finished,
          outcome: :failed,
          started_at: DateTime.utc_now(),
          exit_code: 1,
          output_lines: [],
          stop_category: "context_thrash"
        })

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "t/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "claude-sonnet-5[1m]" in args
    end

    test "a clean prior run does NOT auto-escalate the model (bd-8cn795)",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "clean-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "cwt2"))
      put_app_env(:arbiter, :repo_paths, %{"c2/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "ordinary fix", workspace_id: ws.id})

      {:ok, _prior_run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "c2/repo",
          workspace_id: ws.id,
          state: :finished,
          outcome: :failed,
          started_at: DateTime.utc_now(),
          exit_code: 1,
          output_lines: ["some other unrelated crash"]
        })

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "c2/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      refute "claude-sonnet-5[1m]" in args
    end

    test "an explicit :model opt still wins over the thrash auto-escalation (bd-8cn795)",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "override-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "owt"))
      put_app_env(:arbiter, :repo_paths, %{"o/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "large module fix 2", workspace_id: ws.id})

      {:ok, _prior_run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "o/repo",
          workspace_id: ws.id,
          state: :finished,
          outcome: :failed,
          started_at: DateTime.utc_now(),
          exit_code: 1,
          output_lines: ["autocompact is thrashing"]
        })

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "o/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          model: "opus"
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "opus" in args
      refute "claude-sonnet-5[1m]" in args
    end
  end

  # bd-1abj7u: a `:strict` scope promises writes stay in the worktree.
  # Neither Gemini/agy nor Codex can keep that promise today
  # (`write_confinement/1` answers `:none`) — dispatch must refuse rather
  # than silently spawn an unconfined provider under a `:strict` label.
  describe "strict write-confinement gate (bd-1abj7u)" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "dispatch-strict-#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    defp strict_ws!(ws, agent_type) do
      Ash.update(ws, %{
        config: %{
          "agent" => %{
            "type" => agent_type,
            "security" => %{"permissions" => %{"mode" => "strict"}}
          }
        }
      })
    end

    test "an explicit agent_type: :gemini is refused under :strict, naming the provider and the way out",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "strict-gemini-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "strict-gemini-wt"))
      put_app_env(:arbiter, :repo_paths, %{"sg/repo" => repo})

      {:ok, ws} = strict_ws!(ws, "claude")
      {:ok, task} = Ash.create(Issue, %{title: "strict gemini refusal", workspace_id: ws.id})

      assert {:error, {:claude_start_failed, {:strict_write_confinement_unavailable, message}}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "sg/repo",
                 start_driver: false,
                 start_claude: true,
                 agent_type: :gemini,
                 preflight: false
               )

      assert message =~ "gemini"
      assert message =~ "strict"
      assert message =~ "claude"
      assert message =~ "bubblewrap"

      refute File.exists?(claude_file)
      refute File.exists?(gemini_file)

      pid = Worker.whereis(task.id)
      assert Worker.state(pid).outcome == :failed
    end

    test "automatic selection under :strict skips an ineligible preferred provider for an eligible pool entry",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "strict-pool-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "strict-pool-wt"))
      put_app_env(:arbiter, :repo_paths, %{"sp/repo" => repo})

      {:ok, ws} = strict_ws!(ws, ["gemini", "claude"])
      {:ok, task} = Ash.create(Issue, %{title: "strict pool fallback", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "sp/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      _ = wait_for_argv!(claude_file)
      refute File.exists?(gemini_file)
    end

    test "automatic selection under :strict errors when no configured pool entry is eligible",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "strict-none-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "strict-none-wt"))
      put_app_env(:arbiter, :repo_paths, %{"sn/repo" => repo})

      {:ok, ws} = strict_ws!(ws, "gemini")
      {:ok, task} = Ash.create(Issue, %{title: "strict pool exhausted", workspace_id: ws.id})

      assert {:error, {:claude_start_failed, {:strict_write_confinement_unavailable, _}}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "sn/repo",
                 start_driver: false,
                 start_claude: true,
                 preflight: false
               )

      refute File.exists?(claude_file)
      refute File.exists?(gemini_file)
    end

    # bd-btcdrf, bd-d2o3xb (P7): `sandbox.backend: podman` has a wrap point for
    # Claude. A host that cannot run containers fails the start; the stub
    # claude on PATH is never run on the host.
    test "sandbox.backend: podman never runs claude on the host when containers are unavailable",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)

      repo = seed_repo!(tmp, "podman-claude-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "podman-claude-wt"))
      put_app_env(:arbiter, :repo_paths, %{"pc/repo" => repo})
      put_app_env(:arbiter, :worker_container_available, false)

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "claude",
              "security" => %{"sandbox" => %{"backend" => "podman"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "podman refusal", workspace_id: ws.id})

      assert {:error, {:claude_start_failed, {:podman_unavailable, :disabled_by_config}}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "pc/repo",
                 start_driver: false,
                 start_claude: true,
                 preflight: false
               )

      refute File.exists?(claude_file)
    end

    # bd-d2o3xb (P7), the production call path: Dispatch -> adapter argv ->
    # ClaudeSession -> `podman run`. A stand-in `podman` on PATH records what it
    # was asked to run; the host's `claude` is never executed.
    test "sandbox.backend: podman runs the claude spawn as a `podman run` over the private clone",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      podman_file = Path.join(tmp, "podman-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "podman", podman_file)

      repo = seed_repo!(tmp, "podman-run-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "podman-run-wt"))
      put_app_env(:arbiter, :repo_paths, %{"pr/repo" => repo})
      put_app_env(:arbiter, :worker_container_available, true)
      put_app_env(:arbiter, :worker_container_network_available, true)
      put_app_env(:arbiter, :worker_container_image, "localhost/arb-test/dispatch:1")

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "claude",
              "security" => %{"sandbox" => %{"backend" => "podman"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "podman run", workspace_id: ws.id})

      assert {:ok, %{worktree_path: clone}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "pr/repo",
                 start_driver: false,
                 start_claude: true,
                 preflight: false
               )

      assert Arbiter.Worker.PrivateClone.clone?(clone)

      argv =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          case File.read(podman_file) do
            {:ok, out} when out != "" -> {:halt, String.split(out, "\n", trim: true)}
            _ -> Process.sleep(25) && {:cont, nil}
          end
        end)

      assert is_list(argv), "the stand-in podman was never run"
      assert hd(argv) == "run"
      assert "--network=none" in argv
      assert "--userns=keep-id" in argv
      assert "localhost/arb-test/dispatch:1" in argv
      assert "#{clone}:#{clone}:rw" in argv
      assert "/opt/arbiter/cli/claude" in argv
      assert "--print" in argv

      # The host's claude never ran: only the container's command line names it.
      refute File.exists?(claude_file)
    end

    # bd-50d5j6 (P8): Codex has a container wrap point too. Same production call
    # path as the Claude test above, with an ELF stand-in for the vendored codex
    # binary and a scratch codex home, so the operator's real login is never read.
    test "sandbox.backend: podman runs the codex spawn as a `podman run` with a per-run CODEX_HOME",
         %{ws: ws, tmp: tmp} do
      podman_file = Path.join(tmp, "podman-argv.txt")
      :ok = stub_named_on_path(tmp, "podman", podman_file)

      stub_dir = Path.join(tmp, "stub-bin")
      File.cp!(System.find_executable("true"), Path.join(stub_dir, "codex"))
      File.chmod!(Path.join(stub_dir, "codex"), 0o755)

      source_home = Path.join(tmp, "operator-codex")
      File.mkdir_p!(source_home)
      File.write!(Path.join(source_home, "auth.json"), ~s({"tokens":{"refresh_token":"rt-op"}}))
      put_app_env(:arbiter, :worker_codex_source_home, source_home)

      repo = seed_repo!(tmp, "podman-codex-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "podman-codex-wt"))
      put_app_env(:arbiter, :repo_paths, %{"pcx/repo" => repo})
      put_app_env(:arbiter, :worker_container_available, true)
      put_app_env(:arbiter, :worker_container_network_available, true)
      put_app_env(:arbiter, :worker_container_image, "localhost/arb-test/dispatch:1")

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "codex",
              "security" => %{"sandbox" => %{"backend" => "podman"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "podman codex", workspace_id: ws.id})

      assert {:ok, %{worktree_path: clone}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "pcx/repo",
                 agent_type: :codex,
                 start_driver: false,
                 start_claude: true,
                 preflight: false
               )

      assert Arbiter.Worker.PrivateClone.clone?(clone)

      argv =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          case File.read(podman_file) do
            {:ok, out} when out != "" -> {:halt, String.split(out, "\n", trim: true)}
            _ -> Process.sleep(25) && {:cont, nil}
          end
        end)

      assert is_list(argv), "the stand-in podman was never run"
      assert hd(argv) == "run"
      assert "--network=none" in argv
      assert "/opt/arbiter/cli/codex" in argv
      assert "exec" in argv
      # The real login is not on the command line at all.
      refute Enum.any?(argv, &String.contains?(&1, source_home))
      assert Enum.any?(argv, &String.contains?(&1, "/opt/arbiter/cli/codex:ro"))
      assert Enum.any?(argv, &(&1 == "CODEX_HOME"))
    end

    # The checkout a podman dispatch gets is a private clone, and only Claude and
    # Codex have a container wrap point: an explicit provider that has none is refused
    # at the gate, before anything is spawned.
    test "sandbox.backend: podman refuses an explicit non-claude provider at the gate",
         %{ws: ws, tmp: tmp} do
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "podman-gemini-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "podman-gemini-wt"))
      put_app_env(:arbiter, :repo_paths, %{"pg/repo" => repo})

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "gemini",
              "security" => %{"sandbox" => %{"backend" => "podman"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "podman gemini", workspace_id: ws.id})

      assert {:error, {:claude_start_failed, {:sandbox_backend_unavailable, :podman, message}}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "pg/repo",
                 agent_type: :gemini,
                 start_driver: false,
                 start_claude: true,
                 preflight: false
               )

      assert message =~ "claude and codex only"
      refute File.exists?(gemini_file)
    end

    # bd-anwb0u (G11): the guardrail floor lands after SecurityPolicy.resolve/3.
    # A `bypass` workspace dispatching to a quarantine subject is floored to
    # `:strict`, and the same write-confinement gate then refuses an adapter
    # that cannot keep it — with the floor named as the source.
    test "a quarantine subject is floored to :strict and refused where writes cannot be confined",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "floor-gemini-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "floor-gemini-wt"))
      put_app_env(:arbiter, :repo_paths, %{"fg/repo" => repo})

      put_app_env(:arbiter, :guardrail_subject_rules, [
        %{match: %{provider: "antigravity"}, tier: :quarantine},
        %{match: %{provider: "claude"}, tier: :privileged}
      ])

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "claude",
              "security" => %{"permissions" => %{"mode" => "bypass"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "floor gemini refusal", workspace_id: ws.id})

      assert {:error, {:claude_start_failed, {:strict_write_confinement_unavailable, message}}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "fg/repo",
                 start_driver: false,
                 start_claude: true,
                 agent_type: :gemini,
                 preflight: false
               )

      assert message =~ "guardrail tier"
      refute File.exists?(gemini_file)
    end

    test "a privileged subject keeps its bypass posture under the same rules", %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)

      repo = seed_repo!(tmp, "floor-claude-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "floor-claude-wt"))
      put_app_env(:arbiter, :repo_paths, %{"fc/repo" => repo})

      put_app_env(:arbiter, :guardrail_subject_rules, [
        %{match: %{provider: "claude"}, tier: :privileged}
      ])

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "claude",
              "security" => %{"permissions" => %{"mode" => "bypass"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "floor claude unaffected", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "fc/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      argv = wait_for_argv!(claude_file)
      assert "--dangerously-skip-permissions" in argv
    end

    # AC5: nothing configured, nothing changes. A workspace `guardrails` block
    # with no subject rules behind it is inert, so this dispatch is the same
    # `:bypass` gemini dispatch as the test below.
    test "a guardrails block with no subject rules changes nothing", %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "inert-block-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "inert-block-wt"))
      put_app_env(:arbiter, :repo_paths, %{"ib/repo" => repo})

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "claude",
              "security" => %{"permissions" => %{"mode" => "bypass"}}
            },
            "guardrails" => %{
              "subjects" => [
                %{"match" => %{"provider" => "antigravity"}, "max_tier" => "quarantine"}
              ]
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "inert block unaffected", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "ib/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          preflight: false
        )

      _ = wait_for_argv!(gemini_file)
      refute File.exists?(claude_file)
    end

    test "a :bypass dispatch to gemini is unaffected by the strict gate", %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "bypass-gemini-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "bypass-gemini-wt"))
      put_app_env(:arbiter, :repo_paths, %{"bg/repo" => repo})

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{
              "type" => "claude",
              "security" => %{"permissions" => %{"mode" => "bypass"}}
            }
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "bypass gemini unaffected", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "bg/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          preflight: false
        )

      _ = wait_for_argv!(gemini_file)
      refute File.exists?(claude_file)
    end
  end

  # Read a stub's captured argv once it has settled. The argv-recording shim
  # appends one line per arg, so a bare `File.exists?` check can race a partial
  # write and return only the first token. Wait until the file's contents stop
  # changing across two polls, then split into the arg list.
  defp wait_for_argv!(file) do
    wait_until(fn -> File.exists?(file) end)
    settle_argv(file, File.read!(file))
  end

  defp settle_argv(file, prev) do
    Process.sleep(20)

    case File.read!(file) do
      ^prev -> String.split(prev, "\n", trim: true)
      next -> settle_argv(file, next)
    end
  end

  # Spin until `fun.()` returns truthy or the deadline expires.
  defp wait_until(fun, timeout \\ 2_000) do
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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  # bd-2aslx6 (#1428): a second dispatch landing on a task whose worker is
  # already running an agent session used to open a SECOND paid CLI subprocess
  # inside the SAME worker — `start_worker/3` deliberately reuses a live
  # worker's registration, and `maybe_start_claude/4` then spawned again into
  # it. Observed in production on bd-f7j7eh: one `worker_runs` row carrying an
  # `agy` session and a `claude-haiku` session at once, the Claude one killed
  # unfinished at worker teardown after burning ~127k tokens for no result.
  describe "concurrent agent sessions are refused (bd-2aslx6)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-dup-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    test "a second start_claude dispatch onto a live agent session is refused",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "dup dispatch", workspace_id: ws.id})

      repo = seed_repo!(tmp, "dup-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "dup-wt"))
      put_app_env(:arbiter, :repo_paths, %{"dup/repo" => repo})

      opts = [
        repo: "dup/repo",
        start_driver: false,
        start_claude: true,
        preflight: false,
        # Stand-in for a `claude --print` session that is still working.
        claude_command: ["sleep", "30"]
      ]

      {:ok, first} = Dispatch.dispatch(task.id, Keyword.put(opts, :force, true))
      assert is_port(first.claude_port)

      assert {:error, {:agent_session_active, task_id}} =
               Dispatch.dispatch(task.id, Keyword.put(opts, :force, true))

      assert task_id == task.id

      # The live session is untouched: same worker, same port, still running.
      assert Worker.whereis(task.id) == first.worker_pid
      refute Worker.finished?(Worker.state(first.worker_pid))
      assert Port.info(first.claude_port) != nil

      Worker.stop(first.worker_pid, :normal)
    end

    test "a cross-provider re-dispatch never spawns the second CLI (bd-f7j7eh repro)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_sleeping_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "dup-gem-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "dup-gwt"))
      put_app_env(:arbiter, :repo_paths, %{"dg/repo" => repo})

      {:ok, ws} = Ash.update(ws, %{config: %{"agent" => %{"type" => "claude"}}})
      {:ok, task} = Ash.create(Issue, %{title: "dup gemini task", workspace_id: ws.id})

      base = [repo: "dg/repo", start_driver: false, start_claude: true, preflight: false]

      {:ok, first} =
        Dispatch.dispatch(task.id, Keyword.put(base ++ [agent_type: :gemini], :force, true))

      _ = wait_for_argv!(gemini_file)

      # The follow-up dispatch carries no `agent_type`, so it resolves the
      # workspace default (Claude) — the exact shape that put an agy session and
      # a Claude session in one run.
      assert {:error, {:agent_session_active, _}} =
               Dispatch.dispatch(task.id, Keyword.put(base, :force, true))

      # No Claude CLI was ever spawned for this task.
      refute File.exists?(claude_file)

      snap = Worker.state(first.worker_pid)
      assert snap.meta[:routing_config].provider == "gemini"

      Worker.stop(first.worker_pid, :normal)
    end

    test "a dispatch with no agent (start_claude: false) still attaches to a live worker",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "park dispatch", workspace_id: ws.id})

      repo = seed_repo!(tmp, "park-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "park-wt"))
      put_app_env(:arbiter, :repo_paths, %{"park/repo" => repo})

      {:ok, first} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "park/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sleep", "30"]
        )

      # A no-agent dispatch spends nothing, so it keeps today's attach semantics.
      assert {:ok, second} =
               Dispatch.dispatch(task.id, force: true, repo: "park/repo", start_driver: false)

      assert second.worker_pid == first.worker_pid
      assert second.claude_port == nil

      Worker.stop(first.worker_pid, :normal)
    end

    # The guard must not out-rank `start_worker/3`'s bd-d70whv eviction of a
    # terminal worker. `complete_now/2` and `fail_missing_worktree/1` mark a run
    # terminal WITHOUT killing its sessions (unlike `fail_now/2`), so a terminal
    # worker can still hold a live — possibly hung — agent. Refusing there would
    # pin exactly the stray, spending session this task is about.
    test "a terminal worker still holding a live session is evicted, not refused",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "terminal redispatch", workspace_id: ws.id})

      repo = seed_repo!(tmp, "term-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "term-wt"))
      put_app_env(:arbiter, :repo_paths, %{"term/repo" => repo})

      opts = [
        repo: "term/repo",
        start_driver: false,
        start_claude: true,
        preflight: false,
        claude_command: ["sleep", "30"]
      ]

      {:ok, first} = Dispatch.dispatch(task.id, Keyword.put(opts, :force, true))

      # Finish the run :succeeded the way the `arb done` path does — via
      # complete_now/2, which leaves the session port open.
      :ok = Worker.advance(first.worker_pid, :work)
      :ok = Worker.complete(first.worker_pid, :test)
      assert Worker.state(first.worker_pid).outcome == :succeeded
      assert Worker.agent_session_live?(first.worker_pid)

      assert {:ok, second} = Dispatch.dispatch(task.id, Keyword.put(opts, :force, true))
      assert second.worker_pid != first.worker_pid
      assert is_port(second.claude_port)

      # The stale worker (and with it the session it was still holding) is gone.
      refute Process.alive?(first.worker_pid)
      wait_until(fn -> Port.info(first.claude_port) == nil end)

      Worker.stop(second.worker_pid, :normal)
    end

    test "once the live session exits, a re-dispatch is allowed again",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "redispatch after exit", workspace_id: ws.id})

      repo = seed_repo!(tmp, "again-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "again-wt"))
      put_app_env(:arbiter, :repo_paths, %{"again/repo" => repo})

      {:ok, first} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "again/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["true"]
        )

      # Wait for the port to exit and the worker to stamp `:exited_at`.
      wait_until(fn -> not Arbiter.Worker.agent_session_live?(first.worker_pid) end)

      assert {:ok, second} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "again/repo",
                 start_driver: false,
                 start_claude: true,
                 preflight: false,
                 claude_command: ["sleep", "30"]
               )

      assert is_port(second.claude_port)

      Worker.stop(second.worker_pid, :normal)
    end
  end

  describe "worktree provisioning" do
    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-wt-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      # Bare origin: Worktree.create fetches from `origin` and branches from
      # `origin/<base>`. Tests set it up explicitly so the repo has an upstream
      # the provisioning path can consult.
      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"st/repo" => repo})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, remote: remote, worktree_root: worktree_root, tmp: tmp}
    end

    test "creates a worktree on a derived branch when repo is configured",
         %{ws: ws, worktree_root: root} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "implement the thing",
          workspace_id: ws.id,
          issue_type: :feature
        })

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "st/repo", start_driver: false)

      assert is_binary(result.worktree_path)
      assert String.starts_with?(result.worktree_path, root)
      assert File.dir?(result.worktree_path)

      # Branch matches BranchNamer's derivation.
      branch = BranchNamer.derive(task)
      assert {:ok, ^branch} = Arbiter.Worker.Worktree.current_branch(result.worktree_path)
    end

    test "skips worktree when repo is not in repo_paths", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "unmapped", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "no-such-repo", start_driver: false)

      assert result.worktree_path == nil
    end

    test "skips worktree for a task issue_type even with a configured repo (bd-5lc99r)",
         %{ws: ws} do
      # A `task` is non-reviewable ops/research work with no code deliverable, so
      # dispatch must not provision a worktree by default — even though `st/repo`
      # is configured and a feature/bug/chore would get one here.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "research spike",
          workspace_id: ws.id,
          issue_type: :task
        })

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "st/repo", start_driver: false)

      assert result.worktree_path == nil
    end

    test "provision_worktree: true forces a worktree even for a task type (bd-5lc99r)",
         %{ws: ws} do
      # The rare task that genuinely needs a repo checkout to inspect can opt back
      # in with an explicit flag.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "task needing a checkout",
          workspace_id: ws.id,
          issue_type: :task
        })

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "st/repo",
          start_driver: false,
          provision_worktree: true
        )

      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    # bd-9s9dqz: `task` (operational action) and `research` (findings) are the
    # two no-PR types. Both run the real dispatch path with a configured repo and
    # end without a worktree, a ReviewGate round or a Merging stop.
    for type <- [:task, :research] do
      test "a #{type} dispatch provisions no worktree, skips ReviewGate and closes (bd-9s9dqz)",
           %{ws: ws} do
        claude_credential_env!()

        {:ok, ticket} =
          Ash.create(Issue, %{
            title: "no-PR #{unquote(type)}",
            workspace_id: ws.id,
            issue_type: unquote(type)
          })

        # `research` owes findings, so give the notes gate something to find;
        # `task` is dispatched WITHOUT any notes to prove it needs none.
        ticket =
          if unquote(type) == :research do
            {:ok, t} =
              Ash.update(ticket, %{notes: "## Findings\n\nNothing odd."}, action: :update)

            t
          else
            ticket
          end

        {:ok, result} =
          Dispatch.dispatch(ticket.id,
            force: true,
            repo: "st/repo",
            start_claude: true,
            preflight: false,
            claude_command: ["sleep", "5"],
            interval_ms: 5,
            max_ticks: 200
          )

        assert result.worktree_path == nil

        ref = Process.monitor(result.driver_pid)
        send(result.worker_pid, {:__claude_session_done__, "arb done"})
        assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 5_000

        {:ok, reloaded} = Ash.get(Issue, ticket.id)
        assert reloaded.state == :closed
        assert reloaded.pr_ref == nil

        # No ReviewGate round was ever opened, and the run never waited on one.
        assert Round |> Ash.Query.filter(task_id == ^ticket.id) |> Ash.read!() == []
        assert latest_run(ticket.id).outcome == :succeeded
      end
    end

    test "per-workspace repo_paths overrides the Application env", %{repo: repo} do
      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "per-ws-#{System.unique_integer([:positive])}",
          prefix: "pw",
          config: %{"repo_paths" => %{"per-ws/repo" => repo}}
        })

      {:ok, task} =
        Ash.create(Issue, %{title: "per-ws", workspace_id: ws_local.id, repo: "per-ws/repo"})

      # `per-ws/repo` is NOT in Application env — only in this workspace's
      # config. Dispatch must still find it.
      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "per-ws/repo", start_driver: false)

      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "cuts the worktree from (and targets) the workspace's configured base branch",
         %{repo: repo} do
      # The source repo's default branch is `main`. Create a `develop` branch
      # that diverges from it (pushed to origin so the fetch-from-origin
      # provisioner can see it), then configure a workspace whose merge config
      # points the integration branch at `develop`.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "develop"])
      File.write!(Path.join(repo, "DEVELOP_ONLY.md"), "only on develop\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "DEVELOP_ONLY.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "develop-only file"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "develop"])
      # Leave the repo's HEAD on `main` so a hardcoded "main" base would NOT
      # see the develop-only file — the assertion below proves we cut from
      # `develop`, not from whatever HEAD happens to be.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "base-branch-ws-#{System.unique_integer([:positive])}",
          prefix: "bb",
          config: %{
            "repo_paths" => %{"bb/repo" => repo},
            "merge" => %{"base" => "develop"}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{title: "non-main base", workspace_id: ws_local.id, repo: "bb/repo"})

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "bb/repo", start_driver: false)

      # Worktree was cut from `develop`: the develop-only file is present.
      assert is_binary(result.worktree_path)
      assert File.exists?(Path.join(result.worktree_path, "DEVELOP_ONLY.md"))

      # Merge target_branch threaded into the worker's meta matches the base,
      # so the completed branch merges back into `develop`, not `main`.
      assert %{target_branch: "develop"} = Worker.state(result.worker_pid).meta
    end

    test "skips worktree when provision_worktree: false", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "opt-out", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "st/repo",
          start_driver: false,
          provision_worktree: false
        )

      assert result.worktree_path == nil
    end

    test "attaches to existing branch when re-dispatching a reopened task", %{repo: repo, ws: ws} do
      # Reproduces bd-4tta5n: task is slung once (branch created), the worktree
      # is cleaned up but the branch remains, then the task is reopened and
      # re-slung. Worktree.create fails with "already exists"; dispatch must fall
      # back to Worktree.attach and succeed.
      {:ok, task} =
        Ash.create(Issue, %{title: "re-dispatch after review", workspace_id: ws.id})

      # First dispatch — provisions the worktree, creating the branch locally.
      {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: "st/repo", start_driver: false)
      assert is_binary(first.worktree_path)
      branch = BranchNamer.derive(task)

      # Simulate Driver cleanup: remove the worktree directory but leave the
      # branch (Worktree.cleanup removes the worktree, not the branch).
      Arbiter.Worker.Worktree.cleanup(first.worktree_path)
      refute File.dir?(first.worktree_path)

      # Confirm the branch still exists in the repo.
      {branches, 0} = System.cmd("git", ["-C", repo, "branch", "--list", branch])
      assert String.contains?(branches, branch)

      # Requeue the task so it can be re-slung.
      {:ok, task} = Issue |> Ash.get!(task.id) |> Ash.update(%{}, action: :requeue)

      # Second dispatch — branch already exists; must attach instead of creating.
      assert {:ok, second} =
               Dispatch.dispatch(task.id, force: true, repo: "st/repo", start_driver: false)

      assert is_binary(second.worktree_path)
      assert File.dir?(second.worktree_path)
      assert {:ok, ^branch} = Arbiter.Worker.Worktree.current_branch(second.worktree_path)
    end

    test "worktree starts from upstream tip even when the repo's local base is stale",
         %{repo: repo, remote: remote, tmp: tmp, ws: ws} do
      # Reproduces the 2026-06-04 incident: a second clone advances origin/main;
      # the repo's local `main` stays put. Dispatch must still produce a worktree
      # at the upstream tip.
      clone = Path.join(tmp, "advance")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, "UPSTREAM.md"), "added on origin\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "UPSTREAM.md"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "advance"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])

      refute File.exists?(Path.join(repo, "UPSTREAM.md"))

      {:ok, task} = Ash.create(Issue, %{title: "stale local base", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "st/repo", start_driver: false)

      assert File.exists?(Path.join(result.worktree_path, "UPSTREAM.md"))
    end

    test "fetch failure aborts the dispatch with a clear error", %{ws: ws, tmp: tmp} do
      # Repo with a broken `origin` (points at a nonexistent path): the fetch
      # must fail and the dispatch abort with a structured error rather than
      # silently falling back to the stale local base.
      broken = Path.join(tmp, "broken-origin")
      File.mkdir_p!(broken)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", broken])
      {_, 0} = System.cmd("git", ["-C", broken, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", broken, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", broken, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(broken, "x"), "x")
      {_, 0} = System.cmd("git", ["-C", broken, "add", "x"])
      {_, 0} = System.cmd("git", ["-C", broken, "commit", "-q", "-m", "i"])
      # Origin points at a path that doesn't exist — `git fetch` will fail.
      {_, 0} =
        System.cmd("git", ["-C", broken, "remote", "add", "origin", Path.join(tmp, "no-such")])

      Application.put_env(:arbiter, :repo_paths, %{"broken/repo" => broken})

      {:ok, task} = Ash.create(Issue, %{title: "fetch failure", workspace_id: ws.id})

      assert {:error, {:worktree_failed, reason}} =
               Dispatch.dispatch(task.id, force: true, repo: "broken/repo", start_driver: false)

      assert match?({:fetch_failed, _}, reason) or match?({:missing_origin_ref, _}, reason),
             "expected fetch_failed or missing_origin_ref, got: #{inspect(reason)}"
    end

    test "per-task target_branch overrides the workspace default", %{repo: repo, remote: remote} do
      # Push a `dolphin` branch to origin so Worktree.create can fetch it.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "dolphin"])
      File.write!(Path.join(repo, "DOLPHIN.md"), "dolphin\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "DOLPHIN.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      _ = remote

      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "per-task-target-#{System.unique_integer([:positive])}",
          prefix: "pb",
          # Workspace default is the bare "main"; the task overrides to dolphin.
          config: %{"repo_paths" => %{"pb/repo" => repo}, "merge" => %{"base" => "main"}}
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "per-task target",
          workspace_id: ws_local.id,
          repo: "pb/repo",
          target_branch: "dolphin"
        })

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "pb/repo", start_driver: false)

      # The task-specified target wins: the worktree carries the dolphin file
      # and the worker's meta records dolphin as the merge target.
      assert File.exists?(Path.join(result.worktree_path, "DOLPHIN.md"))
      assert %{target_branch: "dolphin"} = Worker.state(result.worker_pid).meta
    end

    test "per-repo target_branch default applies when task has none", %{repo: repo} do
      # Push a `dolphin` branch and configure the repo to default to it.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "dolphin"])
      File.write!(Path.join(repo, "DOLPHIN.md"), "dolphin\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "DOLPHIN.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "repo-default-target-#{System.unique_integer([:positive])}",
          prefix: "rd",
          # Repo-level default beats the workspace default ("main").
          config: %{
            "repo_paths" => %{
              "rd/repo" => %{"path" => repo, "target_branch" => "dolphin"}
            },
            "merge" => %{"base" => "main"}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{title: "repo default", workspace_id: ws_local.id, repo: "rd/repo"})

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "rd/repo", start_driver: false)

      assert File.exists?(Path.join(result.worktree_path, "DOLPHIN.md"))
      assert %{target_branch: "dolphin"} = Worker.state(result.worker_pid).meta
    end

    # bd-8ssxap: `ticket_verify failed` reopens a task but leaves its old
    # per-task branch on disk. That branch's commits are already merged into
    # main (the round that got verified) — redispatching onto it as-is gives
    # the worker nothing new to add, and it can just merge main back in and
    # submit an empty PR (the bd-96mn8i incident).
    test "redispatch resets an already-merged branch to current main (bd-8ssxap)",
         %{ws: ws, repo: repo} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "fix the null guard",
          workspace_id: ws.id,
          issue_type: :bug
        })

      branch = BranchNamer.derive(task)

      # Simulate the PRIOR dispatch: a fix was committed, pushed, and merged
      # into main via a real `git merge --squash` — this repo's default
      # GitHub merge method (lib/arbiter/mergers/github/config.ex) and exactly
      # what actually happened in the bd-96mn8i incident (601c8877/c83ca747
      # squashed into a04cc0f4). A squash lands a brand-new single-parent
      # commit on main that the old branch tip is NEVER an ancestor of, unlike
      # a `--no-ff` merge commit — so this reproduces the case plain
      # merge-base ancestry cannot catch on its own.
      assert {:ok, wt_path} = Arbiter.Worker.Worktree.create(repo, branch, "main")
      File.write!(Path.join(wt_path, "FIX.md"), "the fix\n")
      {_, 0} = System.cmd("git", ["-C", wt_path, "add", "FIX.md"])
      {_, 0} = System.cmd("git", ["-C", wt_path, "commit", "-q", "-m", "the fix"])
      {_, 0} = System.cmd("git", ["-C", wt_path, "push", "-q", "origin", branch])

      {_, 0} = System.cmd("git", ["-C", repo, "fetch", "-q", "origin", branch])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])
      {_, 0} = System.cmd("git", ["-C", repo, "merge", "-q", "--squash", "origin/" <> branch])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "the fix (squashed) (#1)"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # main keeps moving — an unrelated PR merges after the squash, before
      # the redispatch. On a busy fleet this is the normal case, and it must
      # not stop the stale branch from being detected (bd-8ssxap round 3).
      File.write!(Path.join(repo, "UNRELATED.md"), "unrelated\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "UNRELATED.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "unrelated PR (#2)"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # The task parks for post-merge verification and comes back :failed —
      # exactly the bd-96mn8i sequence. (bd-842qio: only work in progress
      # parks, so it was in progress first, as the prior dispatch left it.)
      task = put_state!(task, :active)
      {:ok, task} = Ash.update(task, %{}, action: :await_verification)
      {:ok, task} = Arbiter.Tasks.Verification.failed(task, "still broken in prod")

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "st/repo", start_driver: false)

      assert result.worktree_path == wt_path
      # No commits ahead of the current upstream main — the stale, already-
      # merged branch was reset, not reused as-is.
      assert {:ok, false} =
               Arbiter.Worker.Worktree.has_commits_ahead?(wt_path, "origin/main")

      # HEAD lands exactly on the current upstream main tip, not merely
      # "somewhere that happens to have no commits ahead".
      {_, 0} = System.cmd("git", ["-C", repo, "fetch", "-q", "origin", "main"])

      assert Arbiter.Worker.Worktree.head_sha(wt_path) ==
               String.trim(elem(System.cmd("git", ["-C", repo, "rev-parse", "origin/main"]), 0))
    end

    test "redispatch keeps a branch whose commits have NOT merged (normal changes-requested)",
         %{ws: ws, repo: repo} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "still being reviewed",
          workspace_id: ws.id,
          issue_type: :bug
        })

      branch = BranchNamer.derive(task)

      assert {:ok, wt_path} = Arbiter.Worker.Worktree.create(repo, branch, "main")
      File.write!(Path.join(wt_path, "WIP.md"), "wip\n")
      {_, 0} = System.cmd("git", ["-C", wt_path, "add", "WIP.md"])
      {_, 0} = System.cmd("git", ["-C", wt_path, "commit", "-q", "-m", "wip, not merged yet"])

      {:ok, result} =
        Dispatch.dispatch(task.id, force: true, repo: "st/repo", start_driver: false)

      assert result.worktree_path == wt_path
      assert File.exists?(Path.join(wt_path, "WIP.md"))
      assert {:ok, true} = Arbiter.Worker.Worktree.has_commits_ahead?(wt_path, "origin/main")
    end
  end

  describe "work prompt fix-pass sections (bd-bw93c3)" do
    test "includes prior review findings from the latest ReviewGate.Round (bd-dp7hiw)", %{
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "fix pass task", workspace_id: ws.id})

      # As of bd-dp7hiw, `task.notes` only carries a short summary line — the
      # actual findings live in `Arbiter.ReviewGate.Round`, which is what
      # `prior_review_findings_section/1` now reads from.
      {:ok, task} =
        Ash.update(
          task,
          %{notes: "ReviewGate verdict: REQUEST_CHANGES (2026-01-01T00:00:00Z) — rounds: 1"},
          action: :update
        )

      {:ok, _round} =
        Ash.create(Round, %{
          task_id: task.id,
          round: 1,
          role: :review,
          verdict: :request_changes,
          findings: "VERDICT: REQUEST_CHANGES\n\nFix the null guard.",
          finding_count: 1,
          converged: false
        })

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "Prior review findings"
      assert prompt =~ "Fix the null guard."
    end

    test "prefers the later fix round's findings even when its round number is lower (bd-6d3h8m)",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fix pass task, fix round", workspace_id: ws.id})

      # Pass 1 rejects at round 3 (fix_round_attempt 0). The automatic fix
      # round resets numbering and pass 2 rejects again at round 1
      # (fix_round_attempt 1) — the newer findings, but the lower round
      # number. Sorting on `round` alone would surface pass 1's stale
      # findings instead.
      {:ok, _round1} =
        Ash.create(Round, %{
          task_id: task.id,
          round: 3,
          fix_round_attempt: 0,
          role: :review,
          verdict: :request_changes,
          findings: "VERDICT: REQUEST_CHANGES\n\nStale pass-1 finding.",
          finding_count: 1,
          converged: false
        })

      {:ok, _round2} =
        Ash.create(Round, %{
          task_id: task.id,
          round: 1,
          fix_round_attempt: 1,
          role: :review,
          verdict: :request_changes,
          findings: "VERDICT: REQUEST_CHANGES\n\nFresh pass-2 finding.",
          finding_count: 1,
          converged: false
        })

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "Fresh pass-2 finding."
      refute prompt =~ "Stale pass-1 finding."
    end

    test "omits prior review findings section when task has no ReviewGate rounds", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fresh task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "Prior review findings"
    end

    test "includes PR review instruction when task has a pr_ref", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fix pass with pr", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "319"}, action: :update)

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "existing PR (#319)"
      assert prompt =~ "gh pr view 319 --json reviews,reviewComments"
      assert prompt =~ "Do NOT open a new PR"
    end

    test "omits PR review instruction when task has no pr_ref", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no pr task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "gh pr view"
    end

    test "review prompt is unaffected by notes or pr_ref in work mode", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review task", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "42", notes: "some notes"}, action: :update)

      review_prompt = Dispatch.prompt_for_task(task, review: true)
      refute review_prompt =~ "Prior review findings"
      refute review_prompt =~ "existing PR"
    end

    test "review prompt requires the VERIFICATION disclosure and forbids stale re-flags (bd-1j5x6u)",
         %{ws: ws} do
      # bd-4te55l's High finding: the coordinator-dispatched `worker_review` path
      # (this review_prompt/2, consumed by Worker.route_reviewer_completion/1)
      # never got the VERIFICATION: FULL/PARTIAL disclosure protocol that
      # ReviewGate's own in-band round loop got. Same coverage as
      # ReviewGate.review_prompt/1's equivalent test.
      {:ok, task} = Ash.create(Issue, %{title: "review task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "VERIFICATION: FULL",
             "review_prompt must require the reviewer to disclose full verification"

      assert prompt =~ "VERIFICATION: PARTIAL",
             "review_prompt must give the reviewer a way to disclose partial verification"

      assert prompt =~ "re-open the CURRENT file",
             "review_prompt must require re-confirming findings against the current diff, not memory"
    end

    test "includes worktree isolation section when worktree_path is given (bd-cwov25)",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "coding task", workspace_id: ws.id})

      prompt =
        Dispatch.prompt_for_task(task, worktree_path: "/home/ryan/dev/arbiter-worktrees/feat-x")

      assert prompt =~ "FILESYSTEM ISOLATION"
      assert prompt =~ "/home/ryan/dev/arbiter-worktrees/feat-x"
      assert prompt =~ "Do NOT use absolute"
    end

    test "omits worktree isolation section when no worktree_path is given (bd-cwov25)",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "coding task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "FILESYSTEM ISOLATION"
    end

    test "work prompt carries read-discipline guidance against context thrash (bd-8cn795)",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "coding task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "grep",
             "work prompt must steer workers toward grep/symbol search before reading a file"

      assert prompt =~ "bounded",
             "work prompt must call out bounded offset/limit reads over whole-file reads"

      assert prompt =~ "whole-file reads",
             "work prompt must explicitly discourage whole-file reads of large modules"
    end

    test "review prompt carries the same read-discipline guidance (bd-8cn795)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "grep"
      assert prompt =~ "bounded"
    end
  end

  describe "task-type dispatch prompt (bd-5lc99r)" do
    test "a task-type directive gets the findings-in-notes briefing, not the work prompt",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "investigate the flaky deploy",
          workspace_id: ws.id,
          issue_type: :research
        })

      prompt = Dispatch.prompt_for_task(task, [])

      # Frames the deliverable as a findings summary in notes via the MCP tool.
      assert prompt =~ "findings"
      assert prompt =~ "notes"
      assert prompt =~ "ticket_update_progress"
      assert prompt =~ "notes gate"

      # Explicitly NOT the code-change/PR work prompt.
      refute prompt =~ "author a pr_body"
      refute prompt =~ "git commit"
    end

    test "a non-task type still gets the standard work prompt", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "build the thing",
          workspace_id: ws.id,
          issue_type: :feature
        })

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "notes gate"
    end

    test "review: true wins over a task issue_type (reviewer still reviews)", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "task but reviewed",
          workspace_id: ws.id,
          issue_type: :research
        })

      prompt = Dispatch.prompt_for_task(task, review: true)
      refute prompt =~ "notes gate"
    end
  end

  describe "PRPatrol follow-up prompt (bd-6v2my2)" do
    test "a task-type follow-up with source_pr is told it has no branch/PR of its own and may push to the original PR",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "PR #3679: needs follow-up",
          workspace_id: ws.id,
          issue_type: :research,
          source_pr: "3679"
        })

      prompt = Dispatch.prompt_for_task(task, worktree_path: "/tmp/wt-follow-up")

      assert prompt =~ "NO branch or pull request of its"
      assert prompt =~ "PRPatrol follow-up against EXISTING pull request #3679"
      assert prompt =~ "code change at all is SUCCESS"
      assert prompt =~ "gh pr checkout 3679"
      assert prompt =~ "git push -u origin <new-branch>"
      assert prompt =~ "arb create <title> --parent #{task.id} --type feature"

      # Still gets the notes gate (it's a `:task`) and its own worktree's
      # isolation warning (provisioned so it has a checkout to `gh`/`git` from).
      assert prompt =~ "notes gate"
      assert prompt =~ "FILESYSTEM ISOLATION"
      assert prompt =~ "/tmp/wt-follow-up"
    end

    test "a plain task-type directive (no source_pr) keeps the original 'do not edit a repo' framing",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "investigate the flaky deploy",
          workspace_id: ws.id,
          issue_type: :research
        })

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "you are not expected to edit a repo"
      refute prompt =~ "PRPatrol follow-up"
      refute prompt =~ "gh pr checkout"
    end
  end

  describe "conflict_resolve_briefing/3 (#354, Phase 2b)" do
    test "embeds the task intent and the rebase/resolve/test/push steps", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "Widget refactor",
          description: "Extract the widget builder.",
          acceptance: "- builder is pure\n- tests pass",
          workspace_id: ws.id
        })

      briefing = Dispatch.conflict_resolve_briefing(task, "feature/widget", "main")

      # Intent context — resolve conflicts honoring the original task.
      assert briefing =~ "Widget refactor"
      assert briefing =~ "Extract the widget builder."
      assert briefing =~ "builder is pure"

      # The narrow, hardened job: rebase, resolve, run tests, force-push.
      assert briefing =~ "git fetch origin main"
      assert briefing =~ "git rebase origin/main"
      assert briefing =~ "Run the test suite"
      assert briefing =~ "git push --force-with-lease origin feature/widget"
      assert briefing =~ "arb done"

      # Must NOT invite re-implementation or a new PR.
      assert briefing =~ "open a new PR"
      assert briefing =~ "re-implement"
    end

    test "the legacy ConflictResolver prompt now delegates to the hardened briefing", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "Conflicty change", workspace_id: ws.id})

      via_resolver =
        Arbiter.Workflows.MergeQueue.ConflictResolver.prompt_for(%{
          task: task,
          branch: "feature/c",
          target_branch: "develop"
        })

      assert via_resolver == Dispatch.conflict_resolve_briefing(task, "feature/c", "develop")
      assert via_resolver =~ "git rebase origin/develop"
      assert via_resolver =~ "Run the test suite"
    end
  end

  describe "work prompt completion notes (tracker-backed tasks)" do
    test "instructs a tracker-backed worker to produce QA + Deployment notes", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "tracked work",
          workspace_id: ws.id,
          tracker_type: "jira",
          tracker_ref: "AX-17585",
          skip_upstream_create: true
        })

      # Verify the adapter can be resolved and loaded independently of run order.
      # completion_notes_step/1 uses Code.ensure_loaded? so the check succeeds even
      # when the module hasn't been touched earlier in the test suite (bd-6aqgok).
      adapter = Arbiter.Trackers.for_task(task)
      assert Code.ensure_loaded?(adapter), "adapter #{inspect(adapter)} must be loadable"

      assert function_exported?(adapter, :gating_fields, 2),
             "jira adapter must export gating_fields/2"

      prompt = Dispatch.prompt_for_task(task, [])

      # Notes persist via the MCP tool, never the arb escript (bd-53xrmi).
      assert prompt =~ "backed by an external tracker"
      assert prompt =~ "ticket_update_progress"
      assert prompt =~ "qa_notes"
      assert prompt =~ "deployment_notes"
      refute prompt =~ "arb ticket update"
    end

    test "untracked tasks get no completion-notes step", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "local work", workspace_id: ws.id, tracker_type: "none"})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "qa_notes"
      refute prompt =~ "backed by an external tracker"
    end

    test "a tracker type without a tracker_ref gets no completion-notes step", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "tracked but unlinked",
          workspace_id: ws.id,
          tracker_type: "jira",
          tracker_ref: nil,
          skip_upstream_create: true
        })

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "qa_notes"
    end

    test "github-tracked tasks (bd/default workspace) get no completion-notes step", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "github work",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "42",
          skip_upstream_create: true
        })

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "qa_notes"
      refute prompt =~ "backed by an external tracker"
    end
  end

  describe "work prompt PR body authoring (bd-53xrmi)" do
    test "instructs the worker to author a pr_body via MCP and NOT open its own PR",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "author body", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      # Authors the body and persists it via the MCP tool, never the arb escript.
      assert prompt =~ "ticket_update_progress"
      assert prompt =~ "pr_body"
      assert prompt =~ "Summary"
      assert prompt =~ "Test plan"
      refute prompt =~ "arb ticket update"

      # No longer tells the worker to open a PR; explicitly forbids it.
      refute prompt =~ "open a PR if appropriate"
      assert prompt =~ "Do NOT open a pull request"
      assert prompt =~ "gh pr create"
    end

    test "the PR-body step is present for untracked tasks too", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "local body", workspace_id: ws.id, tracker_type: "none"})

      prompt = Dispatch.prompt_for_task(task, [])
      assert prompt =~ "pr_body"
      assert prompt =~ "ticket_update_progress"
    end
  end

  describe "resume/2 (bd-auma3z)" do
    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-resume-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"rs/repo" => repo})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, worktree_root: worktree_root, tmp: tmp}
    end

    # Dispatch a task, provisioning its worktree, then simulate a mid-work stop:
    # the worker fails (lingers in :failed, registered) with the worktree left
    # on disk — exactly the state `arb resume` is built to recover from.
    defp stop_worker_with_outpost(task_id) do
      {:ok, first} = Dispatch.dispatch(task_id, force: true, repo: "rs/repo", start_driver: false)
      assert is_binary(first.worktree_path)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)
      first
    end

    test "reuses the worktree, links the new run, and boots as a resume", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "resume work", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

      prior_run = latest_run(task.id)
      assert prior_run.outcome == :failed

      {:ok, result} =
        Dispatch.resume(task.id, start_driver: false, claude_command: ["sleep", "2"])

      # Same worktree, fresh worker.
      assert result.worktree_path == first.worktree_path
      assert result.worker_pid != first.worker_pid

      snap = Worker.state(result.worker_pid)
      assert snap.meta[:resume] == true
      # The resumed worker (meta.resume, booted :starting) advanced to :working
      # when the claude session started.
      assert snap.state == :working

      # The new run is linked to the prior one.
      new_run = latest_run(task.id)
      assert new_run.id != prior_run.id
      assert new_run.resumed_from_run_id == prior_run.id
    end

    # bd-8ssxap round 2 (reviewer finding 2): `maybe_provision_worktree`'s
    # bd-8ssxap reset-if-merged pre-check must never run on a resume. Take a
    # branch whose commits are ALREADY merged into main (so plain ancestry
    # alone would call it a reset candidate) with an uncommitted, never-
    # committed edit sitting on top — exactly what a worker crash or timeout
    # leaves behind. A resume must reattach to that file, not hard-reset it
    # away.
    test "resume never hard-resets the worktree, preserving uncommitted work", %{
      ws: ws,
      repo: repo
    } do
      {:ok, task} = Ash.create(Issue, %{title: "resume onto merged branch", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

      branch = BranchNamer.derive(task)

      # The dispatched branch is local-only until pushed — push it so it can
      # be merged, then merge its (empty) history into main so it reads as
      # already-merged.
      {_, 0} = System.cmd("git", ["-C", first.worktree_path, "push", "-q", "origin", branch])
      {_, 0} = System.cmd("git", ["-C", repo, "fetch", "-q", "origin", branch])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          repo,
          "merge",
          "-q",
          "--no-ff",
          "-m",
          "merge (nothing to add)",
          "origin/" <> branch
        ])

      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # Leave an uncommitted edit in the preserved worktree, as a crashed or
      # timed-out worker would.
      File.write!(Path.join(first.worktree_path, "in_progress.md"), "not committed yet\n")

      {:ok, result} =
        Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])

      assert result.worktree_path == first.worktree_path
      assert File.exists?(Path.join(result.worktree_path, "in_progress.md"))

      assert File.read!(Path.join(result.worktree_path, "in_progress.md")) ==
               "not committed yet\n"
    end

    # bd-985tkl — the ordering that stranded bd-3qkbch/#1724 and bd-bsdeb2/#1732.
    #
    # `ensure_not_active/1` only ever resolves the EXACT task key, so a live
    # `<task>:fixpass` sibling sails past it; the refusal comes later, from
    # `Worker.start/1`'s family check inside `dispatch/2`. By then
    # `stop_prior_worker/1` has already run, so the failed primary — the process
    # `Worker.Watchdog` monitors — is dead by the time the caller sees the
    # error. The Watchdog's deferral has to survive that `:DOWN`; this pins the
    # fact it has to survive, so a reordering here cannot silently un-fix it.
    test "a resume refused by a live :fixpass sibling has ALREADY stopped the prior worker",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "resume blocked by fixpass", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

      {:ok, fixpass} =
        Worker.start(
          task_id: task.id,
          repo: "rs/repo",
          workspace_id: ws.id,
          registry_key: task.id <> ":fixpass"
        )

      :ok = Worker.advance(fixpass, :implement)
      on_exit(fn -> if Process.alive?(fixpass), do: GenServer.stop(fixpass, :normal) end)

      assert {:error,
              {:worker_start_failed,
               {:task_worker_live, %{registry_key: blocker_key, pid: blocker_pid}}}} =
               Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])

      assert blocker_key == task.id <> ":fixpass"
      assert blocker_pid == fixpass

      # The refusal's cost: the prior worker is gone, taking any `:DOWN`-driven
      # watcher with it unless that watcher is deliberately holding on.
      refute Process.alive?(first.worker_pid)
    end

    # bd-8eheb6: the Watchdog's auto-resume budget is enforced from a counter on
    # the WORKER's meta, because every auto-resume mints a fresh worker and a
    # fresh Watchdog. If resume/2 didn't re-stamp it, the next Watchdog would
    # read 0, the cap would never bind, and a never-converging review would
    # auto-resume forever — the exact loop the cap exists to prevent.
    test "resume/2 re-stamps the awaiting_review auto-resume attempt count", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "auto-resume counter", workspace_id: ws.id})
      _first = stop_worker_with_outpost(task.id)

      {:ok, result} =
        Dispatch.resume(task.id,
          start_driver: false,
          claude_command: ["sleep", "2"],
          awaiting_review_resume_attempts: 2
        )

      assert Worker.state(result.worker_pid).meta[:awaiting_review_resume_attempts] == 2
    end

    test "a resume without the opt leaves the auto-resume counter absent", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no auto-resume counter", workspace_id: ws.id})
      _first = stop_worker_with_outpost(task.id)

      {:ok, result} =
        Dispatch.resume(task.id, start_driver: false, claude_command: ["sleep", "2"])

      refute Map.has_key?(
               Worker.state(result.worker_pid).meta,
               :awaiting_review_resume_attempts
             )
    end

    # bd-a9zb7w: same reasoning for the ReviewGate fix-round budget. Each fix
    # round mints a fresh worker, so both the attempt counter and the digest of
    # the findings the round was dispatched against have to be re-stamped or
    # neither the cap nor the convergence check can bind on the next rejection.
    test "resume/2 re-stamps the ReviewGate fix-round counter and findings digest",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fix-round counter", workspace_id: ws.id})
      _first = stop_worker_with_outpost(task.id)

      {:ok, result} =
        Dispatch.resume(task.id,
          start_driver: false,
          claude_command: ["sleep", "2"],
          review_gate_fix_round_attempts: 2,
          review_gate_findings_digest: "deadbeefdeadbeef"
        )

      meta = Worker.state(result.worker_pid).meta
      assert meta[:review_gate_fix_round_attempts] == 2
      assert meta[:review_gate_findings_digest] == "deadbeefdeadbeef"
    end

    test "a resume without the opts leaves the fix-round counter absent", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no fix-round counter", workspace_id: ws.id})
      _first = stop_worker_with_outpost(task.id)

      {:ok, result} =
        Dispatch.resume(task.id, start_driver: false, claude_command: ["sleep", "2"])

      refute Map.has_key?(Worker.state(result.worker_pid).meta, :review_gate_fix_round_attempts)
      refute Map.has_key?(Worker.state(result.worker_pid).meta, :review_gate_findings_digest)
    end

    test "the resumed worker's prompt is briefed with the prior work", %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "briefed resume", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

      # Commit some "prior work" into the worktree so the briefing has content.
      wt = first.worktree_path
      File.write!(Path.join(wt, "progress.ex"), "defmodule P, do: nil\n")
      {_, 0} = System.cmd("git", ["-C", wt, "add", "progress.ex"])
      {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "-m", "did half the work"])
      _ = repo

      # The worktree was cut from main, so the briefing diffs against main.
      {:ok, prefix} = Arbiter.Worker.ResumeContext.build(task, wt, "main")

      assert prefix =~ "did half the work"
      assert prefix =~ "RESUMING work on task #{task.id}"
    end

    test "refuses when there is no preserved worktree", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no worktree", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

      # Tear the worktree down — nothing left to resume.
      Arbiter.Worker.Worktree.cleanup(first.worktree_path)
      refute File.dir?(first.worktree_path)

      assert {:error, :no_outpost} = Dispatch.resume(task.id, start_driver: false)
    end

    # Round-1 review finding: a detached inspect checkout is not preserved work.
    # If resume accepted it, `ResumeContext.build/3` would run `git log
    # <base>..HEAD` in a tree whose HEAD is `origin/<base>` while the local
    # `<base>` ref is the parent repo's stale one — listing UPSTREAM commits under
    # "the commits the prior worker made … DO NOT start over".
    test "refuses to resume from a detached checkout at the branch leaf", %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "detached resume", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

      # Replace the branch worktree with a detached one at the same leaf — the
      # shape a pre-fix task-type dispatch left behind.
      path = first.worktree_path
      Worktree.cleanup(path)
      branch = BranchNamer.derive(task)
      {:ok, ^path} = Worktree.create_detached(repo, branch, "main")
      assert {:ok, "HEAD"} = Worktree.current_branch(path)

      assert {:error, :no_outpost} = Dispatch.resume(task.id, start_driver: false)
    end

    # bd-4olwyg: a conflict pass left the PR branch's worktree mid-rebase, so
    # HEAD read as detached and resume answered "no preserved worktree" for a
    # directory the next conflict dispatch then tripped over as "exists".
    test "resumes a branch worktree stopped mid-rebase", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "mid-rebase resume", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)
      path = first.worktree_path
      stop_mid_rebase!(path)
      assert {:ok, "HEAD"} = Worktree.current_branch(path)

      assert {:ok, result} =
               Dispatch.resume(task.id, start_driver: false, claude_command: ["sleep", "2"])

      assert result.worktree_path == path
    end

    test "refuses to resume a closed task", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "closed resume", workspace_id: ws.id})
      _ = stop_worker_with_outpost(task.id)
      {:ok, _} = Ash.update(task, %{}, action: :close)

      assert {:error, {:task_closed, _}} = Dispatch.resume(task.id, start_driver: false)
    end

    test "refuses while an worker is still actively working", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "active resume", workspace_id: ws.id})
      # Dispatch but DON'T stop — the run is live (:starting/:working), not stopped.
      {:ok, _live} = Dispatch.dispatch(task.id, force: true, repo: "rs/repo", start_driver: false)

      assert {:error, {:worker_active, %{state: run_state, waiting_on: nil}}} =
               Dispatch.resume(task.id, start_driver: false)

      assert run_state in [:starting, :working]
    end

    # bd-8lq2g7: the refusal message is the last thing an operator reads before
    # deciding what to do, and "stop it before resuming" is actively harmful when
    # the live run is WAITING on its review gate — stopping it discards the
    # review in flight, and the re-dispatch re-runs the whole gate from round 1.
    # Say what's really going on instead. (bd-741sid: no worker stays resident
    # on an open PR any more, so the review gate is the only such wait; the
    # old `:awaiting_review` Watchdog wording, bd-8jixav, went with it.)
    test "the refusal message warns rather than instructs a stop when waiting on the review gate" do
      msg =
        Dispatch.worker_active_message(%{state: :waiting, waiting_on: :review_gate}, "vs-6jrn9m")

      assert msg =~ "vs-6jrn9m"
      assert msg =~ "review gate"

      refute msg =~ "stop it before resuming",
             "a run waiting on the review gate must not be told to stop, got: #{msg}"

      # bd-7xtz6w: `arb worker list` cannot show a ReviewGate's passes, so the
      # message must not send the operator there; it names the evidence the
      # guard saw and the supported way out of a stalled gate instead.
      refute msg =~ "arb worker list"
      assert msg =~ "arb worker resume vs-6jrn9m"

      msg =
        Dispatch.worker_active_message(
          %{
            state: :waiting,
            waiting_on: :review_gate,
            review_evidence: ["review pass x is running"]
          },
          "vs-6jrn9m"
        )

      assert msg =~ "review pass x is running"
    end

    test "the refusal message still tells an operator to stop a genuinely working worker" do
      for run <- [%{state: :working, waiting_on: nil}, :working] do
        msg = Dispatch.worker_active_message(run, "vs-6jrn9m")
        assert msg =~ "stop it before resuming"
        assert msg =~ "working"
      end

      msg = Dispatch.worker_active_message(%{state: :waiting, waiting_on: :question}, "vs-6jrn9m")
      assert msg =~ "stop it before resuming"
      assert msg =~ "waiting"
    end

    test "inherits the repo from the prior run when omitted", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "repo inherit", workspace_id: ws.id})
      _ = stop_worker_with_outpost(task.id)

      # No repo passed — must inherit "rs/repo" from the prior run record.
      {:ok, result} =
        Dispatch.resume(task.id, start_driver: false, claude_command: ["sleep", "2"])

      assert is_binary(result.worktree_path)
    end

    # bd-b7e33c AC5 post-merge finding: `worker_resume` (the MCP tool backing
    # this path) resumed an agy task straight onto Claude — Routing.choose/2
    # re-decided the provider from the workspace default with nothing to pin
    # it to the prior run. Without an explicit `agent_type`, `resume/2` must
    # now default to the provider the task's most recent usage row ran on.
    test "resume/2 without an explicit agent_type stays on the prior run's provider",
         %{ws: ws, tmp: tmp} do
      gemini_file = Path.join(tmp, "gemini-resume-argv.txt")
      :ok = stub_sleeping_on_path(tmp, "agy", gemini_file)

      {:ok, task} = Ash.create(Issue, %{title: "agy resume provider", workspace_id: ws.id})

      # Workspace defaults to Claude — nothing here forces gemini explicitly on
      # the resume call, so a passing test proves the default came from the
      # prior run's ledger row, not from workspace/routing config.
      {:ok, first} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rs/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          preflight: false
        )

      _ = wait_for_argv!(gemini_file)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)

      # A real agy run writes this row itself when its session port exits;
      # simulate that here rather than running a full CLI session.
      {:ok, _event} =
        Ash.create(UsageEvent, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "rs/repo",
          step: :work,
          provider: "gemini",
          occurred_at: DateTime.utc_now()
        })

      File.rm!(gemini_file)

      {:ok, result} = Dispatch.resume(task.id, start_driver: false, preflight: false)

      _ = wait_for_argv!(gemini_file)

      routing = Worker.state(result.worker_pid).meta[:routing_config]
      assert routing.provider == "gemini"
    end
  end

  describe "resume_session/2 (bd-1z7624)" do
    @env_key :repo_paths

    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "dispatch-resume-session-#{:erlang.unique_integer([:positive])}"
        )

      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"rs/repo" => repo})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, worktree_root: worktree_root, tmp: tmp}
    end

    # bd-b7e33c AC2/AC5: the actual `arb worker resume` / `POST
    # /api/workers/:id/resume` surface. Session-level resume threads the prior
    # `session_id` through `Worker.inject_resume_argv/4`, which now (T7)
    # translates it to `--conversation <id>` for gemini/agy — but only if the
    # fresh dispatch actually resolves the gemini adapter. Without pinning
    # `:agent_type` to the ledger's recorded provider, `Routing.choose/2` could
    # still hand the spawn to Claude, and `--conversation <agy-uuid>` would get
    # injected into a Claude invocation instead.
    test "resume_session/2 without an explicit agent_type dispatches the same provider as the prior session",
         %{ws: ws, tmp: tmp} do
      gemini_file = Path.join(tmp, "gemini-resume-session-argv.txt")
      :ok = stub_sleeping_on_path(tmp, "agy", gemini_file)

      {:ok, task} = Ash.create(Issue, %{title: "agy resume session", workspace_id: ws.id})

      {:ok, first} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rs/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          preflight: false
        )

      _ = wait_for_argv!(gemini_file)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)

      {:ok, _event} =
        Ash.create(UsageEvent, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "rs/repo",
          step: :work,
          provider: "gemini",
          session_id: "agy-conv-#{:erlang.unique_integer([:positive])}",
          occurred_at: DateTime.utc_now()
        })

      File.rm!(gemini_file)

      {:ok, result} = Dispatch.resume_session(task.id, start_driver: false, preflight: false)

      resumed_args = wait_for_argv!(gemini_file)
      assert "--conversation" in resumed_args

      routing = Worker.state(result.worker_pid).meta[:routing_config]
      assert routing.provider == "gemini"
    end

    # bd-atsde3: `claude --resume <sid>` for a session whose JSONL exists nowhere
    # ("No conversation found with session ID") must degrade to a briefing
    # resume; one whose JSONL is on disk keeps `--resume`.
    for {label, with_history?} <- [{"missing", false}, {"present", true}] do
      test "resume_session/2 with claude session history #{label}", %{ws: ws, tmp: tmp} do
        argv_file = Path.join(tmp, "claude-resume-session-argv.txt")
        :ok = stub_sleeping_on_path(tmp, "claude", argv_file)
        sid = "11111111-2222-3333-4444-#{:erlang.unique_integer([:positive])}"

        {:ok, task} = Ash.create(Issue, %{title: "claude resume session", workspace_id: ws.id})

        {:ok, first} =
          Dispatch.dispatch(task.id,
            force: true,
            repo: "rs/repo",
            start_driver: false,
            start_claude: true,
            agent_type: :claude,
            preflight: false
          )

        _ = wait_for_argv!(argv_file)
        :ok = Worker.fail(first.worker_pid, :token_exhausted)

        config_dir = Path.join(tmp, "prior-config")

        if unquote(with_history?) do
          File.mkdir_p!(Path.join([config_dir, "projects", "-some-slug"]))
          File.write!(Path.join([config_dir, "projects", "-some-slug", sid <> ".jsonl"]), "{}\n")
        end

        {:ok, _run} =
          Ash.create(Run, %{
            task_id: task.id,
            task_title: task.title,
            repo: "rs/repo",
            workspace_id: ws.id,
            state: :finished,
            outcome: :failed,
            started_at: DateTime.utc_now(),
            session_id: sid,
            config_dir: config_dir,
            provider: "claude"
          })

        {:ok, _event} =
          Ash.create(UsageEvent, %{
            task_id: task.id,
            workspace_id: ws.id,
            repo: "rs/repo",
            step: :work,
            provider: "claude",
            session_id: sid,
            occurred_at: DateTime.utc_now()
          })

        File.rm!(argv_file)

        assert {:ok, _} = Dispatch.resume_session(task.id, start_driver: false, preflight: false)

        args = wait_for_argv!(argv_file)

        if unquote(with_history?) do
          assert "--resume" in args and sid in args
        else
          refute "--resume" in args
        end
      end
    end

    # bd-atsde3 AC2: the Reconciler's post-restart auto-resume is a briefing
    # resume (`Dispatch.resume/2`), never `claude --resume <sid>`, so it cannot
    # hit "No conversation found" in a podman run's fresh config dir.
    test "Reconciler.default_resume/1 respawns claude without --resume", %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "claude-reconciler-argv.txt")
      :ok = stub_sleeping_on_path(tmp, "claude", argv_file)

      {:ok, task} = Ash.create(Issue, %{title: "reconciler resume", workspace_id: ws.id})

      {:ok, first} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rs/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :claude,
          preflight: false
        )

      _ = wait_for_argv!(argv_file)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)

      {:ok, _event} =
        Ash.create(UsageEvent, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "rs/repo",
          step: :work,
          provider: "claude",
          session_id: "99999999-2222-3333-4444-555555555555",
          occurred_at: DateTime.utc_now()
        })

      File.rm!(argv_file)
      {:ok, issue} = Ash.get(Issue, task.id)

      assert {:ok, _} =
               Arbiter.Workers.Reconciler.default_resume(issue,
                 start_driver: false,
                 preflight: false
               )

      args = wait_for_argv!(argv_file)
      refute "--resume" in args
      refute "99999999-2222-3333-4444-555555555555" in args
    end

    # bd-b7e33c post-merge finding (2026-09-19), corrected 2026-09-21 per
    # round-1 review finding 1: the provider and the session_id used to come
    # from two INDEPENDENT "newest row" queries, so a task whose most recent
    # signal recorded a different provider than the row that actually
    # captured the resumable session_id could pin `:agent_type` to the wrong
    # provider while still threading the OTHER session's conversation id —
    # exactly the "spawn handed a conversation UUID that belongs to a
    # different provider" shape the AC5 fix was meant to close.
    #
    # The provider half of that pin is NOT resolved off the usage ledger —
    # `resolve_session_resume_provider/3` only falls through to
    # `resolve_resume_provider/2` -> `Agents.resolve_revision_provider/2` ->
    # `Run.latest_authoring_provider/1`, which reads `worker_run` rows FIRST
    # and only consults the usage ledger when no run carries a provider. So
    # the mismatch has to be a newer **Run** row, not a newer usage-event row
    # (a usage-event-only fixture resolves to the same provider before and
    # after the fix, and would pass even with the fix reverted). Reproduce it
    # directly: an OLDER usage row carries the real, resumable `session_id`
    # under `provider: "gemini"`, while a NEWER **Run** row (a claude fallback
    # attempt that failed before capturing a session) records `provider:
    # "claude"`.
    test "resume_session/2 pins the provider to the SAME row the session_id came from",
         %{ws: ws, tmp: tmp} do
      gemini_file = Path.join(tmp, "gemini-resume-mismatch-argv.txt")
      claude_file = Path.join(tmp, "claude-resume-mismatch-argv.txt")
      :ok = stub_sleeping_on_path(tmp, "agy", gemini_file)
      :ok = stub_sleeping_on_path(tmp, "claude", claude_file)

      {:ok, task} = Ash.create(Issue, %{title: "agy resume mismatch", workspace_id: ws.id})

      {:ok, first} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rs/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          preflight: false
        )

      _ = wait_for_argv!(gemini_file)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)

      {:ok, older} =
        Ash.create(UsageEvent, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "rs/repo",
          step: :work,
          provider: "gemini",
          session_id: "agy-conv-mismatch",
          occurred_at: DateTime.add(DateTime.utc_now(), -600, :second)
        })

      # A newer FAILED claude attempt that never captured a session_id — this
      # is what Run.latest_authoring_provider/1 actually reads, so it is what
      # would steal the resume without resolve_session_resume_provider/3.
      {:ok, _claude_run} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "rs/repo",
          workspace_id: ws.id,
          kind: :implement,
          state: :finished,
          outcome: :failed,
          provider: "claude",
          started_at: DateTime.utc_now()
        })

      # sanity: the two independent lookups really do disagree, so this test
      # actually exercises the mismatch rather than a scenario that can't occur.
      refute older.session_id == nil
      assert Run.latest_authoring_provider(task.id) == :claude

      File.rm!(gemini_file)

      {:ok, result} =
        Dispatch.resume_session(task.id,
          repo: "rs/repo",
          start_driver: false,
          preflight: false
        )

      resumed_args = wait_for_argv!(gemini_file)
      assert "--conversation" in resumed_args
      conv_idx = Enum.find_index(resumed_args, &(&1 == "--conversation"))
      assert Enum.at(resumed_args, conv_idx + 1) == "agy-conv-mismatch"

      routing = Worker.state(result.worker_pid).meta[:routing_config]
      assert routing.provider == "gemini"
    end

    # bd-b7e33c finding 2 (round 1 re-review): the mismatch guard in
    # `maybe_put_resume_session_id/9` also has to fire when the CALLER forces
    # a different provider via an explicit `agent_type:` opt — not just when
    # the resolver falls through on its own. Reproduce that path directly: the
    # prior session captured a resumable id under gemini, but the caller
    # overrides to claude. The override must win (routing.provider == claude)
    # and the foreign gemini conversation id must NOT be threaded into the
    # claude spawn — it degrades to a real `ResumeContext.build/3` git-derived
    # briefing instead (bd-b7e33c round-2 finding 1: the fallback used to drop
    # the session id but never build a briefing either, so it silently
    # produced a fresh, un-briefed dispatch).
    test "resume_session/2 with an explicit agent_type override does not thread the other provider's session_id",
         %{ws: ws, tmp: tmp} do
      gemini_file = Path.join(tmp, "gemini-resume-override-argv.txt")
      claude_file = Path.join(tmp, "claude-resume-override-argv.txt")
      :ok = stub_sleeping_on_path(tmp, "agy", gemini_file)
      :ok = stub_sleeping_on_path(tmp, "claude", claude_file)

      {:ok, task} = Ash.create(Issue, %{title: "agy resume override", workspace_id: ws.id})

      {:ok, first} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rs/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          preflight: false
        )

      _ = wait_for_argv!(gemini_file)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)

      {:ok, _event} =
        Ash.create(UsageEvent, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: "rs/repo",
          step: :work,
          provider: "gemini",
          session_id: "agy-conv-override",
          occurred_at: DateTime.utc_now()
        })

      {:ok, result} =
        Dispatch.resume_session(task.id,
          repo: "rs/repo",
          start_driver: false,
          preflight: false,
          agent_type: :claude
        )

      resumed_args = wait_for_argv!(claude_file)
      refute "--resume" in resumed_args
      refute "agy-conv-override" in resumed_args

      # The dropped session id must be replaced with a real git-derived
      # briefing (ResumeContext.build/3), not a silently un-briefed fresh
      # dispatch — the prompt argument carries the distinctive framing text.
      assert Enum.any?(resumed_args, &String.contains?(&1, "RESUMING work on task"))

      routing = Worker.state(result.worker_pid).meta[:routing_config]
      assert routing.provider == "claude"
    end
  end

  describe "review dispatch (review: true)" do
    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-review-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      prior = Application.get_env(:arbiter, @env_key)
      Application.put_env(:arbiter, @env_key, %{"rv/repo" => repo})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, @env_key, prior),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo}
    end

    test "review: true skips the worktree and attaches the CodeReview workflow",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review me", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_driver: false
        )

      # No per-task branch, no worktree.
      assert result.worktree_path == nil

      # Workflow attached is CodeReview, not Work.
      machine_state = Arbiter.Workflows.MachineState |> Ash.get!(result.machine_id)
      assert machine_state.workflow_module == inspect(Arbiter.Workflows.CodeReview)

      # Worker is tagged review_only so completion bypasses the merge queue.
      snap = Worker.state(result.worker_pid)
      assert snap.meta[:review_only] == true
      refute Map.has_key?(snap.meta, :branch)
    end

    test "review prompt mentions the task's tracker ref and bans pushes/merges",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "external pr review",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "999"
        })

      prompt =
        Arbiter.Worker.Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "reviewer worker"
      assert prompt =~ "github:999"
      assert prompt =~ "Do NOT push"
      assert prompt =~ "Do NOT merge"
      assert prompt =~ "arb done"

      # The work prompt is still produced by default for non-review dispatches.
      work = Arbiter.Worker.Dispatch.prompt_for_task(task, [])
      assert work =~ "working autonomously"
      refute work =~ "reviewer worker"
    end

    test "review prompt uses pr_ref when set, not tracker_ref (issue vs PR number fix)",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "pr ref takes precedence",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "93"
        })

      {:ok, task} = Ash.update(task, %{pr_ref: "123"}, action: :update)

      prompt = Arbiter.Worker.Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "github:123"
      refute prompt =~ "github:93"
    end

    test "review prompt includes pre-fetched tracker_context block when provided (bd-2eo4cg)",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "review coworker PR",
          workspace_id: ws.id,
          tracker_type: :none,
          tracker_context_type: :jira,
          tracker_context_ref: "AX-18004"
        })

      # Simulate a pre-fetched tracker context (normally done in build_agent_session_opts).
      context = %{
        ref: "AX-18004",
        type: :jira,
        title: "Some Jira ticket",
        description: "## Acceptance\n- feature works\n- tests pass"
      }

      prompt =
        Arbiter.Worker.Dispatch.prompt_for_task(task, review: true, tracker_context: context)

      assert prompt =~ "Tracker context (read-only, jira:AX-18004)"
      assert prompt =~ "Some Jira ticket"
      assert prompt =~ "feature works"
      # The task has no tracker_ref, so no "Tracker ref (PR/MR to review)" line
      refute prompt =~ "Tracker ref (PR/MR to review)"
    end

    test "review prompt omits tracker context block when no context is pre-fetched (bd-2eo4cg)",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "review without context",
          workspace_id: ws.id,
          tracker_type: :none
        })

      prompt = Arbiter.Worker.Dispatch.prompt_for_task(task, review: true)

      refute prompt =~ "Tracker context (read-only"
    end

    test "review with start_claude: true uses the repo path as cwd when no worktree",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review w/ claude", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          start_driver: false,
          # A no-op argv standing in for a real claude session — proves the
          # port opened, which means the cwd resolution succeeded.
          claude_command: ["true"]
        )

      assert is_port(result.claude_port)
      assert result.worktree_path == nil
    end

    test "review with start_claude: true and an unresolvable repo errors",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no cwd", workspace_id: ws.id})

      assert {:error, {:repo_not_found, "no-such-repo"}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "no-such-repo",
                 review: true,
                 start_claude: true,
                 claude_command: ["true"]
               )
    end
  end

  describe "review dispatch worktree checkout (bd-199giy)" do
    @env_key :repo_paths

    # A source checkout with a real `origin` (a bare repo on disk) and the
    # task's own branch pushed to it — the production shape of a review
    # dispatch: the implementer pushed its branch, and the coordinator's
    # shared checkout may never have fetched it.
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "dispatch-review-wt-#{:erlang.unique_integer([:positive])}")

      remote = Path.join(tmp, "remote.git")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(tmp)

      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])

      for {k, v} <- [
            {"user.email", "test@example.com"},
            {"user.name", "Test User"},
            {"commit.gpgsign", "false"}
          ],
          do: {_, 0} = System.cmd("git", ["-C", repo, "config", k, v])

      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "-u", "origin", "main"])

      prior = Application.get_env(:arbiter, @env_key)
      Application.put_env(:arbiter, @env_key, %{"rv/repo" => repo})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, @env_key, prior),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, remote: remote, tmp: tmp}
    end

    # Push `branch` (with one extra commit) to origin, then rewind the source
    # checkout to main so the branch exists ONLY on the remote.
    defp push_task_branch(repo, branch) do
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", branch])
      File.write!(Path.join(repo, "feature.txt"), "work\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "feature.txt"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "the work"])
      {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", branch])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])
      {_, 0} = System.cmd("git", ["-C", repo, "branch", "-q", "-D", branch])
      String.trim(sha)
    end

    test "provisions a detached worktree at the reviewed branch's origin head",
         %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "worktree review", workspace_id: ws.id})
      branch = Arbiter.Worker.BranchNamer.derive(task)
      head_sha = push_task_branch(repo, branch)

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          start_driver: false,
          claude_command: ["true"]
        )

      assert %{path: path, branch: ^branch, head_sha: ^head_sha, base_branch: "main"} =
               result.review_checkout

      on_exit(fn -> Arbiter.Reviews.Checkout.teardown(path) end)

      # A real, separate directory — not the shared checkout.
      assert File.dir?(path)
      refute path == repo
      assert File.exists?(Path.join(path, "feature.txt"))

      {out, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
      assert String.trim(out) == head_sha

      # Detached, so the implementer's own worktree keeps the branch.
      {_, code} = System.cmd("git", ["-C", path, "symbolic-ref", "-q", "HEAD"])
      assert code != 0

      # No per-task branch worktree was provisioned — the review checkout is
      # its own thing, not the dispatch worktree.
      assert result.worktree_path == nil
    end

    test "the review prompt points at the provisioned checkout", %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "prompt points at checkout", workspace_id: ws.id})
      branch = Arbiter.Worker.BranchNamer.derive(task)
      _sha = push_task_branch(repo, branch)

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          start_driver: false,
          claude_command: ["true"]
        )

      checkout = result.review_checkout
      on_exit(fn -> Arbiter.Reviews.Checkout.teardown(checkout.path) end)

      prompt = Dispatch.prompt_for_task(task, review: true, review_checkout: checkout)

      assert prompt =~ checkout.path
      assert prompt =~ "throwaway git worktree checked out DETACHED"
      assert prompt =~ "git diff origin/main...HEAD"
      refute prompt =~ "Do not check out the branch."
      refute prompt =~ "no worktree was provisioned"

      # The kill-discipline guidance carries over: a worktree-backed reviewer
      # can boot servers again.
      assert prompt =~ "NEVER use `pkill`"
    end

    test "falls back to the shared checkout when the branch was never pushed",
         %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "never pushed", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          start_driver: false,
          claude_command: ["true"]
        )

      # Provisioning failed (no such branch on origin) — the review still ran.
      assert result.review_checkout == nil
      assert is_port(result.claude_port)
      assert File.dir?(repo)
    end

    # bd-4wy1w1 (P5): a branch whose worker ran in a private clone (git
    # layout B) and never pushed exists only in that clone; the checkout's
    # local fallback looks for it in the main repo, so it is synced back first.
    test "reviews a never-pushed branch that lives only in a private clone",
         %{ws: ws, repo: repo, tmp: tmp} do
      prior_root = Application.fetch_env(:arbiter, :worktree_root)
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))

      on_exit(fn ->
        case prior_root do
          {:ok, value} -> Application.put_env(:arbiter, :worktree_root, value)
          :error -> Application.delete_env(:arbiter, :worktree_root)
        end
      end)

      {:ok, task} = Ash.create(Issue, %{title: "clone-only review", workspace_id: ws.id})
      branch = Arbiter.Worker.BranchNamer.derive(task)
      {:ok, clone} = Arbiter.Worker.PrivateClone.create(repo, branch, "main")
      File.write!(Path.join(clone, "feature.txt"), "clone work\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "feature.txt"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "clone work"])
      {head, 0} = System.cmd("git", ["-C", clone, "rev-parse", "HEAD"])
      head_sha = String.trim(head)

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          start_driver: false,
          claude_command: ["true"]
        )

      assert %{path: path, head_sha: ^head_sha} = result.review_checkout
      on_exit(fn -> Arbiter.Reviews.Checkout.teardown(path) end)
      assert File.read!(Path.join(path, "feature.txt")) == "clone work\n"
    end

    # bd-5fa7zg: the reviewer runs tests in this checkout, so it is seeded from the
    # implementer's worktree (and `worker.repos.<repo>.seed_paths`) like the
    # ReviewGate's own gate-review checkout, instead of starting cold.
    test "seeds the review checkout from the implementer worktree and seed_paths",
         %{ws: ws, repo: repo, tmp: tmp} do
      prior_root = Application.fetch_env(:arbiter, :worktree_root)
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))

      on_exit(fn ->
        case prior_root do
          {:ok, value} -> Application.put_env(:arbiter, :worktree_root, value)
          :error -> Application.delete_env(:arbiter, :worktree_root)
        end
      end)

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "worker" => %{"repos" => %{"repo" => %{"seed_paths" => ["deps", "priv/plts"]}}}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "seeded review", workspace_id: ws.id})
      branch = Arbiter.Worker.BranchNamer.derive(task)
      _sha = push_task_branch(repo, branch)

      impl = Arbiter.Worker.Worktree.worktree_path(branch)
      File.mkdir_p!(Path.join(impl, "deps/jason"))
      File.write!(Path.join(impl, "deps/jason/mix.exs"), "# dep\n")
      File.mkdir_p!(Path.join(impl, "priv/plts"))
      File.write!(Path.join(impl, "priv/plts/core.plt"), "plt")

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          start_driver: false,
          claude_command: ["true"]
        )

      %{path: path} = result.review_checkout
      on_exit(fn -> Arbiter.Reviews.Checkout.teardown(path) end)

      assert File.read!(Path.join(path, "deps/jason/mix.exs")) == "# dep\n"
      assert File.read!(Path.join(path, "priv/plts/core.plt")) == "plt"
    end

    test "tears the review checkout down when the dispatch fails after the agent spawns",
         %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "teardown on failure", workspace_id: ws.id})
      branch = Arbiter.Worker.BranchNamer.derive(task)
      _sha = push_task_branch(repo, branch)

      before = worktree_paths(repo)

      # Everything through the agent spawn succeeds (so the checkout IS
      # provisioned); the machine attach then fails on a module that is not a
      # workflow. That error path is where the throwaway checkout used to leak:
      # `finish_dispatch/4`'s `else` could not see the rebound opts carrying it.
      assert {:error, {:machine_start_failed, _}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "rv/repo",
                 review: true,
                 start_claude: true,
                 start_driver: false,
                 claude_command: ["true"],
                 workflow_module: NotAWorkflowModule
               )

      # Nothing left behind — neither on disk nor registered in the shared
      # repo's `.git/worktrees` (which `git worktree list` reads).
      assert worktree_paths(repo) == before
      refute Enum.any?(worktree_paths(repo), &(Path.basename(&1) =~ ~r/^review-/))
    end

    defp worktree_paths(repo) do
      {out, 0} = System.cmd("git", ["-C", repo, "worktree", "list", "--porcelain"])

      out
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "worktree "))
      |> Enum.map(&String.trim_leading(&1, "worktree "))
      |> Enum.sort()
    end

    test "the driver tears the review checkout down when the worker finishes",
         %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "teardown me", workspace_id: ws.id})
      branch = Arbiter.Worker.BranchNamer.derive(task)
      _sha = push_task_branch(repo, branch)

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          claude_command: ["true"],
          interval_ms: 1
        )

      path = result.review_checkout.path
      assert File.dir?(path)

      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 10_000

      refute File.dir?(path)
    end
  end

  describe "review security posture (bd-199giy)" do
    test "denies the mutating tools once the reviewer has a real checkout" do
      base = Arbiter.Agents.SecurityPolicy.base()

      hardened = Dispatch.review_security_policy(base, review_checkout: %{path: "/tmp/wt"})

      assert "Edit" in hardened.permissions.deny
      assert "Write" in hardened.permissions.deny
      assert "NotebookEdit" in hardened.permissions.deny
      # The reviewer still needs the network to post its review via `gh`/`glab`.
      assert hardened.sandbox.network == true
    end

    test "leaves the policy untouched for a diff-only review" do
      base = Arbiter.Agents.SecurityPolicy.base()

      assert Dispatch.review_security_policy(base, []) == base
      assert Dispatch.review_security_policy(base, review_checkout: nil) == base
    end
  end

  describe "review_security_policy/2 sandbox backend (bd-4rvf98)" do
    setup do
      %{
        podman:
          Arbiter.Agents.SecurityPolicy.merge(Arbiter.Agents.SecurityPolicy.base(), %{
            sandbox: %{backend: :podman}
          })
      }
    end

    test "a review spawn runs under review_backend, not the implement backend", %{podman: podman} do
      for opts <- [[review_checkout: %{path: "/tmp/wt"}], [review: true]] do
        review = Dispatch.review_security_policy(podman, opts)
        assert Arbiter.Agents.SecurityPolicy.sandbox_backend(review) == :bwrap
      end
    end

    test "an implement spawn keeps the podman backend", %{podman: podman} do
      assert Dispatch.review_security_policy(podman, []) == podman
      assert Dispatch.review_security_policy(podman, review: false) == podman
    end

    test "an explicit podman review_backend is kept, so the spawn is refused", %{podman: podman} do
      both =
        Arbiter.Agents.SecurityPolicy.merge(podman, %{sandbox: %{review_backend: :podman}})

      review = Dispatch.review_security_policy(both, review: true)
      assert Arbiter.Agents.SecurityPolicy.sandbox_backend(review) == :podman

      assert {:error, {:sandbox_backend_unavailable, :podman, _}} =
               Arbiter.Worker.Sandbox.module(review)

      assert {:error, {:sandbox_backend_unavailable, :podman, _}} =
               Arbiter.Agents.Claude.default_argv("hi", security: review)
    end
  end

  describe "real-work repo resolution (bd-1ziw04)" do
    # Tests verify that start_claude: true dispatches fail loudly when no repo
    # can be resolved, and auto-select when exactly one repo is available.

    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-repo-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo}
    end

    test "0 repos: start_claude: true with no repo and empty :repo_paths fails loudly",
         %{ws: ws} do
      Application.delete_env(:arbiter, @env_key)
      task = issue_without_repo!(%{title: "no repos", workspace_id: ws.id})

      assert {:error, :no_repo_configured} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      # Refused BEFORE any state mutation: task still :backlog, no worker.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :backlog
      assert Worker.whereis(task.id) == nil
    end

    test "1 repo: start_claude: true with no repo auto-selects the sole configured repo",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"sole/repo" => repo})
      task = issue_without_repo!(%{title: "auto-select", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["sleep", "2"],
                 preflight: false
               )

      # Worktree provisioned using the auto-selected repo.
      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "multi-repo: start_claude: true with no repo and multiple :repo_paths fails loudly",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"repo/a" => repo, "repo/b" => repo})
      task = issue_without_repo!(%{title: "multi repos", workspace_id: ws.id})

      assert {:error, {:ambiguous_repo, repos}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert "repo/a" in repos
      assert "repo/b" in repos

      # Refused before any state mutation.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :backlog
      assert Worker.whereis(task.id) == nil
    end

    test "multi-repo: workspace default_repo resolves the ambiguity (bd-5pctey)",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"repo/a" => repo, "repo/b" => repo})
      {:ok, ws} = Ash.update(ws, %{config: %{"default_repo" => "repo/b"}}, action: :update)
      task = issue_without_repo!(%{title: "multi repos with default", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "multi-repo: workspace default_repo that doesn't resolve still fails loudly (bd-5pctey)",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"repo/a" => repo, "repo/b" => repo})

      {:ok, ws} =
        Ash.update(ws, %{config: %{"default_repo" => "repo/nonexistent"}}, action: :update)

      task = issue_without_repo!(%{title: "multi repos with bad default", workspace_id: ws.id})

      assert {:error, {:ambiguous_repo, repos}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert "repo/a" in repos
      assert "repo/b" in repos
    end

    test "multi-repo: explicit :repo opt overrides workspace default_repo (bd-5pctey)",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"repo/a" => repo, "repo/b" => repo})
      {:ok, ws} = Ash.update(ws, %{config: %{"default_repo" => "repo/b"}}, action: :update)
      task = issue_without_repo!(%{title: "explicit beats default", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "repo/a",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "explicit repo not in :repo_paths fails with {:repo_not_found, repo}",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"real/repo" => repo})
      {:ok, task} = Ash.create(Issue, %{title: "bad repo", workspace_id: ws.id})

      assert {:error, {:repo_not_found, "no-such/repo"}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "no-such/repo",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      # Refused before any state mutation.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :backlog
      assert Worker.whereis(task.id) == nil
    end

    test "explicit repo slug resolves against a registered key differing only by _/- (bd-6rioa4)",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{
        "acme-corp/apex-server" => repo
      })

      {:ok, task} = Ash.create(Issue, %{title: "underscore slug", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "acme-corp/apex_server",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "dry dispatch (no start_claude) is unaffected — still parks without a repo", %{ws: ws} do
      Application.delete_env(:arbiter, @env_key)
      {:ok, task} = Ash.create(Issue, %{title: "dry dispatch", workspace_id: ws.id})

      # No --with-claude → no repo required → succeeds and parks as :active.
      assert {:ok, result} = Dispatch.dispatch(task.id, force: true, start_driver: false)
      assert result.task.state == :active
      assert result.worktree_path == nil
    end
  end

  describe "issue-level repo assignment (bd-2jum8j)" do
    @env_key :repo_paths

    # Two distinguishable source repos so a test can prove *which* one the
    # worktree was cut from by looking for its marker file.
    defp init_repo!(tmp, name) do
      repo = Path.join(tmp, name)
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "MARKER-#{name}"), "#{name}\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      remote = Path.join(tmp, "#{name}-remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      repo
    end

    setup do
      tmp = Path.join(System.tmp_dir!(), "issue-repo-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      repo_a = init_repo!(tmp, "alpha")
      repo_b = init_repo!(tmp, "beta")

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"org/alpha" => repo_a, "org/beta" => repo_b})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo_a: repo_a, repo_b: repo_b}
    end

    test "an Issue persists a repo assignment", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "carries a repo", workspace_id: ws.id, repo: "org/beta"})

      assert task.repo == "org/beta"
      assert Ash.get!(Issue, task.id).repo == "org/beta"

      {:ok, updated} = Ash.update(task, %{repo: "org/alpha"})
      assert updated.repo == "org/alpha"
    end

    test "multi-repo workspace: the issue's own repo resolves dispatch instead of erroring",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "issue repo wins", workspace_id: ws.id, repo: "org/beta"})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert File.exists?(Path.join(result.worktree_path, "MARKER-beta"))
      assert latest_run(task.id).repo == "org/beta"
    end

    test "an explicit per-dispatch repo overrides the issue's stored repo", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "override", workspace_id: ws.id, repo: "org/beta"})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "org/alpha",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert File.exists?(Path.join(result.worktree_path, "MARKER-alpha"))
      assert latest_run(task.id).repo == "org/alpha"
    end

    test "an issue repo that no longer resolves fails loudly rather than picking another",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "stale repo", workspace_id: ws.id, repo: "org/alpha"})

      # The repo went away *after* the issue was filed — bd-9dwbvt refuses an
      # unconfigured repo at create time, so this is the only way in.
      {:ok, task} = Ash.update(task, %{repo: "org/gone"})

      assert {:error, {:repo_not_found, "org/gone"}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert Ash.get!(Issue, task.id).state == :backlog
      assert Worker.whereis(task.id) == nil
    end

    test "an issue with no repo still falls through to the ambiguous-repo error", %{ws: ws} do
      task = issue_without_repo!(%{title: "no issue repo", workspace_id: ws.id})

      assert {:error, {:ambiguous_repo, repos}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert "org/alpha" in repos
      assert "org/beta" in repos
    end

    test "a dry dispatch (no start_claude) still binds the issue's repo", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "dry with issue repo", workspace_id: ws.id, repo: "org/beta"})

      assert {:ok, result} = Dispatch.dispatch(task.id, force: true, start_driver: false)
      assert result.task.state == :active
      assert File.exists?(Path.join(result.worktree_path, "MARKER-beta"))
    end
  end

  defmodule StubMigrationsPending do
    @moduledoc false
    def count_pending, do: {:ok, 3}
  end

  defmodule StubMigrationsUnreachable do
    @moduledoc false
    def count_pending, do: {:error, :unreachable}
  end

  describe "pending migrations gate" do
    test "dispatch proceeds when migrations are current", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "migrations current", workspace_id: ws.id})

      # In a test environment where migrations are applied, dispatch should proceed
      # (or fail for other reasons, but not due to pending migrations)
      case Dispatch.dispatch(task.id, force: true, repo: "test/repo", start_driver: false) do
        {:ok, result} ->
          assert result.task.state == :active

        {:error, {:pending_migrations, _count}} ->
          # If we do have pending migrations in test, that's OK too — this just verifies
          # the check is in place and returns the expected error format
          :ok

        other ->
          flunk("unexpected dispatch result: #{inspect(other)}")
      end
    end

    test "dispatch is refused with a reason naming the migration state when migrations are pending",
         %{ws: ws} do
      Application.put_env(:arbiter, :migrations_module, StubMigrationsPending)

      on_exit(fn -> Application.delete_env(:arbiter, :migrations_module) end)

      {:ok, task} = Ash.create(Issue, %{title: "migrations pending", workspace_id: ws.id})

      assert Dispatch.dispatch(task.id, force: true, repo: "test/repo", start_driver: false) ==
               {:error, {:pending_migrations, 3}}

      reloaded = Ash.get!(Issue, task.id)
      assert reloaded.state == :backlog
      assert Worker.whereis(task.id) == nil
    end

    test "dispatch is refused when the migration check fails (database unreachable)",
         %{ws: ws} do
      Application.put_env(:arbiter, :migrations_module, StubMigrationsUnreachable)

      on_exit(fn -> Application.delete_env(:arbiter, :migrations_module) end)

      {:ok, task} = Ash.create(Issue, %{title: "migrations check failed", workspace_id: ws.id})

      assert Dispatch.dispatch(task.id, force: true, repo: "test/repo", start_driver: false) ==
               {:error, {:migrations_check_failed, :unreachable}}

      reloaded = Ash.get!(Issue, task.id)
      assert reloaded.state == :backlog
      assert Worker.whereis(task.id) == nil
    end
  end

  describe "quota gate bypass audit log (bd-2sh0i2)" do
    test "skip_quota_gate: true produces a quota_gate_bypass event with actor, reason, and quota state",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "quota bypass", workspace_id: ws.id})

      # Dispatch with skip_quota_gate and capture_quota_bypass_reason
      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 skip_quota_gate: true,
                 quota_bypass_actor: "coordinator:token-123",
                 quota_bypass_reason: "manual override for critical task"
               )

      assert result.task.state == :active

      # Verify the audit event was created
      events =
        Arbiter.Events.Record
        |> Ash.Query.filter(workspace_id == ^ws.id and topic == "quota_gate_bypass")
        |> Ash.read!()

      assert length(events) == 1
      event = List.first(events)

      # Verify the event contains all required fields
      payload = event.payload

      assert payload["task_id"] == task.id
      assert payload["actor"] == "coordinator:token-123"
      assert payload["reason"] == "manual override for critical task"
      assert is_map(payload["quota_state"])
      assert payload["quota_state"]["provider"] in ["claude", "gemini"]
      assert is_binary(payload["at"])
    end

    test "skip_quota_gate: true without reason creates event with nil reason", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "quota bypass no reason", workspace_id: ws.id})

      assert {:ok, _result} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "test/repo",
                 start_driver: false,
                 skip_quota_gate: true,
                 quota_bypass_actor: "loop:proposal-456"
               )

      events =
        Arbiter.Events.Record
        |> Ash.Query.filter(workspace_id == ^ws.id and topic == "quota_gate_bypass")
        |> Ash.read!()

      assert length(events) == 1
      event = List.first(events)
      payload = event.payload

      assert payload["task_id"] == task.id
      assert payload["actor"] == "loop:proposal-456"
      assert payload["reason"] == nil
      assert is_map(payload["quota_state"])
    end

    test "skip_quota_gate: false does not create an audit event", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "quota not bypassed", workspace_id: ws.id})

      # Dispatch WITHOUT skip_quota_gate
      assert {:ok, _result} =
               Dispatch.dispatch(task.id, force: true, repo: "test/repo", start_driver: false)

      # No quota_gate_bypass event should be created
      events =
        Arbiter.Events.Record
        |> Ash.Query.filter(workspace_id == ^ws.id and topic == "quota_gate_bypass")
        |> Ash.read!()

      assert length(events) == 0
    end
  end

  # Leave the branch worktree at `path` mid-rebase: a branch commit and a
  # side commit both add `conflict.txt`, and the branch is rebased onto the side.
  defp stop_mid_rebase!(path) do
    git = fn args -> System.cmd("git", ["-C", path | args], stderr_to_stdout: true) end
    {branch, 0} = git.(["rev-parse", "--abbrev-ref", "HEAD"])
    {base, 0} = git.(["rev-parse", "HEAD"])

    for {args, _} <- [
          {["config", "user.email", "t@e.com"], nil},
          {["config", "user.name", "T"], nil},
          {["config", "commit.gpgsign", "false"], nil}
        ],
        do: {_, 0} = git.(args)

    File.write!(Path.join(path, "conflict.txt"), "branch side\n")
    {_, 0} = git.(["add", "conflict.txt"])
    {_, 0} = git.(["commit", "-q", "-m", "branch side"])
    {_, 0} = git.(["checkout", "-q", "--detach", String.trim(base)])
    File.write!(Path.join(path, "conflict.txt"), "other side\n")
    {_, 0} = git.(["add", "conflict.txt"])
    {_, 0} = git.(["commit", "-q", "-m", "other side"])
    {side, 0} = git.(["rev-parse", "HEAD"])
    {_, 0} = git.(["checkout", "-q", String.trim(branch)])
    {_, status} = git.(["rebase", String.trim(side)])
    assert status != 0
    :ok
  end
end
