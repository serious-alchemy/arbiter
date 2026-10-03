defmodule Arbiter.Worker.Egress.BridgeIdentityTest do
  @moduledoc """
  bd-c1qq7l (G9): the registry behind the Arbiter bridge's identity. The
  end-to-end behaviour (a real bridge into the real endpoint) is in
  `ArbiterWeb.WorkerBridgeIdentityTest`.
  """
  use ExUnit.Case, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Worker.Egress.BridgeIdentity

  @peer {{127, 0, 0, 1}, 50_001}

  setup do
    run_id = "r#{System.unique_integer([:positive])}"
    on_exit(fn -> BridgeIdentity.delete_run(run_id) end)
    {:ok, run_id: run_id}
  end

  defp worker_token(task_id \\ "bd-abc123"),
    do: Scope.mint_worker(%{id: task_id, workspace_id: "ws-1"}, "repo")

  defp live_pid, do: start_supervised!({Agent, fn -> :ok end}, id: make_ref())

  test "an unregistered peer is not a bridge connection" do
    assert BridgeIdentity.resolve({127, 0, 0, 1}, 50_999) == :none
    assert BridgeIdentity.resolve(nil, nil) == :none
  end

  test "a registered connection resolves to the run's worker scope", %{run_id: run_id} do
    :ok = BridgeIdentity.put_run(run_id, worker_token())
    :ok = BridgeIdentity.register(run_id, @peer, live_pid())

    assert {:bridge, ^run_id,
            {:ok, %Scope{tier: :worker, task_id: "bd-abc123", workspace_id: "ws-1"}}} =
             BridgeIdentity.resolve(elem(@peer, 0), elem(@peer, 1))
  end

  test "a run with no token, a non-worker token or a bad token resolves to an error", %{
    run_id: run_id
  } do
    pid = live_pid()
    :ok = BridgeIdentity.register(run_id, @peer, pid)
    resolve = fn -> BridgeIdentity.resolve(elem(@peer, 0), elem(@peer, 1)) end

    assert {:bridge, ^run_id, {:error, :no_identity}} = resolve.()

    :ok = BridgeIdentity.put_run(run_id, nil)
    assert {:bridge, ^run_id, {:error, :no_identity}} = resolve.()

    :ok = BridgeIdentity.put_run(run_id, Scope.mint_coordinator(nil))
    assert {:bridge, ^run_id, {:error, :not_worker_scope}} = resolve.()

    :ok = BridgeIdentity.put_run(run_id, "garbage")
    assert {:bridge, ^run_id, {:error, _}} = resolve.()

    expired = Scope.mint_worker(%{id: "bd-abc123", workspace_id: "ws-1"}, nil, max_age: -1)
    :ok = BridgeIdentity.put_run(run_id, expired)
    assert {:bridge, ^run_id, {:error, :expired}} = resolve.()
  end

  test "a resume replaces the run's token", %{run_id: run_id} do
    :ok = BridgeIdentity.register(run_id, @peer, live_pid())
    :ok = BridgeIdentity.put_run(run_id, worker_token("bd-old"))
    :ok = BridgeIdentity.put_run(run_id, worker_token("bd-new"))

    assert {:bridge, _, {:ok, %Scope{task_id: "bd-new"}}} =
             BridgeIdentity.resolve(elem(@peer, 0), elem(@peer, 1))
  end

  test "the connection's entry goes with its process", %{run_id: run_id} do
    :ok = BridgeIdentity.put_run(run_id, worker_token())
    pid = live_pid()
    :ok = BridgeIdentity.register(run_id, @peer, pid)
    assert {:bridge, _, _} = BridgeIdentity.resolve(elem(@peer, 0), elem(@peer, 1))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert BridgeIdentity.resolve(elem(@peer, 0), elem(@peer, 1)) == :none
  end

  test "the run's entry goes with its owner and with delete_run/1", %{run_id: run_id} do
    owner = live_pid()
    :ok = BridgeIdentity.put_run(run_id, worker_token(), owner)
    :ok = BridgeIdentity.register(run_id, @peer, live_pid())

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    _ = :sys.get_state(BridgeIdentity)

    assert {:bridge, ^run_id, {:error, :no_identity}} =
             BridgeIdentity.resolve(elem(@peer, 0), elem(@peer, 1))

    :ok = BridgeIdentity.put_run(run_id, worker_token())
    :ok = BridgeIdentity.delete_run(run_id)

    assert {:bridge, ^run_id, {:error, :no_identity}} =
             BridgeIdentity.resolve(elem(@peer, 0), elem(@peer, 1))
  end
end
