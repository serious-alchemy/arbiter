defmodule Arbiter.Nodes.ClusterUpgradeTest do
  @moduledoc """
  K9 (bd-6ez9yn, `docs/design/remote-workers.md` K§2.4): a cluster node is moved by image.
  The primary names the controller image for its own version (`hello_ok.upgrade{version,
  image}` and the operator's `upgrade`), and a node that cannot patch its own Deployment
  shows `outdated` with the exact `kubectl set image` command.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Overview, Registry}
  alias Arbiter.Settings

  @operator Actor.operator("cli")
  @registry "registry.example.test/arbiter"
  @release "v9.9.9"
  @image "#{@registry}/controller:#{@release}"

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    previous = Application.fetch_env(:arbiter, :data_dir)
    previous_version = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :data_dir, home)
    Application.put_env(:arbiter, :node_primary_version, "1.2.3")
    {:ok, _} = Settings.set_nodes_registry(@registry)

    tree = Path.join([home, "releases", @release])
    File.mkdir_p!(Path.join(tree, "bin"))
    File.write!(Path.join(tree, "bin/arbiter"), "#!/bin/sh\n")
    File.chmod!(Path.join(tree, "bin/arbiter"), 0o755)
    File.ln_s!(tree, Path.join(home, "current"))

    on_exit(fn ->
      restore(:data_dir, previous)
      restore(:node_primary_version, previous_version)
      {:ok, _} = Settings.set_nodes_registry(nil)

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  defp enroll!(name, kind) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name, kind: kind], @operator)
    {:ok, %{node: node}} = Nodes.redeem_join_token(token, %{kind: kind})
    node
  end

  defp hello(caps \\ %{}, overrides \\ %{}) do
    Map.merge(
      %{
        "agent_version" => "0.0.1",
        "proto" => 1,
        "kind" => "cluster",
        "caps" =>
          Map.merge(%{"backend" => "k8s", "image" => "registry", "upgrade" => "image"}, caps),
        "capacity" => %{"ceiling" => 4},
        "runs" => []
      },
      overrides
    )
  end

  defp attach!(node, params) do
    {:ok, %{hello_ok: ok}} = Registry.attach(node, self(), params, tick_ms: :infinity)
    ok
  end

  describe "hello_ok" do
    test "an outdated cluster node is told an image, not a tarball" do
      ok = attach!(enroll!("k3s", "cluster"), hello())

      assert ok["health"] == "outdated"
      assert ok["upgrade"] == %{"version" => @release, "image" => @image}
      refute Map.has_key?(ok["upgrade"], "sha256")
    end

    test "with no nodes.registry there is no image to name: no upgrade is offered" do
      {:ok, _} = Settings.set_nodes_registry(nil)
      ok = attach!(enroll!("k3s", "cluster"), hello())
      assert ok["health"] == "outdated"
      refute Map.has_key?(ok, "upgrade")
    end

    test "a machine node still gets the tarball spec" do
      ok = attach!(enroll!("box", "machine"), hello(%{}, %{"kind" => "machine"}))
      assert %{"version" => @release, "sha256" => sha} = ok["upgrade"]
      assert is_binary(sha)
      refute Map.has_key?(ok["upgrade"], "image")
    end

    test "a current cluster node is told nothing" do
      ok = attach!(enroll!("k3s", "cluster"), hello(%{}, %{"agent_version" => "1.2.3"}))
      assert ok["health"] == "ready"
      refute Map.has_key?(ok, "upgrade")
    end
  end

  describe "Nodes.upgrade/2" do
    test "pushes the image to a connected cluster node and audits it" do
      node = enroll!("k3s", "cluster")
      attach!(node, hello())

      assert {:ok, %{version: @release, image: @image}} = Nodes.upgrade(node, @operator)

      assert_receive {:node_session,
                      {:upgrade, %{"version" => @release, "image" => @image} = payload}}

      refute Map.has_key?(payload, "sha256")

      assert [event] = Nodes.events(kind: :upgraded)
      assert event.detail["image"] == @image
    end

    test "a cluster node needs nodes.registry to be upgraded" do
      node = enroll!("k3s", "cluster")
      attach!(node, hello())
      {:ok, _} = Settings.set_nodes_registry(nil)
      assert {:error, :unavailable} = Nodes.upgrade(node, @operator)
    end

    test "a machine node is unchanged: version and sha256" do
      node = enroll!("box", "machine")
      attach!(node, hello(%{}, %{"kind" => "machine"}))
      assert {:ok, %{version: @release, sha256: sha}} = Nodes.upgrade(node, @operator)
      assert is_binary(sha)
    end
  end

  describe "the outdated row" do
    defp row(node), do: Overview.get(node.id)

    test "without self-upgrade it carries the exact kubectl set image command" do
      node = enroll!("k3s", "cluster")
      attach!(node, hello(%{"self_upgrade" => false, "namespace" => "ci-workers"}))

      row = row(node)
      assert row.kind == :cluster
      assert row.health == :outdated
      assert row.image == @image

      assert row.upgrade_command ==
               "kubectl -n ci-workers set image deployment/arbiter-controller controller=#{@image}"
    end

    test "the namespace defaults to arbiter-workers" do
      node = enroll!("k3s", "cluster")
      attach!(node, hello())

      assert row(node).upgrade_command ==
               "kubectl -n arbiter-workers set image deployment/arbiter-controller controller=#{@image}"
    end

    test "a node that patches itself shows no command: it is on its way" do
      node = enroll!("k3s", "cluster")
      attach!(node, hello(%{"self_upgrade" => true}))
      row = row(node)
      assert row.health == :outdated
      assert row.self_upgrade? == true
      assert row.upgrade_command == nil
    end

    test "a current node, a machine and a node with no registry show no command" do
      current = enroll!("k3s", "cluster")
      attach!(current, hello(%{}, %{"agent_version" => "1.2.3"}))
      assert row(current).upgrade_command == nil

      machine = enroll!("box", "machine")
      attach!(machine, hello(%{}, %{"kind" => "machine"}))
      assert row(machine).upgrade_command == nil

      {:ok, _} = Settings.set_nodes_registry(nil)
      stale = enroll!("k3s-2", "cluster")
      attach!(stale, hello())
      assert row(stale).upgrade_command == nil
    end

    test "a cluster node that never connected has no command" do
      node = enroll!("never", "cluster")
      assert row(node).upgrade_command == nil
      assert row(node).kind == :cluster
    end
  end
end
