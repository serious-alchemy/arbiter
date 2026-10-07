defmodule Arbiter.NodeAgent.SupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.NodeAgent.Supervisor, as: AgentSupervisor

  setup do
    home = Path.join(System.tmp_dir!(), "arb-agentsup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "an unconfigured agent stays up and says why in the status file", %{home: home} do
    start_supervised!(
      {AgentSupervisor,
       [env: %{}, node_home: home, credential_file: Path.join(home, "credential")]}
    )

    children = AgentSupervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert children == [Arbiter.NodeAgent.TaskSupervisor]

    status = home |> Path.join("status.json") |> File.read!() |> Jason.decode!()
    assert status["state"] == "unconfigured"
    assert status["error"] =~ "ARB_NODE_URL"
  end

  test "a configured agent starts exactly the NodeAgent tree and no primary process", %{
    home: home
  } do
    cred = Path.join(home, "credential")
    File.write!(cred, "arbn_n1." <> String.duplicate("A", 52))
    File.chmod!(cred, 0o600)

    start_supervised!({AgentSupervisor,
     [
       env: %{},
       primary_url: "http://127.0.0.1:9",
       node_home: home,
       credential_file: cred,
       # connection attempts to a dead port retry in the background
       backoff: [base: 60_000, max: 60_000]
     ]})

    children = AgentSupervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

    # `Image.Builder` is the primary app tree's here, so the agent doesn't start
    # a second one; a bare agent boot does.
    assert Enum.sort(children) ==
             Enum.sort([
               Arbiter.NodeAgent.TaskSupervisor,
               Arbiter.NodeAgent.Status,
               Arbiter.NodeAgent.Upgrader,
               Arbiter.NodeAgent.RunRegistry,
               Arbiter.NodeAgent.RunSupervisor,
               Arbiter.NodeAgent.Bridge,
               Arbiter.NodeAgent.Connection
             ])
  end
end
