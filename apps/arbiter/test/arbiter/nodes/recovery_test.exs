defmodule Arbiter.Nodes.RecoveryTest do
  @moduledoc """
  RW12 (`docs/design/remote-workers.md` §10.5): `Nodes.Recovery.await/1`, the first
  step of the boot sweep. It waits (bounded, in parallel across nodes) for the
  nodes that hold live remote runs to reconnect and deliver what they retained,
  and stamps the runs of a node that never comes back `interrupted` / `:node_lost`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Recovery, Registry, Session}
  alias Arbiter.Workers.Run

  @version "1.2.3"
  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    prev_version = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)
    prev_dir = Application.fetch_env(:arbiter, :data_dir)
    Application.put_env(:arbiter, :data_dir, home)

    on_exit(fn ->
      restore(:node_primary_version, prev_version)
      restore(:data_dir, prev_dir)

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  defp enroll!(name) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)
    node
  end

  defp hello(retained) do
    %{
      "agent_version" => @version,
      "proto" => 1,
      "caps" => %{},
      "capacity" => %{"suggestion" => 4},
      "inventory" => %{"runs" => [], "retained" => Enum.map(retained, &%{"run" => &1})}
    }
  end

  defp attach(node, retained, channel \\ self()) do
    Registry.attach(node, channel, hello(retained), tick_ms: :infinity)
  end

  defp run!(node, state \\ :working) do
    Ash.create!(Run, %{
      task_id: "bd-rec-#{System.unique_integer([:positive])}",
      base_task_id: "bd-rec",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: state,
      node_id: node && node.id,
      started_at: DateTime.utc_now()
    })
  end

  defp context_fun(_run), do: {:ok, %{home: "/h", branch: "b", base: "main", seeded_paths: []}}

  # Plays an agent: connects after `delay_ms` (as one does after a primary restart, once
  # its backoff elapses) with `retained`, then answers every `recover` the session asks.
  defp start_agent(
         node,
         retained,
         delay_ms \\ 0,
         reply \\ %{"transcripts" => "none", "checkout" => "ok"}
       ) do
    spawn_link(fn ->
      Process.sleep(delay_ms)
      {:ok, %{pid: pid}} = attach(node, retained, self())
      answer_loop(pid, reply)
    end)
  end

  defp answer_loop(pid, reply) do
    receive do
      {:node_session, {:push, "recover", %{"run" => run}}} ->
        Session.checkout_done(pid, run, {:ok, %{head: "tip-of-#{run}"}})
        Session.node_event(pid, "recovered", Map.put(reply, "run", run))
        answer_loop(pid, reply)

      _other ->
        answer_loop(pid, reply)
    end
  end

  defp opts(extra \\ []),
    do:
      Keyword.merge(
        [
          context_fun: &context_fun/1,
          node_timeout_ms: 300,
          total_timeout_ms: 600,
          primary?: true
        ],
        extra
      )

  defp reload(run), do: Ash.get!(Run, run.id)

  test "nothing to recover returns at once" do
    _local = run!(nil)
    _done = run!(enroll!("n0"), :finished)
    assert {:ok, report} = Recovery.await(opts())
    assert report == %{}
  end

  test "a non-primary instance recovers nothing" do
    run!(enroll!("n0"))
    assert {:ok, :skipped} = Recovery.await(opts(primary?: false))
  end

  test "a node that reconnects delivers its retained run before await returns" do
    node = enroll!("n1")
    run = run!(node)
    # connects only after await has started waiting
    start_agent(node, [run.id], 80)

    assert {:ok, report} = Recovery.await(opts(node_timeout_ms: 2_000, total_timeout_ms: 3_000))
    assert report[run.id] == :collected
    # nothing was stamped: the Reconciler (which runs next) resumes it like any interrupted run
    assert reload(run).state == :working
  end

  test "several runs on one node are all recovered" do
    node = enroll!("n3")
    runs = [run!(node), run!(node)]
    start_agent(node, Enum.map(runs, & &1.id))

    assert {:ok, report} = Recovery.await(opts(node_timeout_ms: 2_000, total_timeout_ms: 3_000))
    assert Enum.all?(runs, &(report[&1.id] == :collected))
  end

  test "a node that never reconnects: the run is interrupted as :node_lost, within the budget" do
    node = enroll!("gone")
    run = run!(node)
    started = System.monotonic_time(:millisecond)

    assert {:ok, report} = Recovery.await(opts())
    assert {:unreachable, :timeout} = report[run.id]
    assert System.monotonic_time(:millisecond) - started < 2_000

    updated = reload(run)
    assert updated.state == :finished
    assert updated.outcome == :interrupted
    assert updated.stop_category == "node_lost"
    assert updated.failure_reason =~ "node lost: gone"
    assert updated.completed_at
  end

  test "many unreachable nodes are waited for in parallel, inside the total budget" do
    runs = for i <- 1..4, do: run!(enroll!("gone-#{i}"))
    started = System.monotonic_time(:millisecond)

    assert {:ok, report} = Recovery.await(opts(node_timeout_ms: 400, total_timeout_ms: 800))
    assert Enum.all?(runs, &match?({:unreachable, _}, report[&1.id]))
    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "a reachable node that has nothing for the run leaves the row to the Reconciler" do
    node = enroll!("empty")
    run = run!(node)
    {:ok, _} = attach(node, [])

    assert {:ok, report} = Recovery.await(opts())
    assert {:unreachable, :not_on_node} = report[run.id]

    # the node is fine; only the work is missing: it is "server restarted", not node_lost
    untouched = reload(run)
    assert untouched.state == :working
  end

  test "a run whose home clone is missing is not asked for" do
    node = enroll!("n2")
    run = run!(node)
    {:ok, _} = attach(node, [run.id])

    assert {:ok, report} =
             Recovery.await(opts(context_fun: fn _ -> {:error, :no_home_clone} end))

    assert {:unreachable, {:no_context, :no_home_clone}} = report[run.id]
    refute_received {:node_session, {:push, "recover", _}}
  end
end
