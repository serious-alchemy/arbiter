defmodule Arbiter.Nodes.OverviewTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Overview, Registry}
  alias Arbiter.Settings
  alias Arbiter.Workers.Run

  @version "1.2.3"
  @operator Actor.operator("cli")

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    previous_version = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)
    previous_dir = Application.fetch_env(:arbiter, :data_dir)
    Application.put_env(:arbiter, :data_dir, home)

    on_exit(fn ->
      restore(:node_primary_version, previous_version)
      restore(:data_dir, previous_dir)

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  defp enroll!(name, opts \\ []) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name] ++ opts, @operator)
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)
    node
  end

  defp hello(overrides \\ %{}) do
    Map.merge(
      %{
        "agent_version" => @version,
        "proto" => 1,
        "arch" => "x86_64",
        "caps" => %{"backend" => "podman"},
        "capacity" => %{"cpus" => 8, "suggestion" => 4},
        "runs" => []
      },
      overrides
    )
  end

  defp connect!(node, params \\ hello()),
    do: {:ok, _} = Registry.attach(node, self(), params, tick_ms: :infinity)

  defp run!(state) do
    Ash.create!(Run, %{
      task_id: "bd-overview-test",
      base_task_id: "bd-overview-test",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: state,
      started_at: DateTime.utc_now()
    })
  end

  defp row(overview, name), do: Enum.find(overview.nodes, &(&1.name == name))

  describe "build/0 node rows" do
    test "an enrolled node that never connected is offline with no live capacity" do
      enroll!("cold", max_workers: 3)

      assert %{state: :offline, live: 0, override: 3, max: 3, suggested: nil, ceiling: nil} =
               row(Overview.build(), "cold")
    end

    test "a connected node reports version, health, suggestion, ceiling and live runs" do
      node = enroll!("warm")
      live = run!(:working)

      connect!(
        node,
        hello(%{
          "capacity" => %{"suggestion" => 4, "ceiling" => 2},
          "runs" => [%{"id" => live.id, "state" => "running"}]
        })
      )

      assert %{
               state: :online,
               health: :ready,
               agent_version: @version,
               server_version: @version,
               suggested: 4,
               ceiling: 2,
               override: nil,
               max: 2,
               live: 1
             } = row(Overview.build(), "warm")
    end

    test "an override above the node ceiling loses to it; one below wins" do
      above = enroll!("above", max_workers: 8)
      below = enroll!("below", max_workers: 1)
      params = hello(%{"capacity" => %{"suggestion" => 4, "ceiling" => 3}})
      connect!(above, params)
      connect!(below, params)

      overview = Overview.build()
      assert %{override: 8, ceiling: 3, max: 3} = row(overview, "above")
      assert %{override: 1, ceiling: 3, max: 1} = row(overview, "below")
    end

    test "draining and revoked nodes show those states" do
      drained = enroll!("drained")
      revoked = enroll!("gone")
      connect!(drained)
      {:ok, _} = Nodes.drain(drained, @operator)
      {:ok, _} = Nodes.revoke(revoked, @operator)

      overview = Overview.build()
      assert %{state: :draining} = row(overview, "drained")
      assert %{state: :revoked} = row(overview, "gone")
    end

    test "the last heartbeat comes from the live session's silence" do
      node = enroll!("beating")
      connect!(node)

      assert %{last_heartbeat_at: %DateTime{} = at} = row(Overview.build(), "beating")
      assert DateTime.diff(DateTime.utc_now(), at) in 0..5
    end
  end

  describe "build/0 local row" do
    test "the primary is a local row whose default cap is the install's local concurrency" do
      %{local: local} = Overview.build()

      assert %{name: "local", kind: :local, state: :online, override: nil} = local
      assert local.suggested == Arbiter.Board.Snapshot.system_max_concurrent()
      assert local.max == local.suggested
    end

    test "counts live local runs but not finished ones nor ones on a node" do
      remote = run!(:working)
      _local = run!(:starting)
      _done = run!(:finished)
      connect!(enroll!("host"), hello(%{"runs" => [%{"id" => remote.id}]}))

      assert %{local: %{live: 1}} = Overview.build()
    end

    test "the override replaces the suggestion, and may be 0" do
      {:ok, 0} = Nodes.set_local_max_workers(0, @operator)
      assert %{local: %{override: 0, max: 0}} = Overview.build()
    end
  end

  describe "build/0 totals and warnings" do
    test "sums local plus every non-revoked node's cap against conductor.max_concurrent" do
      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      {:ok, _} = Settings.set_conductor_system_max_concurrent(10)
      connect!(enroll!("a", max_workers: 3))
      connect!(enroll!("b"), hello(%{"capacity" => %{"suggestion" => 4}}))
      revoked = enroll!("c", max_workers: 9)
      {:ok, _} = Nodes.revoke(revoked, @operator)

      assert %{total: 9, ceiling: 10, warnings: []} = Overview.build()
    end

    test "warns when the global ceiling is below the sum" do
      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      {:ok, _} = Settings.set_conductor_system_max_concurrent(4)
      enroll!("a", max_workers: 5)

      assert %{total: 7, ceiling: 4, warnings: warnings} = Overview.build()
      assert :ceiling_below_total in warnings
    end

    test "warns when the global ceiling far exceeds the sum" do
      {:ok, 1} = Nodes.set_local_max_workers(1, @operator)
      {:ok, _} = Settings.set_conductor_system_max_concurrent(20)

      assert :ceiling_far_above_total in Overview.build().warnings
    end

    test "a local cap of 0 is a persistent warning" do
      {:ok, 0} = Nodes.set_local_max_workers(0, @operator)
      assert :local_cap_zero in Overview.build().warnings
    end
  end

  describe "node_for_run/1" do
    test "names the node whose session holds the run, else nil" do
      node = enroll!("runner")
      remote = run!(:working)
      connect!(node, hello(%{"runs" => [%{"id" => remote.id}]}))

      assert %{id: id, name: "runner"} = Overview.node_for_run(remote.id)
      assert id == node.id
      assert Overview.node_for_run(run!(:working).id) == nil
    end
  end

  describe "exposure/1" do
    test "tailnet, private and loopback hosts are private" do
      for url <- [
            "https://box.tail1234.ts.net",
            "https://10.1.2.3",
            "http://172.16.0.9:4848",
            "http://192.168.1.5",
            "https://100.64.0.1",
            "http://127.0.0.1:4848",
            "http://localhost:4848",
            "https://[fd00::1]",
            "https://[::1]"
          ] do
        assert Overview.exposure(url) == :private, url
      end
    end

    test "anything else is public" do
      for url <- ["https://arbiter.example.com", "https://8.8.8.8", "http://172.32.0.1"] do
        assert Overview.exposure(url) == :public, url
      end
    end

    test "nil and unparseable urls are :unset" do
      assert Overview.exposure(nil) == :unset
      assert Overview.exposure("not a url") == :unset
    end
  end
end
