defmodule Arbiter.WorkerRunPersistenceTest do
  # DataCase (async: false → shared sandbox) so the worker process, which
  # runs under the DynamicSupervisor, can reach the same DB connection when
  # it writes / updates the Run row.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Workers.Run
  require Ash.Query

  @fixture Path.expand("../fixtures/echo_with_done.sh", __DIR__)

  defp runs_for(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  test "starting a worker creates a :starting Run row, kept in step with the worker" do
    task_id = "bd-runstart-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    [run] = runs_for(task_id)
    assert run.state == :starting
    assert run.outcome == nil
    assert run.kind == :implement
    assert run.repo == "arbiter"
    assert run.workspace_id == "ws-runs"
    assert %DateTime{} = run.started_at
    assert run.completed_at == nil

    # The row follows the worker: driving → :working, a question → :waiting.
    :ok = Worker.advance(pid, :implement)
    assert [%{state: :working, outcome: nil}] = runs_for(task_id)

    :ok = Worker.await(pid, :question)
    assert [%{state: :waiting, outcome: nil}] = runs_for(task_id)

    :ok = Worker.resume(pid)
    assert [%{state: :working, outcome: nil}] = runs_for(task_id)
  end

  test "kind is derived from meta (reviewer/implementer/main)" do
    main_id = "bd-typemain-#{System.unique_integer([:positive])}"
    review_id = "bd-typereview-#{System.unique_integer([:positive])}"
    impl_id = "bd-typeimpl-#{System.unique_integer([:positive])}"
    revonly_id = "bd-typerevonly-#{System.unique_integer([:positive])}"

    {:ok, main} = Worker.start(task_id: main_id, repo: "arbiter", workspace_id: "ws-runs")

    {:ok, review} =
      Worker.start(
        task_id: review_id,
        repo: "arbiter",
        workspace_id: "ws-runs",
        meta: %{role: :reviewer}
      )

    {:ok, impl} =
      Worker.start(
        task_id: impl_id,
        repo: "arbiter",
        workspace_id: "ws-runs",
        meta: %{role: :implementer}
      )

    {:ok, revonly} =
      Worker.start(
        task_id: revonly_id,
        repo: "arbiter",
        workspace_id: "ws-runs",
        meta: %{review_only: true}
      )

    on_exit(fn ->
      for pid <- [main, review, impl, revonly],
          Process.alive?(pid),
          do: GenServer.stop(pid, :normal)
    end)

    assert [%{kind: :implement}] = runs_for(main_id)
    assert [%{kind: :review}] = runs_for(review_id)
    assert [%{kind: :implement, role: "impl"}] = runs_for(impl_id)
    assert [%{kind: :review}] = runs_for(revonly_id)
  end

  test "the resolved model is persisted onto the Run row on completion" do
    task_id = "bd-runmodel-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :model, "claude-opus-4-8")
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.outcome == :succeeded
    assert run.model == "claude-opus-4-8"
  end

  test "model backfilled onto Run row when session exit event arrives after terminal transition" do
    # Regression: the race condition where fail_now fires before the stream-json
    # init event is processed. The worker terminates with model=nil in meta; then
    # the port's exit handler calls sync_session_meta which now finds the model
    # and patches the existing DB row rather than leaving it NULL.
    #
    # We reproduce it by: failing the worker first (no model in meta), THEN
    # opening a ClaudeSession with a stream-json fixture that emits an init event.
    # Port data arrives after the terminal transition, so sync_session_meta fires
    # on an already-failed worker — which is the exact race the backfill covers.
    task_id = "bd-runmodelrace-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    # Fail the worker with no model in meta (simulates fail_now before session exit).
    :ok = Worker.advance(pid, :implement)
    :ok = Worker.fail(pid, :uncommitted_at_completion)

    [pre_run] = runs_for(task_id)
    assert pre_run.outcome == :failed
    assert pre_run.model == nil

    # Now open a session AFTER the fail. The port will output a stream-json init
    # event carrying the model; sync_session_meta will detect the model arriving
    # on a terminal worker and backfill the DB row.
    cwd = System.tmp_dir!()

    init_event =
      Jason.encode!(%{
        "type" => "system",
        "subtype" => "init",
        "model" => "claude-haiku-4-5",
        "session_id" => "sess-backfill"
      })

    events_path = Path.join(cwd, "backfill-events-#{System.unique_integer([:positive])}.jsonl")
    File.write!(events_path, init_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", events_path]
      )

    # Wait for the port to exit and the backfill DB write to land.
    :ok =
      wait_until(
        fn ->
          case runs_for(task_id) do
            [%{model: m}] when not is_nil(m) -> true
            _ -> false
          end
        end,
        2000
      )

    [run] = runs_for(task_id)
    assert run.outcome == :failed
    assert run.model == "claude-haiku-4-5"
  end

  # G18: a harness version change resets a subject's promotion clock, so each run
  # records the agent CLI's version — here, the one Claude's `init` event reports.
  test "the harness version the session's init event reports lands on the Run row" do
    task_id = "bd-runharness-#{System.unique_integer([:positive])}"
    cwd = System.tmp_dir!()

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    init_event =
      Jason.encode!(%{
        "type" => "system",
        "subtype" => "init",
        "model" => "claude-opus-5",
        "session_id" => "sess-harness-#{task_id}",
        "claude_code_version" => "2.1.296"
      })

    events_path = Path.join(cwd, "harness-events-#{System.unique_integer([:positive])}.jsonl")
    File.write!(events_path, init_event <> "\n")
    on_exit(fn -> File.rm(events_path) end)

    {:ok, _port} =
      ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["cat", events_path])

    :ok =
      wait_until(
        fn -> match?([%{session_id: "sess-harness-" <> _}], runs_for(task_id)) end,
        3_000
      )

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.harness_version == "2.1.296"
  end

  @tag :tmp_dir
  test "a host-local spawn whose stream reports no version records the host binary's", %{
    tmp_dir: dir
  } do
    task_id = "bd-runhostver-#{System.unique_integer([:positive])}"
    fake = Path.join(dir, "agy")
    File.write!(fake, "#!/bin/sh\necho 'agy version 1.2.16'\n")
    File.chmod!(fake, 0o755)

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: dir,
        provider: "gemini",
        command: ["true"],
        harness_probe: [executable: fake, probe: true]
      )

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.harness_version == "1.2.16"
  end

  test "difficulty_at_dispatch is captured from meta at Run creation (bd-dzz6ly)" do
    task_id = "bd-rundiff-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(
        task_id: task_id,
        repo: "arbiter",
        workspace_id: "ws-runs",
        meta: %{difficulty_at_dispatch: 1}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    [run] = runs_for(task_id)
    assert run.difficulty_at_dispatch == 1
  end

  test "difficulty_at_dispatch is nil when the dispatch carried no difficulty" do
    task_id = "bd-rundiffnil-#{System.unique_integer([:positive])}"

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    [run] = runs_for(task_id)
    assert run.difficulty_at_dispatch == nil
  end

  test "reporting :run_provenance backfills resolved_skills/routing/tier/thinking/orders digest onto the Run row (bd-dzz6ly)" do
    task_id = "bd-runprov-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    provenance = %{
      resolved_skills: [
        %{
          "name" => "tdd",
          "activation_mode" => "always_on",
          "skill_version" => "2026-01-01T00:00:00Z"
        }
      ],
      standing_orders_digest: String.duplicate("a", 64),
      routing_policy: "by_difficulty",
      model_tier: "premium",
      thinking: "high"
    }

    :ok = Worker.report(pid, :run_provenance, provenance)

    [run] = runs_for(task_id)

    assert run.resolved_skills == [
             %{
               "name" => "tdd",
               "activation_mode" => "always_on",
               "skill_version" => "2026-01-01T00:00:00Z"
             }
           ]

    assert run.standing_orders_digest == String.duplicate("a", 64)
    assert run.routing_policy == "by_difficulty"
    assert run.model_tier == "premium"
    assert run.thinking == "high"
  end

  test "lifecycle broadcasts do not carry meta.output_lines (bd-81vbzg)" do
    task_id = "bd-lcpayload-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "workers")

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :output_lines, ["line one", "line two"])

    assert_receive {:worker_lifecycle, :started, %{task_id: ^task_id, meta: started_meta}}
    refute Map.has_key?(started_meta, :output_lines)

    GenServer.stop(pid, :normal)
    assert_receive {:worker_lifecycle, :stopped, %{task_id: ^task_id, meta: stopped_meta}}, 5_000
    refute Map.has_key?(stopped_meta, :output_lines)
  end

  test "completing a worker finishes the Run row :succeeded with output_lines" do
    task_id = "bd-runcomp-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :output_lines, ["line one", "line two"])
    :ok = Worker.report(pid, :exit_status, 0)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.state == :finished
    assert run.outcome == :succeeded
    assert run.exit_code == 0
    assert run.output_lines == ["line one", "line two"]
    assert %DateTime{} = run.completed_at
  end

  test "claude __claude_session_done__ also finishes the row :succeeded" do
    task_id = "bd-runclaude-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :run_claude)
    send(pid, {:__claude_session_done__, "arb done"})

    # Wait briefly for the cast-like handle_info to land + write.
    :ok =
      wait_until(fn -> match?([%{state: :finished, outcome: :succeeded}], runs_for(task_id)) end)

    [run] = runs_for(task_id)
    assert run.outcome == :succeeded
  end

  test "terminate from an unfinished state finishes the Run row :succeeded" do
    # Mirror the REAL worker-completion teardown: a claude-driven worker sits
    # at an unfinished state (:working) and is torn down by the task `:close`
    # after-action (StopWorker -> Worker.stop -> terminate/2) WITHOUT any
    # explicit Worker.complete/2 ever firing. Before bd-39q7sk this left the
    # row stuck live until the next boot reconcile.
    task_id = "bd-runterm-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    :ok = Worker.advance(pid, :run_claude)
    :ok = Worker.report(pid, :output_lines, ["working", "arb done"])
    :ok = Worker.report(pid, :exit_status, 0)

    [running] = runs_for(task_id)
    assert running.state == :working
    assert running.completed_at == nil

    # Synchronous stop: GenServer.stop blocks until terminate/2 returns, so the
    # row write has landed by the time this returns.
    :ok = Worker.stop(pid, :normal)

    [run] = runs_for(task_id)
    assert run.state == :finished
    assert run.outcome == :succeeded
    assert %DateTime{} = run.completed_at
    assert run.exit_code == 0
    assert run.output_lines == ["working", "arb done"]
  end

  for provider <- ["claude", "agy"] do
    test "an operator stop of a live #{provider} run records :interrupted/operator_stop, not :succeeded" do
      task_id = "bd-opstop-#{unquote(provider)}-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Worker.start(
          task_id: task_id,
          repo: "arbiter",
          workspace_id: "ws-runs",
          meta: %{provider: unquote(provider)}
        )

      :ok = Worker.advance(pid, :run_claude)
      assert [%{state: :working}] = runs_for(task_id)

      :ok = Worker.operator_stop(task_id)

      [run] = runs_for(task_id)
      assert run.state == :finished
      assert run.outcome == :interrupted
      assert run.failure_reason == "operator_stop"
      assert %DateTime{} = run.completed_at
    end
  end

  test "an operator-stopped (:interrupted) run is not counted completed or failed by Loop analysis" do
    row = fn outcome ->
      %{
        task_id: "bd-t",
        kind: :implement,
        role: "base",
        outcome: outcome,
        cost_usd: 0.0,
        weighted_tokens: 0,
        window_share_5h: 0.0,
        converged?: outcome == :succeeded,
        difficulty: nil,
        difficulty_source: :issue,
        model: "m",
        model_tier: nil,
        rejected?: false,
        transcript_read?: false,
        failure_reason: nil,
        stop_category: nil,
        repo: "r",
        title: "t",
        state: :finished,
        max_round: 1,
        findings: [],
        terminal_lines: []
      }
    end

    report =
      Arbiter.Loop.Analysis.build_report([row.(:interrupted), row.(:succeeded)], label: "t")

    assert report.totals.completed == 1
    assert report.totals.failed == 0
    assert report.totals.runs == 2
  end

  test "terminate after an explicit completion does not double-write the Run row" do
    # complete_now/2 already stamped the row; terminate/2 must no-op so it does
    # not clobber the completed_at / exit fields written at completion time.
    task_id = "bd-runterm2-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :exit_status, 0)
    :ok = Worker.complete(pid, :done)

    [completed] = runs_for(task_id)
    assert completed.outcome == :succeeded
    first_completed_at = completed.completed_at

    :ok = Worker.stop(pid, :normal)

    [run] = runs_for(task_id)
    assert run.outcome == :succeeded
    assert run.completed_at == first_completed_at
  end

  test "failing a worker finishes the Run row :failed with failure_reason" do
    task_id = "bd-runfail-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :verify)
    :ok = Worker.fail(pid, :max_ticks_exceeded)

    [run] = runs_for(task_id)
    assert run.state == :finished
    assert run.outcome == :failed
    assert run.failure_reason == ":max_ticks_exceeded"
    assert %DateTime{} = run.completed_at
  end

  test "ClaudeSession output lines flow end-to-end into the Run row on completion" do
    # Exercises the full path from port data through the worker's session
    # tracking, sync_session_meta, and record_run_finished into the DB, so that
    # `arb worker show <task-id>` on a closed task shows real output.
    task_id = "bd-sessionlines-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        command: [@fixture]
      )

    # Wait for the fixture's "arb done" to land and the Run row to be stamped.
    :ok =
      wait_until(
        fn -> match?([%{state: :finished, outcome: :succeeded}], runs_for(task_id)) end,
        2000
      )

    [run] = runs_for(task_id)
    assert run.outcome == :succeeded
    assert %DateTime{} = run.completed_at
    # The fixture emits these lines; they must survive into the DB row.
    assert "doing important work" in run.output_lines
    assert "arb done" in run.output_lines
    # Lines appear oldest-first, so "doing important work" precedes "arb done".
    assert Enum.find_index(run.output_lines, &(&1 == "doing important work")) <
             Enum.find_index(run.output_lines, &(&1 == "arb done"))
  end

  test "output_lines capped to last #{500} lines when session is very chatty" do
    # Verifies that a session producing more than @max_output_lines (500) lines
    # only persists the last 500 rather than bloating the row indefinitely.
    task_id = "bd-linesclip-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    # Inject 600 lines directly via report/3 (same mechanism sync_session_meta
    # uses) so we don't need a subprocess fixture that produces 600+ lines.
    lines = Enum.map(1..600, &"line #{&1}")
    :ok = Worker.advance(pid, :implement)
    :ok = Worker.report(pid, :output_lines, lines)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert length(run.output_lines) == 500
    # The LAST 500 lines (101–600) should be retained, not the first 500.
    assert "line 101" in run.output_lines
    assert "line 600" in run.output_lines
    refute "line 100" in run.output_lines
  end

  test "the terminal result event's structured outcome lands on the Run row (bd-9rdwe4)" do
    task_id = "bd-runresult-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    cwd = System.tmp_dir!()

    result_event =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "all done, tests green"
      })

    events_path = Path.join(cwd, "result-events-#{System.unique_integer([:positive])}.jsonl")
    File.write!(events_path, result_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["cat", events_path])

    # The result event lands on session meta asynchronously (port data); wait
    # for it before completing the worker, mirroring how a real driver would
    # only close the run out after the terminal event actually arrived.
    :ok =
      wait_until(fn ->
        case Worker.state(pid) do
          %{meta: %{result_subtype: "success"}} -> true
          _ -> false
        end
      end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.result_subtype == "success"
    assert run.result_is_error == false
    assert run.result_message == "all done, tests green"
  end

  # bd-apwfmy (Definition of done, item 1): StopReason already classifies the
  # death typed, with the whole captured output in hand, and Arbiter then kept
  # only the English sentence it renders. Persist the category itself so the
  # loop stops re-deriving it with a regex over the transcript tail.
  test "a stopped worker's typed StopReason category lands on the Run row" do
    task_id = "bd-runstop-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :claude)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        command: ["sh", "-c", "echo 'API Error: 401 Invalid authentication credentials'; exit 1"]
      )

    :ok =
      wait_until(
        fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end,
        3_000
      )

    [run] = runs_for(task_id)
    assert run.outcome == :failed
    assert run.stop_category == "auth_expired"
    # The prose label is untouched — the typed column is additive.
    assert is_binary(run.failure_reason)
  end

  test "a cleanly completed run records no stop_category" do
    task_id = "bd-runnostop-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.outcome == :succeeded
    assert run.stop_category == nil
  end

  test "run completion archives the agent's own session JSONL (bd-db0p38)" do
    # End-to-end over the real path: the CLAUDE_CONFIG_DIR the session spawns
    # under lands on the Run row, the stream's `init` event supplies the
    # session id, and `record_run_finished/1` copies the CLI's own JSONL into
    # the durable log root before the CLI can prune it at ~21 days.
    task_id = "bd-archivejsonl-#{System.unique_integer([:positive])}"
    uniq = System.unique_integer([:positive])

    root = Path.join(System.tmp_dir!(), "run-archive-root-#{uniq}")
    cfg = Path.join(System.tmp_dir!(), "run-archive-cfg-#{uniq}")
    cwd = Path.join(System.tmp_dir!(), "run-archive-cwd-#{uniq}")
    File.mkdir_p!(cwd)

    session_id = "aaaaaaaa-bbbb-cccc-dddd-#{String.pad_leading("#{uniq}", 12, "0")}"

    # Seed the CLI's on-disk session file exactly where `locate/2` globs.
    slug = Arbiter.Usage.ClaudeSessionFile.project_slug(cwd)
    proj = Path.join([cfg, "projects", slug])
    File.mkdir_p!(proj)

    File.write!(
      Path.join(proj, session_id <> ".jsonl"),
      Jason.encode!(%{"type" => "assistant", "thinking" => "ground truth"}) <> "\n"
    )

    prev_root = Application.get_env(:arbiter, :output_log_root)
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(cfg)
      File.rm_rf(cwd)

      if prev_root,
        do: Application.put_env(:arbiter, :output_log_root, prev_root),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    init_event =
      Jason.encode!(%{
        "type" => "system",
        "subtype" => "init",
        "session_id" => session_id,
        "model" => "claude-opus-5"
      })

    events_path = Path.join(cwd, "init-events.jsonl")
    File.write!(events_path, init_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        env: [{"CLAUDE_CONFIG_DIR", cfg}],
        command: ["cat", events_path]
      )

    # The init event lands on the Run row asynchronously; wait for it before
    # completing, so the archive has coordinates to work from.
    :ok = wait_until(fn -> match?([%{session_id: ^session_id}], runs_for(task_id)) end, 3_000)

    :ok = Worker.advance(pid, :implement)
    :ok = Worker.complete(pid, :done)

    [run] = runs_for(task_id)
    assert run.config_dir == cfg

    assert Arbiter.Worker.SessionArchive.archived?(run.id)
    assert {:ok, body} = Arbiter.Worker.SessionArchive.read(run.id)
    assert body =~ "ground truth"
  end

  test "a gemini spawn records the injected HOME as config_dir, not CLAUDE_CONFIG_DIR (bd-6nupvc T9)" do
    task_id = "bd-agyconfigdir-#{System.unique_integer([:positive])}"
    uniq = System.unique_integer([:positive])

    cwd = Path.join(System.tmp_dir!(), "agy-cfgdir-cwd-#{uniq}")
    File.mkdir_p!(cwd)
    home = Path.join(System.tmp_dir!(), "agy-cfgdir-home-#{uniq}")

    on_exit(fn ->
      File.rm_rf(cwd)
      File.rm_rf(home)
    end)

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        provider: "gemini",
        env: [{"HOME", home}],
        command: ["true"]
      )

    [run] = runs_for(task_id)
    assert run.config_dir == home
  end

  test "a HOME earlier in the spawn's env list does not win over a later one (bd-6nupvc T9)" do
    # `env_pairs/3` appends caller/agent env AFTER the workspace's own vars,
    # and the OS applies the list last-wins — so `effective_config_dir/2`
    # must scan from the end, not take the first HOME it finds.
    task_id = "bd-agyconfigdirorder-#{System.unique_integer([:positive])}"
    uniq = System.unique_integer([:positive])

    cwd = Path.join(System.tmp_dir!(), "agy-cfgdirorder-cwd-#{uniq}")
    File.mkdir_p!(cwd)
    earlier_home = Path.join(System.tmp_dir!(), "agy-cfgdirorder-earlier-#{uniq}")
    later_home = Path.join(System.tmp_dir!(), "agy-cfgdirorder-later-#{uniq}")

    on_exit(fn ->
      File.rm_rf(cwd)
      File.rm_rf(earlier_home)
      File.rm_rf(later_home)
    end)

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        provider: "gemini",
        env: [{"HOME", earlier_home}, {"HOME", later_home}],
        command: ["true"]
      )

    [run] = runs_for(task_id)
    assert run.config_dir == later_home
  end

  defp wait_until(fun, timeout_ms \\ 500, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline, step_ms)
  end

  defp do_wait(fun, deadline, step_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until/3 timed out")
      else
        Process.sleep(step_ms)
        do_wait(fun, deadline, step_ms)
      end
    end
  end
end
