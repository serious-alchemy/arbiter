defmodule Arbiter.Worker.GuardrailDispatchTest do
  @moduledoc """
  bd-atll60 (G13) end to end: guardrail eligibility is a hard gate on every
  path that picks an implementer provider, not just the quota-routed one
  (`docs/design/guardrail-profiles.md` §5.7, §9 G13). Each test runs the real
  dispatcher against stubbed agent binaries (`Arbiter.TestSandbox`), with the
  ineligible provider the *better* choice (listed first, more quota headroom)
  so only the guardrail explains the outcome.

  Rules: `claude` is `privileged`, `codex` is `quarantine` (a D1 ceiling).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Messages.Message
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.DispatchQueue

  require Ash.Query

  @repo "gd/repo"
  @rules [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "codex"}, tier: :quarantine}
  ]

  setup do
    claude_credential_env!()
    put_app_env(:arbiter, :guardrail_subject_rules, @rules)

    sandbox = TestSandbox.provision!("guardrail-dispatch")
    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{@repo => sandbox.repo})

    on_exit(fn ->
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
      TestSandbox.own_live_workers!(sandbox)
    end)

    %{sandbox: sandbox}
  end

  defp workspace!(config) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "gdd-#{n}", prefix: "gdd#{n}", config: config})
  end

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

  defp task!(ws, attrs),
    do: Ash.create!(Issue, Map.merge(%{title: "guarded work", workspace_id: ws.id}, attrs))

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  defp no_runs?(task_id), do: Ash.Query.filter(Run, task_id == ^task_id) |> Ash.read!() == []

  defp escalations(task_id, kind) do
    Message
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == task_id and &1.escalation_kind == kind))
  end

  defp dispatch(task, extra \\ []) do
    Dispatch.dispatch(
      task.id,
      Keyword.merge([force: true, repo: "r", start_driver: false], extra)
    )
  end

  describe "the legacy agent.type pool (routing off)" do
    test "skips an ineligible head of the pool for an eligible provider" do
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
      task = task!(ws, %{difficulty: 3})

      {:ok, result} = dispatch(task)

      assert Worker.state(result.worker_pid).meta[:provider] == "claude"
      assert latest_run(task.id).provider == "claude"
    end

    test "an eligible head of the pool is still taken (the ticket is within its ceiling)" do
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
      task = task!(ws, %{difficulty: 1})

      {:ok, result} = dispatch(task)

      # The pool's head runs as the default: nothing swapped it for claude.
      refute latest_run(result.task.id).provider == "claude"
      refute Worker.state(result.worker_pid).meta[:provider] == "claude"
    end

    test "with the whole pool ineligible the dispatch is refused and the coordinator is told" do
      ws = workspace!(%{"agent" => %{"type" => ["codex"]}})
      task = task!(ws, %{difficulty: 3})

      assert {:error, {:guardrail_ineligible, :codex, phrase}} = dispatch(task)

      assert phrase =~ "held — guardrail"
      assert phrase =~ "D3"
      assert no_runs?(task.id)
      assert [_one] = escalations(task.id, :no_eligible_model)
    end
  end

  describe "an explicit provider" do
    test "a caller-named ineligible provider is refused, not run" do
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
      task = task!(ws, %{difficulty: 3})

      assert {:error, {:guardrail_ineligible, :codex, phrase}} =
               dispatch(task, agent_type: :codex)

      assert phrase =~ "quarantine"
      assert no_runs?(task.id)
    end

    test "a caller-named eligible provider runs" do
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
      task = task!(ws, %{difficulty: 3})

      {:ok, result} = dispatch(task, agent_type: :claude)
      assert Worker.state(result.worker_pid).meta[:provider] == "claude"
    end
  end

  describe "most_quota routing" do
    defp routed!(claude_used) do
      ws =
        workspace!(%{
          "agent" => %{"type" => ["codex", "claude"]},
          "routing" => %{"provider_selection" => "most_quota"}
        })

      claude = account!(:claude)
      codex = account!(:codex)
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      claude_used!(claude, claude_used)
      codex_used!(codex, 10.0)
      %{ws: ws, claude: claude, codex: codex}
    end

    test "the ineligible account loses although it has the most headroom" do
      %{ws: ws, claude: claude} = routed!(0.70)
      task = task!(ws, %{difficulty: 3})

      {:ok, _} = dispatch(task)

      run = latest_run(task.id)
      assert run.provider_account_id == claude.id
      assert Enum.any?(run.routing_decision["dropped"], &(&1["reason"] == "guardrail_ineligible"))
    end

    test "when every eligible account is quota-held the dispatch is HELD, never given to the ineligible one" do
      %{ws: ws, claude: claude} = routed!(0.99)
      task = task!(ws, %{difficulty: 3})

      assert {:error, {:quota_held, task_id}} = dispatch(task)
      assert task_id == task.id
      assert no_runs?(task.id)

      assert %{reason: %{gate: :guardrail, phrase: phrase}} =
               DispatchQueue.held_item(ws.id, task.id)

      assert phrase =~ "eligible: claude:#{claude.slug}"
      assert phrase =~ "quota held"
      assert phrase =~ "ineligible: codex:"
      assert phrase =~ "D3"
      assert escalations(task.id, :no_eligible_model) == []
    end

    test "when no attached account is eligible at all the dispatch is refused and escalated" do
      ws =
        workspace!(%{
          "agent" => %{"type" => ["codex"]},
          "routing" => %{"provider_selection" => "most_quota"}
        })

      codex = account!(:codex)
      allow!(ws, codex, 0)
      codex_used!(codex, 10.0)
      task = task!(ws, %{difficulty: 3})

      assert {:error, {:guardrail_ineligible, _provider, phrase}} = dispatch(task)
      assert phrase =~ "held — guardrail"
      assert [_] = escalations(task.id, :no_eligible_model)
    end
  end

  # G15c (bd-dfay3f, design §5.6 step 4): a mid-run grant that widens the ticket
  # past what the pinned implementer subject may hold re-routes the next spawn.
  describe "a mid-run grant widens the ticket past the pinned subject" do
    @prod_read %{
      "prod_read" => %{"enforced_read_only" => true, "env_from_secret" => %{"A" => "b"}}
    }

    # Trusted, not a floored tier: a quarantine or probation floor is one this sandbox's codex
    # adapter cannot confine, which would drop it before the grant matters.
    @trusted_rules [
      %{match: %{provider: "claude"}, tier: :privileged},
      %{match: %{provider: "codex"}, tier: :trusted}
    ]

    defp pinned_codex!(accounts, rules \\ @trusted_rules) do
      put_app_env(:arbiter, :guardrail_subject_rules, rules)

      ws =
        workspace!(%{
          "agent" => %{"type" => ["codex", "claude"]},
          "routing" => %{"provider_selection" => "most_quota"},
          "guardrails" => %{"bindings" => @prod_read}
        })

      codex = account!(:codex)
      allow!(ws, codex, 0)
      codex_used!(codex, 10.0)

      claude =
        if accounts == :both do
          claude = account!(:claude)
          allow!(ws, claude, 1)
          claude_used!(claude, 0.70)
          claude
        end

      %{ws: ws, codex: codex, claude: claude}
    end

    defp first_run_and_stop!(task, sandbox) do
      {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: @repo, start_driver: false)
      TestSandbox.own!(sandbox, first.worker_pid)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)
      {first, latest_run(task.id)}
    end

    defp grant!(task_id, permission) do
      Issue
      |> Ash.get!(task_id)
      |> Ash.Changeset.for_update(:set_permissions, %{permissions: [permission]},
        context: %{guardrail_authority: :coordinator, permission_actor: "t"}
      )
      |> Ash.update!()
    end

    defp resume(task, extra \\ []) do
      Dispatch.resume(task.id, Keyword.merge([repo: @repo, start_driver: false], extra))
    end

    test "the next spawn is a fresh dispatch on the same branch from an eligible subject",
         %{sandbox: sandbox} do
      %{ws: ws, codex: codex, claude: claude} = pinned_codex!(:both)
      task = task!(ws, %{difficulty: 1})

      {first_result, first} = first_run_and_stop!(task, sandbox)
      assert first.provider_account_id == codex.id

      grant!(task.id, "prod_read")

      {:ok, result} = resume(task, claude_command: ["true"])
      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider == "claude"
      assert run.provider_account_id == claude.id
      assert run.routing_decision["outcome"] == "fallback"
      assert run.provider_fallback =~ "guardrail: pinned subject lacks prod_read"
      assert run.resumed_from_run_id == first.id

      # A fresh dispatch of the other provider, not a session resume.
      refute run.session_id
      assert result.worktree_path == first_result.worktree_path

      # The pin is kept: an operator may lift the permission again.
      assert Ash.get!(Issue, task.id).implementer_account_id == codex.id
    end

    test "with no eligible subject the resume is refused and escalated, never run ineligibly",
         %{sandbox: sandbox} do
      %{ws: ws} = pinned_codex!(:codex_only)
      task = task!(ws, %{difficulty: 1})

      {_, first} = first_run_and_stop!(task, sandbox)
      grant!(task.id, "prod_read")

      assert {:error, {:guardrail_ineligible, _provider, _phrase}} = resume(task)
      assert latest_run(task.id).id == first.id
      assert [_] = escalations(task.id, :no_eligible_model)
    end

    test "a grant within the pinned subject's profile keeps the pin", %{sandbox: sandbox} do
      privileged = [
        %{match: %{provider: "claude"}, tier: :privileged},
        %{match: %{provider: "codex"}, tier: :privileged}
      ]

      %{ws: ws, codex: codex} = pinned_codex!(:both, privileged)
      task = task!(ws, %{difficulty: 1})

      {_, _} = first_run_and_stop!(task, sandbox)
      grant!(task.id, "prod_read")

      {:ok, result} = resume(task, claude_command: ["true"])
      TestSandbox.own!(sandbox, result.worker_pid)

      run = latest_run(task.id)
      assert run.provider_account_id == codex.id
      assert run.routing_decision["outcome"] == "pinned"
      assert is_nil(run.provider_fallback)
      assert escalations(task.id, :no_eligible_model) == []
    end
  end

  describe "unguarded" do
    test "no subject rule configured dispatches exactly as before" do
      put_app_env(:arbiter, :guardrail_subject_rules, [])
      ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
      task = task!(ws, %{difficulty: 3})

      {:ok, result} = dispatch(task)
      # The pool's head runs as the default: nothing swapped it for claude.
      refute latest_run(result.task.id).provider == "claude"
      refute Worker.state(result.worker_pid).meta[:provider] == "claude"
    end
  end

  describe "guardrail_decision on the run (design §5.2)" do
    test "a guarded run records its subject, tier and projection" do
      ws = workspace!(%{"agent" => %{"type" => ["claude"]}})
      task = task!(ws, %{difficulty: 3})

      {:ok, _} = dispatch(task)

      assert %{
               "eligible" => true,
               "tier" => "privileged",
               "role" => "implementer",
               "subject" => %{"provider" => "claude"},
               "permission_fallback" => []
             } = latest_run(task.id).guardrail_decision
    end

    test "an optional permission the subject cannot hold is dropped to dispatch, and recorded" do
      ws = workspace!(%{"agent" => %{"type" => ["codex"]}})

      task =
        Ash.create!(
          Issue,
          %{
            title: "optional network",
            workspace_id: ws.id,
            difficulty: 1,
            permissions: ["network?:status.example.com:443"]
          },
          context: %{guardrail_authority: :coordinator, permission_actor: "t"}
        )

      {:ok, _} = dispatch(task)

      assert %{"eligible" => true, "permission_fallback" => [fallback]} =
               latest_run(task.id).guardrail_decision

      assert fallback["permission"] == "network?:status.example.com:443"
      assert fallback["reason"] =~ "quarantine"
    end

    test "an unguarded run records nothing" do
      put_app_env(:arbiter, :guardrail_subject_rules, [])
      ws = workspace!(%{"agent" => %{"type" => ["claude"]}})
      task = task!(ws, %{difficulty: 3})

      {:ok, _} = dispatch(task)
      assert latest_run(task.id).guardrail_decision == nil
    end
  end
end
