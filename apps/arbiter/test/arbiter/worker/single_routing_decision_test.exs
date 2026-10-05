defmodule ArbiterRoutingProbe.Policy do
  @moduledoc false
  # A counting policy: reports every `choose/3` call (and the ledger snapshot
  # it was handed) to the pid parked in the app env, then answers like
  # `:round_robin` would, so the cursor's advance is observable too.
  @behaviour Arbiter.Agents.Routing.Policy

  @impl true
  def choose(task, workspace, snapshot) do
    send(Application.fetch_env!(:arbiter, :routing_probe_pid), {:choose, task.id, snapshot})
    Arbiter.Agents.Routing.RoundRobin.choose(task, workspace, snapshot)
  end
end

defmodule ArbiterRoutingProbe.Extension do
  @moduledoc false
  @behaviour Arbiter.Extension

  @impl true
  def contributions, do: [{:routing_policy, "counting", ArbiterRoutingProbe.Policy}]
end

defmodule Arbiter.Worker.SingleRoutingDecisionTest do
  @moduledoc """
  bd-4jeqhg (seams #7): one `Routing.Policy.choose/3` call per dispatch, handed
  a real ledger snapshot. Before, the quota-gate provider lookup, the pause
  gate, the account admission, the provider router and the spawn each called
  `choose/3` again — a stateful policy (`:round_robin`'s cursor) could gate on
  one adapter config and spawn on another.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Extensions
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Usage.Event
  alias Arbiter.Worker.Dispatch

  setup do
    claude_credential_env!()

    sandbox =
      TestSandbox.provision!("single-routing",
        stub: %{
          "claude" =>
            "echo \"claude $@\" >> \"$(dirname \"$0\")/../cli-calls.log\"\necho \"arb done\"\nexit 0\n"
        }
      )

    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{"test/repo" => sandbox.repo})
    put_app_env(:arbiter, :routing_probe_pid, self())

    Extensions.load!([ArbiterRoutingProbe.Extension])
    CredentialWatchdog.mark_recovered(Agents.Claude)
    _ = :sys.get_state(CredentialWatchdog)

    on_exit(fn ->
      Extensions.load!()
      TestSandbox.own_live_workers!(sandbox)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ws-single-routing-#{System.unique_integer([:positive])}",
        prefix: "sr#{System.unique_integer([:positive])}",
        config: %{
          "agent" => %{"type" => "claude"},
          "repo_paths" => %{"test/repo" => sandbox.repo},
          "routing" => %{
            "policy" => "counting",
            "adapters" => [%{"model" => "sonnet"}, %{"model" => "haiku"}]
          }
        }
      })

    {:ok, task} = Ash.create(Issue, %{title: "route once", workspace_id: ws.id})
    %{sandbox: sandbox, ws: ws, task: task}
  end

  defp drain_chooses(acc \\ []) do
    receive do
      {:choose, _id, _snapshot} = msg -> drain_chooses([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a dispatch calls the routing policy exactly once", %{task: task} do
    assert {:ok, _} =
             Dispatch.dispatch(task.id,
               repo: "test/repo",
               force: true,
               start_driver: false,
               start_claude: true
             )

    assert [{:choose, id, _snapshot}] = drain_chooses()
    assert id == task.id
  end

  test "the one call is the one that spawns: round_robin picks the first adapter", %{
    task: task,
    sandbox: sandbox
  } do
    {:ok, result} =
      Dispatch.dispatch(task.id,
        repo: "test/repo",
        force: true,
        start_driver: false,
        start_claude: true
      )

    TestSandbox.own!(sandbox, result.worker_pid)
    assert [_] = drain_chooses()

    assert eventually(fn -> File.exists?(sandbox.log) and File.read!(sandbox.log) =~ "sonnet" end)
    refute File.read!(sandbox.log) =~ "haiku"
  end

  test "the policy is handed the workspace's real ledger spend for today", %{
    ws: ws,
    task: task
  } do
    {:ok, _} =
      Ash.create(Event, %{
        task_id: "bd-other",
        repo: "arbiter",
        workspace_id: ws.id,
        step: :work,
        cost_usd: 1.25,
        occurred_at: DateTime.utc_now()
      })

    {:ok, _} =
      Ash.create(Event, %{
        task_id: "bd-yesterday",
        repo: "arbiter",
        workspace_id: ws.id,
        step: :work,
        cost_usd: 99.0,
        occurred_at: DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      })

    assert {:ok, _} =
             Dispatch.dispatch(task.id,
               repo: "test/repo",
               force: true,
               start_driver: false,
               start_claude: true
             )

    assert [{:choose, _id, snapshot}] = drain_chooses()
    assert_in_delta snapshot.cost_usd_today, 1.25, 1.0e-9
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        receive do
        after
          100 -> eventually(fun, tries - 1)
        end
    end
  end
end
