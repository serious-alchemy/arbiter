defmodule Arbiter.Worker.CapabilityDispatchTest do
  @moduledoc """
  bd-57uzkl (R4, design §6.2 / E17): the capability hard gate on the paths the
  routers cannot see — an unrouted (`failover`) workspace, the `no_candidate`
  fall-through to the pre-routing provider, a caller's explicit provider and a
  resume's resolution. Each runs the real dispatcher against stubbed agent
  binaries (`Arbiter.TestSandbox`).

  The fixture's repo (`r`) requires `async_verification`. By the code defaults
  `claude` is reliable and `codex` is unknown, which fails closed.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run

  require Ash.Query

  @repo "pc/repo"

  setup do
    claude_credential_env!()

    sandbox = TestSandbox.provision!("capability-dispatch")
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
    Ash.create!(Workspace, %{name: "cd-#{n}", prefix: "cd#{n}", config: config})
  end

  defp config(opts) do
    routing =
      %{"repos" => %{"r" => %{"requires" => ["async_verification"]}}}
      |> Map.merge(if opts[:gates], do: %{"capability_gates" => true}, else: %{})
      |> Map.merge(if opts[:most_quota], do: %{"provider_selection" => "most_quota"}, else: %{})

    %{"agent" => %{"type" => opts[:pool] || ["codex", "claude"]}, "routing" => routing}
  end

  defp attach!(ws, provider) do
    account =
      Ash.create!(ProviderAccount, %{
        provider: provider,
        slug: "#{provider}-#{System.unique_integer([:positive])}"
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: provider,
      provider_account_id: account.id,
      implementer_position: 0
    })

    account
  end

  defp task!(ws), do: Ash.create!(Issue, %{title: "needs a capable agent", workspace_id: ws.id})

  defp dispatch(task, extra \\ []),
    do: Dispatch.dispatch(task.id, [force: true, repo: "r", start_driver: false] ++ extra)

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  defp no_runs?(task_id), do: Ash.Query.filter(Run, task_id == ^task_id) |> Ash.read!() == []

  # ---- the legacy agent.type path (routing off) -----------------------------------

  describe "failover (routing off): the unrouted agent.type path" do
    test "the pool's first provider lacks the capability: the dispatch is refused, not run" do
      ws = workspace!(config(gates: true))

      assert {:error, {:capability_missing, :codex, phrase}} = dispatch(task!(ws))
      assert phrase =~ "capability missing"
      assert phrase =~ "needs async_verification"
      assert phrase =~ "codex"
    end

    test "a caller-named provider that lacks it is refused too (explicit path)" do
      ws = workspace!(config(gates: true, pool: ["claude"]))
      task = task!(ws)

      assert {:error, {:capability_missing, :codex, _}} = dispatch(task, agent_type: :codex)
      assert no_runs?(task.id)
    end

    test "a capable provider runs, with nothing recorded" do
      ws = workspace!(config(gates: true, pool: ["claude"]))
      task = task!(ws)

      assert {:ok, _} = dispatch(task)
      assert latest_run(task.id).routing_decision == nil
    end

    test "the operator's installation override can make codex capable" do
      {:ok, _} =
        Arbiter.Settings.set_capability_matrix([
          %{"match" => %{"provider" => "codex"}, "async_verification" => "reliable"}
        ])

      ws = workspace!(config(gates: true))
      task = task!(ws)
      assert {:ok, _} = dispatch(task)
    end

    test "gates off (the default): codex runs exactly as today, whatever the repo declares" do
      ws = workspace!(config(gates: false))
      task = task!(ws)

      assert {:ok, _} = dispatch(task)
    end

    test "a task in a repo that declares no requirement is not gated" do
      ws =
        workspace!(%{
          "agent" => %{"type" => ["codex"]},
          "routing" => %{"capability_gates" => true}
        })

      task = task!(ws)
      assert {:ok, _} = dispatch(task)
    end
  end

  # ---- most_quota's no_candidate fall-through ---------------------------------------

  describe "most_quota: the no_candidate fall-through" do
    test "every attached account lacks it, so the pre-routing provider is checked too" do
      ws = workspace!(config(gates: true, most_quota: true))
      attach!(ws, :codex)
      task = task!(ws)

      assert {:error, {:capability_missing, :codex, _}} = dispatch(task)
      assert no_runs?(task.id)
    end

    test "a capable account is routed to, and the decision records the dropped one" do
      ws = workspace!(config(gates: true, most_quota: true))
      attach!(ws, :codex)
      claude = attach!(ws, :claude)
      task = task!(ws)

      assert {:ok, _} = dispatch(task)

      run = latest_run(task.id)
      assert run.provider_account_id == claude.id
      assert Enum.any?(run.routing_decision["dropped"], &(&1["reason"] == "capability_missing"))
    end
  end

  # ---- resume -------------------------------------------------------------------------

  describe "resume/2" do
    test "a provider that cannot resume is refused for the resume role", %{sandbox: sandbox} do
      ws =
        workspace!(%{
          "agent" => %{"type" => ["claude"]},
          "routing" => %{"capability_gates" => true}
        })

      task = task!(ws)

      {:ok, first} =
        Dispatch.dispatch(task.id, force: true, repo: @repo, start_driver: false)

      TestSandbox.own!(sandbox, first.worker_pid)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)

      {:ok, _} =
        Arbiter.Settings.set_capability_matrix([
          %{"match" => %{"provider" => "claude"}, "resume" => false}
        ])

      assert {:error, {:capability_missing, :claude, phrase}} =
               Dispatch.resume(task.id, start_driver: false, claude_command: ["true"])

      assert phrase =~ "needs resume"
    end
  end
end
