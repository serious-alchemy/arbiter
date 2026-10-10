defmodule Arbiter.Worker.Executor.NodeTest do
  @moduledoc """
  bd-4p1vui (`docs/design/remote-workers.md` §10.4.3, §12): `Executor.Node.adopt/3`, the
  held-run twin of `prepare/3`, and `unadopt/2`, over a node's real `Nodes.Session` (the
  test process stands in for the channel).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Registry, Session}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias Arbiter.Workers.Run

  @version "1.2.3"
  @ctx %{home: "/h", branch: "arbiter/b", base: "main", seeded_paths: [], config_dir: "/c"}

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    for {key, value} <- [node_primary_version: @version, data_dir: home] do
      previous = Application.fetch_env(:arbiter, key)
      Application.put_env(:arbiter, key, value)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, key, v)
          :error -> Application.delete_env(:arbiter, key)
        end
      end)
    end

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    {:ok, %{token: token}} = Nodes.mint_join_token([name: "exec-node"], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)

    row =
      Ash.create!(Run, %{
        node_id: node.id,
        task_id: "bd-exec-adopt",
        base_task_id: "bd-exec-adopt",
        repo: "trib/repo",
        kind: :implement,
        provider: "claude",
        state: :working,
        started_at: DateTime.utc_now()
      })

    hello = %{
      "agent_version" => @version,
      "proto" => 1,
      "caps" => %{"backend" => "podman", "run_hold" => "quiesce", "run_adopt" => "attach"},
      "capacity" => %{"cpus" => 8},
      "runs" => [%{"id" => row.id, "state" => "running", "exited" => false, "acked" => 0}]
    }

    {:ok, %{pid: pid, hello_ok: ok}} = Registry.attach(node, self(), hello, tick_ms: :infinity)
    assert ok["runs"] == %{row.id => "hold"}
    %{node: node, run: row.id, session: pid}
  end

  test "adopt hands the held run to its owner and answers like prepare; unadopt gives it back",
       %{node: node, run: run, session: pid} do
    owner = self()
    spec = %{"run" => run, "bridges" => [%{"name" => "arb", "path" => "/p/arb.sock"}]}

    task =
      Task.async(fn -> Executor.adopt(%{id: node.id}, spec, owner: owner, checkout: @ctx) end)

    assert_receive {:node_session, {:push, "adopt", %{"run" => ^run}}}
    Session.node_event(pid, "run.ready", %{"run" => run, "adopted" => true, "acked" => 0})

    assert {:ok, %{handle: {:remote, {_, ^run, _}} = handle, run: ^run, session: ^pid} = prepared} =
             Task.await(task)

    assert {:ok, ^handle} = Executor.open(prepared)
    assert Executor.live?(handle)
    assert {:ok, @ctx} = Session.checkout_context(pid, run)

    assert :ok = Executor.unadopt(node.id, run)
    refute Executor.live?(handle)
    refute_received {:node_session, {:push, "cancel", _}}
    assert :ok = Session.adoptable(pid, run)
  end

  test "a refused adoption is an error and touches nothing", %{node: node, run: run, session: pid} do
    owner = self()
    task = Task.async(fn -> Executor.adopt(node.id, %{"run" => run}, owner: owner) end)
    assert_receive {:node_session, {:push, "adopt", _}}
    Session.node_event(pid, "adopt.refused", %{"run" => run, "reason" => "exited"})

    assert {:error, {:adopt_refused, "exited"}} = Task.await(task)
    refute_received {:node_session, {:push, "cancel", _}}
  end

  test "no session, no run id, or a run that is not held", %{node: node} do
    assert {:error, :no_session} = Executor.adopt("no-such-node", %{"run" => "r1"}, owner: self())
    assert {:error, :no_run_id} = Executor.adopt(node.id, %{}, owner: self())
    assert {:error, :not_held} = Executor.adopt(node.id, %{"run" => "ghost"}, owner: self())
    assert :ok = Executor.unadopt("no-such-node", "r1")
  end
end
