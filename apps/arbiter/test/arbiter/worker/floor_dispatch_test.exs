defmodule Arbiter.Worker.FloorDispatchTest do
  @moduledoc """
  bd-c675ny (R8, design §6.4): the floors on the real dispatcher.

    * the clamp: a task in a floored repo runs at (at least) the floor tier,
      and the run records that it was clamped;
    * the legacy-path check (the same shape as R4's E17): a pinned model below
      the floor, on a path the router cannot see, is refused rather than run;
    * the no-regression invariant (§9): with no `routing.floors` config the
      dispatch and its run are exactly what they were.

  Each runs the real dispatcher against stubbed agent binaries
  (`Arbiter.TestSandbox`).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run

  require Ash.Query

  setup do
    claude_credential_env!()

    sandbox = TestSandbox.provision!("floor-dispatch")
    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{"pc/repo" => sandbox.repo})

    on_exit(fn ->
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
      TestSandbox.own_live_workers!(sandbox)
    end)

    :ok
  end

  defp config(opts) do
    routing =
      %{"policy" => opts[:policy] || "by_difficulty"}
      |> Map.merge(
        if(opts[:floor],
          do: %{
            "floors" => %{
              "repos" => %{
                (opts[:floor_repo] || "pc/repo") => %{"min_model_tier" => opts[:floor]}
              }
            }
          },
          else: %{}
        )
      )

    %{
      "agent" => %{"type" => "claude", "config" => opts[:agent_config] || %{}},
      "routing" => routing
    }
  end

  defp workspace!(config) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "fd-#{n}", prefix: "fd#{n}", config: config})
  end

  defp task!(ws, attrs \\ %{}),
    do:
      Ash.create!(
        Issue,
        Map.merge(%{title: "floor me", workspace_id: ws.id, difficulty: 1}, attrs)
      )

  # `start_claude: true` runs the real spawn path against the sandbox's stubbed
  # `claude`, which is where run provenance is backfilled; the `:sys.get_state`
  # then waits for the worker to have handled that report.
  defp dispatch(task, extra \\ []) do
    opts =
      Keyword.merge(
        [force: true, repo: "pc/repo", start_driver: false, start_claude: true, preflight: false],
        extra
      )

    with {:ok, %{worker_pid: pid}} = ok <- Dispatch.dispatch(task.id, opts) do
      _ = :sys.get_state(pid)
      ok
    end
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

  describe "the clamp" do
    test "a D1 task in a repo with a premium floor runs at premium, and the run says it was clamped" do
      ws = workspace!(config(floor: "premium"))
      task = task!(ws)

      assert {:ok, _} = dispatch(task)

      run = latest_run(task.id)
      assert run.model_tier == "premium"
      assert run.floor_clamped == true
    end

    test "a task already at or above the floor is not clamped" do
      ws = workspace!(config(floor: "standard"))
      task = task!(ws, %{difficulty: 3})

      assert {:ok, _} = dispatch(task)

      run = latest_run(task.id)
      assert run.model_tier == "premium"
      assert run.floor_clamped == false
    end

    test "I1: with no floors config the run is exactly what it was" do
      ws = workspace!(config([]))
      task = task!(ws)

      assert {:ok, _} = dispatch(task)

      run = latest_run(task.id)
      assert run.model_tier == "economy"
      assert run.floor_clamped == false
    end
  end

  describe "the legacy-path check" do
    @pinned %{"model" => "haiku"}

    test "a pinned model below the repo floor is refused, and nothing runs" do
      ws = workspace!(config(policy: "static", floor: "premium", agent_config: @pinned))
      task = task!(ws)

      assert {:error, {:below_floor, :claude, phrase}} = dispatch(task)
      assert phrase =~ "below floor"
      assert phrase =~ "premium"
      assert no_runs?(task.id)
    end

    test "the same pin with no floor runs as today" do
      ws = workspace!(config(policy: "static", agent_config: @pinned))
      task = task!(ws)

      assert {:ok, _} = dispatch(task)
    end

    test "a task in a repo with no floor is not gated" do
      ws =
        workspace!(
          config(
            policy: "static",
            floor: "premium",
            floor_repo: "elsewhere",
            agent_config: @pinned
          )
        )

      task = task!(ws)

      assert {:ok, _} = dispatch(task)
    end

    test "an operator's explicit model override is not routing and is not refused" do
      ws = workspace!(config(policy: "static", floor: "premium", agent_config: @pinned))
      task = task!(ws)

      assert {:ok, _} = dispatch(task, model: "haiku")
    end
  end
end
