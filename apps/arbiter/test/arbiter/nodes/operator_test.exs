defmodule Arbiter.Nodes.OperatorTest do
  @moduledoc "The operator verbs RW7 adds to `Arbiter.Nodes`: the local cap, upgrade, the reserved name."

  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Registry, Session}
  alias Arbiter.Settings

  @operator Actor.operator("cli")

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    previous = Application.fetch_env(:arbiter, :data_dir)
    previous_version = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :data_dir, home)
    Application.put_env(:arbiter, :node_primary_version, "1.2.3")

    on_exit(fn ->
      restore(:data_dir, previous)
      restore(:node_primary_version, previous_version)

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    %{home: home}
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  defp enroll!(name) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name], @operator)
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)
    node
  end

  defp hello do
    %{
      "agent_version" => "1.2.3",
      "proto" => 1,
      "caps" => %{},
      "capacity" => %{"suggestion" => 4},
      "runs" => []
    }
  end

  # A release laid out the way `arb server deploy` leaves it, with no retained
  # tarball: `Nodes.Agent` packs the unpacked tree.
  defp install_release!(home, tag \\ "v9.9.9") do
    tree = Path.join([home, "releases", tag])
    File.mkdir_p!(Path.join(tree, "bin"))
    File.write!(Path.join(tree, "bin/arbiter"), "#!/bin/sh\n")
    File.chmod!(Path.join(tree, "bin/arbiter"), 0o755)
    File.ln_s!(tree, Path.join(home, "current"))
    {:ok, %{version: ^tag, sha256: sha}} = Nodes.Agent.artifact(home)
    %{tag: tag, sha256: sha}
  end

  describe "enrolment" do
    test "broadcasts {:node_enrolled, id, join_token_id} on the nodes topic" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
      {:ok, %{token: token, join_token: jt}} = Nodes.mint_join_token([name: "fresh"], @operator)
      {:ok, %{node: node}} = Nodes.redeem_join_token(token)

      assert_receive {:node_enrolled, id, jt_id}
      assert id == node.id
      assert jt_id == jt.id
    end
  end

  describe "the reserved name" do
    test "`local` names the primary, so no node may take it" do
      refute Nodes.valid_name?("local")
      assert {:error, :invalid_name} = Nodes.mint_join_token([name: "local"], @operator)
      assert Nodes.valid_name?("local-2")
    end
  end

  describe "set_local_max_workers/2" do
    test "persists the override, 0 included, and audits it" do
      assert {:ok, 0} = Nodes.set_local_max_workers(0, @operator)
      assert Settings.nodes_local_max_workers() == 0

      assert [event] = Nodes.events(kind: :updated)
      assert event.node_id == nil
      assert event.actor == "operator:cli"
      assert event.detail == %{"node" => "local", "changes" => %{"max_workers" => 0}}
    end

    test "nil clears the override" do
      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      assert {:ok, nil} = Nodes.set_local_max_workers(nil, @operator)
      assert Settings.nodes_local_max_workers() == nil
      assert length(Nodes.events(kind: :updated)) == 2
    end

    test "refuses a negative or non-integer cap and writes no event" do
      assert {:error, :invalid_value} = Nodes.set_local_max_workers(-1, @operator)
      assert {:error, :invalid_value} = Nodes.set_local_max_workers("3", @operator)
      assert Nodes.events(kind: :updated) == []
    end

    test "an unchanged value writes no event" do
      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      assert length(Nodes.events(kind: :updated)) == 1
    end
  end

  describe "update_node/3 with a live session" do
    test "a new max_workers reaches the session without a reconnect" do
      node = enroll!("live")
      {:ok, %{pid: pid}} = Registry.attach(node, self(), hello(), tick_ms: :infinity)
      assert %{max_workers: 4} = Session.snapshot(pid)

      {:ok, _} = Nodes.update_node(node, %{max_workers: 2}, @operator)
      assert %{max_workers: 2} = Session.snapshot(pid)

      {:ok, _} = Nodes.update_node(Nodes.get_node(node.id), %{max_workers: nil}, @operator)
      assert %{max_workers: 4} = Session.snapshot(pid)
    end
  end

  describe "upgrade/2" do
    test "pushes the served release to the live session's channel and audits it", %{home: home} do
      %{tag: tag, sha256: sha} = install_release!(home)
      node = enroll!("old")
      {:ok, _} = Registry.attach(node, self(), hello(), tick_ms: :infinity)

      assert {:ok, %{version: ^tag, sha256: ^sha}} = Nodes.upgrade(node, @operator)

      assert_receive {:node_session, {:upgrade, %{"version" => ^tag, "sha256" => ^sha}}}

      assert [event] = Nodes.events(kind: :upgraded)
      assert event.node_id == node.id
      assert event.actor == "operator:cli"
      assert event.detail["version"] == tag
    end

    test "an offline node cannot be upgraded", %{home: home} do
      install_release!(home)
      assert {:error, :offline} = Nodes.upgrade(enroll!("cold"), @operator)
      assert Nodes.events(kind: :upgraded) == []
    end

    test "a revoked node cannot be upgraded", %{home: home} do
      install_release!(home)
      node = enroll!("gone")
      {:ok, revoked} = Nodes.revoke(node, @operator)
      assert {:error, :revoked} = Nodes.upgrade(revoked, @operator)
    end

    test "with no release to serve it is :unavailable" do
      node = enroll!("nothing")
      {:ok, _} = Registry.attach(node, self(), hello(), tick_ms: :infinity)
      assert {:error, :unavailable} = Nodes.upgrade(node, @operator)
    end
  end
end
