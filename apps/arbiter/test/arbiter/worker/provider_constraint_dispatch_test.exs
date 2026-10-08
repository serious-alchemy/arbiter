defmodule Arbiter.Worker.ProviderConstraintDispatchTest do
  @moduledoc """
  bd-13pqcp end to end: a ticket's provider constraint on every path that
  picks an implementer account. One test per path — each runs the real
  dispatcher against stubbed agent binaries (`Arbiter.TestSandbox`), with the
  excluded provider the *better* choice (more quota headroom, listed first)
  so only the constraint explains the outcome.

  The fixture is `claude` (headroom 0.15) and `codex` (headroom 0.75), codex
  excluded by the ticket.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderConstraint
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

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  @repo "pc/repo"
  @exclude_codex %{"exclude" => ["codex"]}

  setup do
    claude_credential_env!()

    sandbox = TestSandbox.provision!("provider-constraint")
    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{@repo => sandbox.repo})

    on_exit(fn ->
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
      TestSandbox.own_live_workers!(sandbox)
    end)

    %{sandbox: sandbox}
  end

  # ---- fixtures -------------------------------------------------------------

  defp workspace!(config) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "pcd-#{n}", prefix: "pcd#{n}", config: config})
  end

  defp account!(provider, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{provider}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
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

  # Routed by most_quota: codex has by far the most headroom.
  defp routed!(extra \\ %{}) do
    ws =
      workspace!(
        Map.merge(
          %{
            "agent" => %{"type" => ["codex", "claude"]},
            "routing" => %{"provider_selection" => "most_quota"}
          },
          extra
        )
      )

    claude = account!(:claude)
    codex = account!(:codex)
    allow!(ws, claude, 0)
    allow!(ws, codex, 1)
    claude_used!(claude, 0.70)
    codex_used!(codex, 10.0)
    %{ws: ws, claude: claude, codex: codex}
  end

  # Not routed (failover, today's default): the `agent.type` pool decides, and
  # lists codex first.
  defp failover! do
    ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
    %{ws: ws}
  end

  defp task!(ws, attrs \\ %{}),
    do: Ash.create!(Issue, Map.merge(%{title: "constrained work", workspace_id: ws.id}, attrs))

  defp constrain!(task, constraint),
    do: task.id |> then(&Ash.get!(Issue, &1)) |> Ash.update!(%{provider_constraint: constraint})

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

  defp no_runs?(task_id), do: Ash.Query.filter(Run, task_id == ^task_id) |> Ash.read!() == []

  # Dispatch with a worktree, then stop the worker mid-work — the state every
  # resume role recovers from. The first dispatch is unconstrained, so it goes
  # to the best account (codex); the constraint is set afterwards.
  defp dispatch_and_stop!(task, sandbox, extra \\ []) do
    {:ok, first} =
      Dispatch.dispatch(
        task.id,
        Keyword.merge([force: true, repo: @repo, start_driver: false], extra)
      )

    TestSandbox.own!(sandbox, first.worker_pid)
    :ok = Worker.fail(first.worker_pid, :token_exhausted)
    first
  end

  # Move main on, so the branch actually has something to resolve against.
  defp move_main_on!(sandbox) do
    git = fn args ->
      {_, 0} = System.cmd("git", ["-C", sandbox.repo | args], stderr_to_stdout: true)
    end

    File.write!(Path.join(sandbox.repo, "other.txt"), "other\n")
    git.(["add", "other.txt"])
    git.(["commit", "-q", "-m", "other work"])
    git.(["push", "-q", "origin", "main"])
  end

  # ---- the main dispatch ---------------------------------------------------------

  describe "sandbox.backend podman (#553)" do
    test "an unrouted pool with only gemini is held, not spawned" do
      ws = workspace!(%{"agent" => %{"type" => ["gemini"]}})
      task = task!(ws)

      assert {:error, {:sandbox_backend, :gemini, phrase}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "r",
                 start_driver: false,
                 security: %{"sandbox" => %{"backend" => "podman"}}
               )

      assert phrase =~ "gemini: not supported by sandbox.backend podman"
      assert no_runs?(task.id)
    end
  end

  describe "a new dispatch" do
    test "most_quota: the excluded account loses although it has the most headroom" do
      %{ws: ws, claude: claude} = routed!()
      task = task!(ws, %{provider_constraint: @exclude_codex})

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == "claude"
      run = latest_run(task.id)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert Enum.any?(run.routing_decision["dropped"], &(&1["reason"] == "provider_constraint"))
      assert Ash.get!(Issue, task.id).implementer_account_id == claude.id
    end

    test "most_quota: require picks the required provider although another has more headroom" do
      %{ws: ws, claude: claude} = routed!()
      task = task!(ws, %{provider_constraint: %{"require" => ["claude"]}})

      {:ok, _} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert latest_run(task.id).provider_account_id == claude.id
    end

    test "failover (routing off): the pool's first provider is skipped when it is excluded" do
      %{ws: ws} = failover!()
      task = task!(ws, %{provider_constraint: @exclude_codex})

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == "claude"
      assert latest_run(task.id).provider == "claude"
    end

    test "most_quota with no attached accounts: the pool's excluded head is skipped, not refused on every retry" do
      ws =
        workspace!(%{
          "agent" => %{"type" => ["codex", "claude"]},
          "routing" => %{"provider_selection" => "most_quota"}
        })

      task = task!(ws, %{provider_constraint: @exclude_codex})

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert Worker.state(result.worker_pid).meta[:provider] == "claude"
      assert latest_run(task.id).provider == "claude"
    end

    test "a caller-named provider that violates the constraint is refused, not run" do
      %{ws: ws} = routed!()
      task = task!(ws, %{provider_constraint: @exclude_codex})

      assert {:error, {:provider_constraint, :codex, phrase}} =
               Dispatch.dispatch(task.id,
                 force: true,
                 repo: "r",
                 start_driver: false,
                 agent_type: :codex
               )

      assert phrase =~ "held — provider constraint (exclude codex"
      assert no_runs?(task.id)
    end
  end

  # ---- no eligible account -> held, never a fallback -----------------------------------

  describe "no eligible account has capacity" do
    test "most_quota: the dispatch is held with a reason naming the constraint — it does not fall back to the excluded account" do
      %{ws: ws, claude: claude} = routed!()
      # Claude is the only allowed provider, and it is parked.
      Ash.update!(claude, %{enabled: false})
      task = task!(ws, %{provider_constraint: @exclude_codex})

      assert {:error, {:provider_constraint, nil, phrase}} =
               Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert phrase =~ "held — provider constraint (exclude codex"
      assert phrase =~ "claude:#{claude.slug} disabled"
      assert no_runs?(task.id)
      assert Worker.list_children() |> Enum.all?(&(&1.task_id != task.id))
    end

    test "failover: every pool provider excluded holds the dispatch" do
      %{ws: ws} = failover!()
      task = task!(ws, %{provider_constraint: %{"exclude" => ["codex", "claude"]}})

      assert {:error, {:provider_constraint, nil, phrase}} =
               Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      assert phrase =~ "held — provider constraint (exclude codex, claude"
      assert no_runs?(task.id)
    end

    test "the card says so, and Autopilot plans past it to the next ticket" do
      %{ws: ws} = failover!()

      stuck =
        task!(ws, %{
          priority: 0,
          acceptance: "- x",
          provider_constraint: %{"exclude" => ["codex", "claude"]}
        })

      other = task!(ws, %{priority: 1, acceptance: "- y"})
      {:ok, stuck} = Ash.update(stuck, %{}, action: :promote_to_ready)
      {:ok, other} = Ash.update(other, %{}, action: :promote_to_ready)

      board = Snapshot.load(workspace_id: ws.id)
      entries = Map.new(board.ready, &{&1.card.id, &1})
      assert %{state: :blocked, reason: reason} = entries[stuck.id]
      assert reason =~ "provider constraint (exclude codex, claude"
      assert %{state: :next} = entries[other.id]

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
            send(test, {:dispatched, id})
            {:error, :stubbed}
          end
        )

      assert {:error, :stubbed} = Autopilot.tick(pid)
      assert_receive {:dispatched, dispatched}
      assert dispatched == other.id
      refute_receive {:dispatched, _}
    end
  end

  # ---- resume and the follow-up roles ---------------------------------------------------

  describe "resume/2" do
    test "most_quota: a pin on the now-excluded account falls back to an allowed one", %{
      sandbox: sandbox
    } do
      %{ws: ws, claude: claude, codex: codex} = routed!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)
      assert Ash.get!(Issue, task.id).implementer_account_id == codex.id
      constrain!(task, @exclude_codex)

      {:ok, result} = Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])
      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert run.routing_decision["outcome"] == "fallback"
      assert run.provider_fallback =~ "provider_constraint"
    end

    test "failover: the authoring provider, now excluded, is not resumed on", %{sandbox: sandbox} do
      %{ws: ws} = failover!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox, agent_type: :codex)
      assert latest_run(task.id).provider == "codex"
      constrain!(task, @exclude_codex)

      {:ok, result} = Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])
      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider == "claude"
      assert run.provider_fallback =~ "provider constraint"
    end

    test "with no allowed provider left the resume is refused", %{sandbox: sandbox} do
      %{ws: ws} = failover!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)
      constrain!(task, %{"exclude" => ["codex", "claude", "gemini"]})

      assert {:error, {:provider_constraint, _provider, phrase}} =
               Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])

      assert phrase =~ "held — provider constraint"
    end
  end

  describe "resume_session/2" do
    test "does not continue a session that belongs to the excluded provider", %{
      sandbox: sandbox
    } do
      %{ws: ws, claude: claude} = routed!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)
      constrain!(task, @exclude_codex)

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
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
    end

    test "failover: the session's own provider is passed over when it is excluded", %{
      sandbox: sandbox
    } do
      %{ws: ws} = failover!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)
      constrain!(task, @exclude_codex)

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
      assert latest_run(task.id).provider == "claude"
    end
  end

  describe "the ReviewGate implementer fix round" do
    test "leaves the excluded pin", %{sandbox: sandbox} do
      %{ws: ws, claude: claude} = routed!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)
      constrain!(task, @exclude_codex)

      {:ok, result} =
        ReviewGateFixRoundDispatcher.dispatch(%{
          task_id: task.id,
          attempt: 1,
          verdict: :request_changes,
          claude_command: ["true"]
        })

      TestSandbox.own!(sandbox, result.worker_pid)
      assert latest_run(task.id).provider_account_id == claude.id
    end
  end

  describe "the reconciler's resume" do
    test "leaves the excluded pin", %{sandbox: sandbox} do
      %{ws: ws, claude: claude} = routed!()
      task = task!(ws)
      dispatch_and_stop!(task, sandbox)
      constrain!(task, @exclude_codex)

      {:ok, result} =
        Reconciler.default_resume(Ash.get!(Issue, task.id), claude_command: ["true"])

      TestSandbox.own!(sandbox, result.worker_pid)
      assert latest_run(task.id).provider_account_id == claude.id
    end
  end

  describe "the CI fix pass and the conflict resolver" do
    setup %{sandbox: sandbox} do
      %{ws: ws} = accounts = routed!()
      task = task!(ws, %{issue_type: :feature})
      # The main dispatch pins codex; the constraint arrives afterwards.
      {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)
      constrain!(task, @exclude_codex)

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

    test "the fix pass runs on the allowed account", %{
      task: task,
      context: context,
      claude: claude,
      sandbox: sandbox
    } do
      {:ok, %{worker_pid: pid}} = FixPassDispatcher.dispatch(context)
      TestSandbox.own!(sandbox, pid)

      [run] = runs(task.id, :fix_pass)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
    end

    test "the fix pass is refused when nothing allowed is left — it never runs on the excluded provider",
         %{task: task, context: context} do
      constrain!(task, %{"exclude" => ["codex", "claude", "gemini"]})

      assert {:error, {:provider_constraint, _provider, phrase}} =
               FixPassDispatcher.dispatch(%{context | task: Ash.get!(Issue, task.id)})

      assert phrase =~ "held — provider constraint"
      assert runs(task.id, :fix_pass) == []
    end

    test "the conflict resolver runs on the allowed account", %{
      task: task,
      context: context,
      claude: claude,
      sandbox: sandbox
    } do
      move_main_on!(sandbox)

      {:ok, %{worker_pid: pid}} = ConflictResolver.dispatch(context)
      TestSandbox.own!(sandbox, pid)

      [run] = runs(task.id, :conflict)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
    end

    test "the conflict resolver is refused when nothing allowed is left", %{
      task: task,
      context: context,
      sandbox: sandbox
    } do
      move_main_on!(sandbox)
      constrain!(task, %{"exclude" => ["codex", "claude", "gemini"]})

      assert {:error, {:provider_constraint, _provider, _phrase}} =
               ConflictResolver.dispatch(%{context | task: Ash.get!(Issue, task.id)})

      assert runs(task.id, :conflict) == []
    end
  end

  # ---- unconstrained tickets route exactly as today ----------------------------------------

  describe "a ticket without a constraint" do
    test "most_quota: still goes to the best-headroom account (codex)" do
      %{ws: ws, codex: codex} = routed!()
      task = task!(ws)

      {:ok, _} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      run = latest_run(task.id)
      assert run.provider_account_id == codex.id
      assert run.routing_decision["outcome"] == "selected"
      refute Map.has_key?(run.routing_decision, "constraint")
    end

    test "failover: still the pool's first provider (codex), with nothing recorded" do
      %{ws: ws} = failover!()
      task = task!(ws)

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", start_driver: false)

      # Nothing routed, recorded or pinned: the pool picks, as it always did.
      assert Worker.state(result.worker_pid).meta[:provider] == nil
      assert latest_run(task.id).routing_decision == nil
      assert Ash.get!(Issue, task.id).implementer_account_id == nil
    end

    test "an empty constraint map is no constraint" do
      %{ws: ws} = failover!()
      task = task!(ws, %{provider_constraint: %{}})
      assert task.provider_constraint == nil
      assert ProviderConstraint.from(task) == nil
    end
  end

  describe "the ReviewGate's in-gate implementer round" do
    test "runs on the allowed account, not the excluded pin", %{sandbox: sandbox} do
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

      %{ws: ws, claude: claude, codex: codex} =
        routed!()
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

      task = task!(ws, %{issue_type: :feature, provider_constraint: @exclude_codex})
      task = put_state!(task, :active)

      # Pinned to the account the ticket now excludes.
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
      assert_receive {:worker_lifecycle, :started, %{task_id: ^impl_task_id}}, 15_000

      run = latest_run(impl_task_id)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert run.routing_decision["role"] == "review_gate_implementer"
      assert run.routing_decision["outcome"] == "fallback"

      assert_receive {:worker_lifecycle, :stopped, %{task_id: ^impl_task_id}}, 15_000
      refute Enum.any?(TestSandbox.calls(sandbox), &String.starts_with?(&1, "codex"))
    end
  end
end
