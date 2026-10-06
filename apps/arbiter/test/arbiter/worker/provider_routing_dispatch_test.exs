defmodule Arbiter.Worker.ProviderRoutingDispatchTest do
  @moduledoc """
  bd-40pzpj end to end: `routing.provider_selection: most_quota` on the live
  dispatch path.

    * AC5 — a new dispatch goes to the best-headroom account, and difficulty
      still picks the model within that family (D1 and D4, two families);
      off, nothing changes and nothing is recorded.
    * AC6 — the pin is reused by every implementer role (resume,
      resume_session, the ReviewGate fix round, the CI fix pass, the conflict
      resolver, the reconciler's resume), and an unavailable pin falls back
      at once, recorded.
    * AC7 — the run records the account, family, provider, per-candidate
      headroom, drops, fallback and override.
    * AC8 — a dispatch-time provider override wins and is recorded.

  Every agent binary is stubbed by `Arbiter.TestSandbox`.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  # bd-asxw4e: the tickets here are created in Backlog and dispatched straight
  # away, which a dispatch refuses unless forced — so these calls pass
  # `force: true`. What a dispatch admits is `DispatchEligibilityTest`'s.

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Board.{Autopilot, Snapshot}
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Dispatch}
  alias Arbiter.Workers.{Reconciler, Run}
  alias Arbiter.Workflows.MergeQueue.{ConflictResolver, FixPassDispatcher}
  alias Arbiter.Workflows.ReviewGateFixRoundDispatcher

  require Ash.Query

  @repo "pr/repo"

  setup do
    # bd-80ecol: the stub `claude` runs the real-agent path, whose dispatch
    # guard refuses a spawn with no credential of its own.
    claude_credential_env!()

    sandbox = TestSandbox.provision!("provider-routing")
    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{@repo => sandbox.repo})

    on_exit(fn ->
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
      TestSandbox.own_live_workers!(sandbox)
    end)

    %{sandbox: sandbox}
  end

  # ---- fixtures -------------------------------------------------------------

  defp workspace!(routing) do
    Ash.create!(Workspace, %{
      name: "prd-#{System.unique_integer([:positive])}",
      prefix: "prd",
      config: %{"routing" => routing}
    })
  end

  defp routed_workspace!(extra),
    do: workspace!(Map.merge(%{"provider_selection" => "most_quota"}, extra))

  defp account!(provider) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "#{provider}-#{System.unique_integer([:positive])}"
    })
  end

  defp allow!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: position
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp claude_used!(account, u5) do
    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: u5,
      reset_5h_at: ahead(9_000),
      status_5h: "allowed",
      utilization_7d: 0.0,
      reset_7d_at: ahead(302_400),
      status_7d: "allowed",
      captured_at: now()
    })
  end

  defp codex_used!(account, pct) do
    Ash.create!(CodexQuota, %{
      provider_account_id: account.id,
      provider: "codex",
      session_used_percent: pct,
      session_reset_at: ahead(3_600),
      weekly_used_percent: 0.0,
      weekly_reset_at: ahead(302_400),
      limit_reached: false,
      captured_at: now()
    })
  end

  # A workspace routing between a Claude and a Codex account, with Codex the
  # one with the most headroom (0.75 against Claude's 0.15).
  defp claude_and_codex!(routing \\ %{}) do
    ws = routed_workspace!(routing)
    claude = account!(:claude)
    codex = account!(:codex)
    allow!(ws, claude, 0)
    allow!(ws, codex, 1)
    claude_used!(claude, 0.70)
    codex_used!(codex, 10.0)
    %{ws: ws, claude: claude, codex: codex}
  end

  defp task!(ws, attrs \\ %{}),
    do: Ash.create!(Issue, Map.merge(%{title: "routed work", workspace_id: ws.id}, attrs))

  defp runs(task_id, kind) do
    Run
    |> Ash.Query.filter(base_task_id == ^task_id and kind == ^kind)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read!()
  end

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  # The stub logs its argv before anything else and then exits, so once the
  # agent's port is down its line in the sandbox log is complete.
  defp await_agent_exit(port) when is_port(port) do
    ref = Port.monitor(port)
    assert_receive {:DOWN, ^ref, :port, ^port, _}, 5_000
  end

  # Dispatch with a worktree, then stop the worker mid-work — the state every
  # resume role recovers from.
  defp dispatch_and_stop!(task, sandbox) do
    {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: @repo, start_driver: false)
    TestSandbox.own!(sandbox, first.worker_pid)
    :ok = Worker.fail(first.worker_pid, :token_exhausted)
    first
  end

  # ---- bd-dpv4vt: the grok opt-in survives provider routing ----------------------

  describe "routing.grok.enabled on a most_quota workspace" do
    test "a D1 ticket is routed to grok, not to the quota pick" do
      %{ws: ws} = claude_and_codex!(%{"grok" => %{"enabled" => true}})
      task = task!(ws, %{difficulty: 1})

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == "grok"
      assert latest_run(task.id).provider == "grok"
    end

    test "a D3 ticket still takes the quota pick" do
      %{ws: ws} = claude_and_codex!(%{"grok" => %{"enabled" => true}})
      task = task!(ws, %{difficulty: 3})

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == "codex"
    end

    test "off by default: a D1 ticket takes the quota pick" do
      %{ws: ws} = claude_and_codex!()
      task = task!(ws, %{difficulty: 1})

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == "codex"
    end
  end

  # ---- AC5 / AC7: a new dispatch -----------------------------------------------

  describe "a new dispatch with most_quota on" do
    test "goes to the best-headroom account, pins it and records the decision on the run" do
      %{ws: ws, claude: claude, codex: codex} = claude_and_codex!()
      task = task!(ws)

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == "codex"

      run = latest_run(task.id)
      assert run.provider == "codex"
      assert run.provider_account_id == codex.id
      assert run.model_family == "openai"

      decision = run.routing_decision
      assert decision["outcome"] == "selected"
      assert decision["role"] == "main"
      assert decision["account_slug"] == codex.slug

      assert [
               %{"account_slug" => first, "headroom" => h1},
               %{"account_slug" => second, "headroom" => h2}
             ] =
               decision["candidates"]

      assert {first, second} == {codex.slug, claude.slug}
      assert_in_delta h1, 0.75, 1.0e-3
      assert_in_delta h2, 0.15, 1.0e-3

      pinned = Ash.get!(Issue, task.id)
      assert pinned.implementer_account_id == codex.id
      assert pinned.implementer_family == "openai"
    end

    test "records dropped candidates with their reasons" do
      %{ws: ws, claude: claude} = claude_and_codex!()
      ProviderPool.mark_exhausted(:codex)
      task = task!(ws)

      {:ok, _} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      run = latest_run(task.id)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert [%{"reason" => "circuit_broken"}] = run.routing_decision["dropped"]
    end

    for {difficulty, codex_model, claude_model} <- [
          {1, "gpt-5.6-luna", "haiku"},
          {4, "gpt-5.6-terra", "opus"}
        ] do
      test "D#{difficulty}: the tier's model is spawned within whichever family wins", %{
        sandbox: sandbox
      } do
        # Codex has the headroom: D#{difficulty} spawns codex on the tier's Codex model.
        %{ws: ws} = claude_and_codex!(%{"policy" => "by_difficulty"})
        task = task!(ws, %{difficulty: unquote(difficulty)})

        {:ok, first} =
          Dispatch.dispatch(task.id,
            force: true,
            repo: @repo,
            start_driver: false,
            start_claude: true
          )

        TestSandbox.own!(sandbox, first.worker_pid)
        await_agent_exit(first.claude_port)

        codex_call = Enum.find(TestSandbox.calls(sandbox), &String.starts_with?(&1, "codex"))
        assert codex_call =~ "-m #{unquote(codex_model)}"

        # The other family: Claude has the headroom in a second workspace.
        ws2 = routed_workspace!(%{"policy" => "by_difficulty"})
        claude = account!(:claude)
        codex = account!(:codex)
        allow!(ws2, claude, 0)
        allow!(ws2, codex, 1)
        claude_used!(claude, 0.05)
        codex_used!(codex, 70.0)
        task2 = task!(ws2, %{difficulty: unquote(difficulty)})

        {:ok, second} =
          Dispatch.dispatch(task2.id,
            force: true,
            repo: @repo,
            start_driver: false,
            start_claude: true
          )

        TestSandbox.own!(sandbox, second.worker_pid)
        await_agent_exit(second.claude_port)

        # The stub logs claude's multi-line prompt, so `--model` (after it) is
        # on a later line; only claude takes `--model` (codex takes `-m`).
        assert File.read!(sandbox.log) =~ "--model #{unquote(claude_model)}"

        assert latest_run(task.id).routing_decision["model"] == unquote(codex_model)
        assert latest_run(task2.id).routing_decision["model"] == unquote(claude_model)
      end
    end
  end

  describe "with most_quota off (the default)" do
    test "nothing is routed, recorded or pinned" do
      ws = workspace!(%{})
      claude = account!(:claude)
      codex = account!(:codex)
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, 0.70)
      codex_used!(codex, 10.0)
      task = task!(ws)

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == nil
      run = latest_run(task.id)
      assert run.routing_decision == nil
      assert run.provider_account_id == nil
      assert run.model_family == nil
      assert Ash.get!(Issue, task.id).implementer_account_id == nil
    end
  end

  # ---- bd-3fvue3: Autopilot's promotion gate follows the routing --------------

  describe "Autopilot with most_quota on and the default provider held" do
    test "promotes a Ready card and dispatch routes it to the account with headroom" do
      for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)

      ws = routed_workspace!(%{})

      ws =
        Ash.update!(ws, %{config: Map.put(ws.config, "agent", %{"type" => ["claude", "codex"]})})

      # Claude (the workspace's default provider) is over its own 0.5 ceiling;
      # Codex has room. Each account has two slots, none in use.
      claude =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "claude-#{System.unique_integer([:positive])}",
          max_concurrent: 2,
          quota_config: %{"throttle_threshold" => 0.5}
        })

      codex =
        Ash.create!(ProviderAccount, %{
          provider: :codex,
          slug: "codex-#{System.unique_integer([:positive])}",
          max_concurrent: 2
        })

      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, 0.70)
      codex_used!(codex, 10.0)

      {:ok, created} =
        Ash.create(Issue, %{
          title: "promote me",
          workspace_id: ws.id,
          priority: 0,
          acceptance: "- routed by Autopilot"
        })

      {:ok, task} = Ash.update(created, %{}, action: :promote_to_ready)

      board = Snapshot.load(workspace_id: ws.id)
      assert board.quota == :ok
      assert board.slots_total >= 2

      test = self()

      {:ok, pid} =
        Autopilot.start_link(
          name: nil,
          interval_ms: :never,
          paused: false,
          topics: [],
          follow_up: false,
          snapshot: &Snapshot.load(Keyword.put(&1, :workspace_id, ws.id)),
          dispatch: fn id ->
            result = Dispatch.dispatch(id, repo: "r", start_driver: false)
            send(test, {:dispatched, id, result})
            result
          end
        )

      assert {:ok, promoted} = Autopilot.tick(pid)
      assert promoted == task.id
      assert_receive {:dispatched, promoted_id, {:ok, result}}
      assert promoted_id == task.id

      assert Worker.state(result.worker_pid).meta[:provider] == "codex"
      run = latest_run(task.id)
      assert run.provider_account_id == codex.id
      assert run.routing_decision["outcome"] == "selected"
      assert [%{"account_slug" => slug}] = run.routing_decision["dropped"]
      assert slug == claude.slug
    end
  end

  # ---- AC8 -------------------------------------------------------------------

  describe "a dispatch-time provider override" do
    test "wins over the headroom pick and is recorded as an override" do
      %{ws: ws, claude: claude} = claude_and_codex!()
      task = task!(ws)

      {:ok, _} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "r",
          start_driver: false,
          agent_type: :claude
        )

      run = latest_run(task.id)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert run.routing_decision["outcome"] == "override"
      assert run.routing_decision["override"] =~ "claude"
      assert Ash.get!(Issue, task.id).implementer_account_id == nil
    end
  end

  # ---- AC6: every implementer role reuses the pin ---------------------------

  describe "resume/2" do
    test "reuses the pin although another account now has more headroom", %{sandbox: sandbox} do
      %{ws: ws, claude: claude, codex: codex} = claude_and_codex!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)

      # Claude is now the idle one; the pin still wins.
      claude_used!(claude, 0.0)
      codex_used!(codex, 60.0)

      {:ok, result} = Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])
      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider == "codex"
      assert run.provider_account_id == codex.id
      assert run.routing_decision["outcome"] == "pinned"
      assert run.routing_decision["role"] == "resume"
    end

    test "falls back at once when the pin is unavailable, and records it", %{sandbox: sandbox} do
      %{ws: ws, claude: claude, codex: codex} = claude_and_codex!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)

      ProviderPool.mark_exhausted(:codex)

      {:ok, result} = Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])
      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert run.routing_decision["outcome"] == "fallback"
      assert run.provider_fallback =~ "pinned account codex:#{codex.slug} unavailable"
      assert run.provider_fallback =~ "circuit_broken"

      # The pin is kept for the next role.
      assert Ash.get!(Issue, task.id).implementer_account_id == codex.id
    end
  end

  describe "resume_session/2" do
    test "reuses the pin", %{sandbox: sandbox} do
      %{ws: ws, codex: codex} = claude_and_codex!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)

      Ash.create!(UsageEvent, %{
        task_id: task.id,
        workspace_id: ws.id,
        repo: @repo,
        step: :work,
        provider: "codex",
        session_id: "codex-session-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

      {:ok, result} =
        Dispatch.resume_session(task.id, start_driver: false, claude_command: ["true"])

      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider == "codex"
      assert run.provider_account_id == codex.id
      assert run.routing_decision["role"] == "resume_session"
      assert run.routing_decision["outcome"] == "pinned"
    end
  end

  describe "the ReviewGate implementer fix round" do
    test "reuses the pin", %{sandbox: sandbox} do
      %{ws: ws, codex: codex} = claude_and_codex!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)

      {:ok, result} =
        ReviewGateFixRoundDispatcher.dispatch(%{
          task_id: task.id,
          attempt: 1,
          verdict: :request_changes,
          claude_command: ["true"]
        })

      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider_account_id == codex.id
      assert run.routing_decision["role"] == "review_gate_fix_round"
      assert run.routing_decision["outcome"] == "pinned"
    end
  end

  describe "the ReviewGate's in-gate implementer round" do
    test "reuses the pin", %{sandbox: sandbox} do
      # The reviewer (claude) requests changes; the implementer round must go
      # to the pinned codex account, which commits a fix.
      write_stub = fn name, body ->
        path = Path.join(sandbox.bin, name)
        File.write!(path, "#!/bin/sh\n" <> body)
        File.chmod!(path, 0o755)
      end

      write_stub.("claude", """
      echo "claude $@" >> #{sandbox.log}
      echo "VERDICT: REQUEST_CHANGES"
      echo "- [high] feature.txt:1 needs fix"
      echo "arb done"
      exit 0
      """)

      write_stub.("codex", """
      echo "codex $@" >> #{sandbox.log}
      if [ -f feature.txt ]; then
        echo "fixed" >> feature.txt
        git add feature.txt
        git commit -q -m "implementer fix"
      fi
      echo "arb done"
      exit 0
      """)

      %{ws: ws, codex: codex} =
        claude_and_codex!()
        |> Map.update!(:ws, fn ws ->
          Ash.update!(
            ws,
            %{
              patch: %{
                "review_agent" => %{"type" => "claude"},
                "review" => %{"required" => true, "rounds" => 2}
              },
              unset_paths: []
            },
            action: :patch_config
          )
        end)

      task = task!(ws, %{issue_type: :feature})
      task = put_state!(task, :active)

      {:ok, task} =
        task
        |> Ash.Changeset.for_update(:pin_implementer, %{
          implementer_account_id: codex.id,
          implementer_family: "openai"
        })
        |> Ash.update()

      branch = "task-#{task.id}"
      :ok = TestSandbox.seed_branch!(sandbox, branch)
      {_, 0} = System.cmd("git", ["-C", sandbox.repo, "checkout", "-q", branch])
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "workers")

      {:ok, worker_pid} =
        Worker.start(
          task_id: task.id,
          repo: @repo,
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: sandbox.repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            review_rounds: 2,
            worktree_path: sandbox.repo,
            review_verdict_retries: 0,
            review_timeout_ms: 30_000
          }
        )

      TestSandbox.own!(sandbox, worker_pid)
      :ok = Worker.advance(worker_pid, :claude)
      send(worker_pid, {:__claude_session_done__, "arb done"})

      impl_task_id = "#{task.id}#review#impl1"

      # The round's worker records its run in `init/1`, before it announces
      # `:started`, and only stops once its agent has exited.
      assert_receive {:worker_lifecycle, :started, %{task_id: ^impl_task_id}}, 15_000

      run = latest_run(impl_task_id)
      assert run.provider == "codex"
      assert run.provider_account_id == codex.id
      assert run.routing_decision["role"] == "review_gate_implementer"
      assert run.routing_decision["outcome"] == "pinned"
      # …and the round actually spawned the codex CLI.
      assert_receive {:worker_lifecycle, :stopped, %{task_id: ^impl_task_id}}, 15_000
      assert Enum.any?(TestSandbox.calls(sandbox), &String.starts_with?(&1, "codex"))
    end
  end

  describe "the reconciler's resume" do
    test "reuses the pin", %{sandbox: sandbox} do
      %{ws: ws, codex: codex} = claude_and_codex!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)

      {:ok, result} =
        Reconciler.default_resume(Ash.get!(Issue, task.id), claude_command: ["true"])

      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider_account_id == codex.id
      assert run.routing_decision["role"] == "reconciler_resume"
      assert run.routing_decision["outcome"] == "pinned"
    end
  end

  describe "the CI fix pass and the conflict resolver" do
    setup %{sandbox: sandbox} do
      %{ws: ws} = accounts = claude_and_codex!()
      task = task!(ws, %{issue_type: :feature})
      # The main dispatch pins codex.
      {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)

      branch = BranchNamer.derive(task)
      :ok = TestSandbox.seed_branch!(sandbox, branch)

      context = %{
        task: Ash.get!(Issue, task.id),
        repo: @repo,
        repo_path: sandbox.repo,
        branch: branch,
        target_branch: "main",
        workspace: ws,
        start_claude: false
      }

      Map.merge(accounts, %{task: task, context: context})
    end

    test "the fix pass reuses the pin", %{
      task: task,
      context: context,
      codex: codex,
      sandbox: sandbox
    } do
      {:ok, %{worker_pid: pid}} = FixPassDispatcher.dispatch(context)
      TestSandbox.own!(sandbox, pid)

      # The worker writes its run row in `init/1`, so it exists by now.
      [run] = runs(task.id, :fix_pass)
      assert run.provider == "codex"
      assert run.provider_account_id == codex.id
      assert run.routing_decision["role"] == "fix_pass"
      assert run.routing_decision["outcome"] == "pinned"
    end

    test "the fix pass falls back when the pin is unavailable", %{
      task: task,
      context: context,
      claude: claude,
      sandbox: sandbox
    } do
      ProviderPool.mark_exhausted(:codex)

      {:ok, %{worker_pid: pid}} = FixPassDispatcher.dispatch(context)
      TestSandbox.own!(sandbox, pid)

      [run] = runs(task.id, :fix_pass)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert run.routing_decision["outcome"] == "fallback"
      assert run.provider_fallback =~ "circuit_broken"
    end

    test "the conflict resolver reuses the pin", %{
      task: task,
      context: context,
      codex: codex,
      sandbox: sandbox
    } do
      # Move main on, so the branch actually has something to resolve against.
      git = fn args ->
        {_, 0} = System.cmd("git", ["-C", sandbox.repo | args], stderr_to_stdout: true)
      end

      File.write!(Path.join(sandbox.repo, "other.txt"), "other\n")
      git.(["add", "other.txt"])
      git.(["commit", "-q", "-m", "other work"])
      git.(["push", "-q", "origin", "main"])

      {:ok, %{worker_pid: pid}} = ConflictResolver.dispatch(context)
      TestSandbox.own!(sandbox, pid)

      [run] = runs(task.id, :conflict)
      assert run.provider == "codex"
      assert run.provider_account_id == codex.id
      assert run.routing_decision["role"] == "conflict_resolver"
      assert run.routing_decision["outcome"] == "pinned"
    end
  end
end
