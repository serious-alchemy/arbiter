defmodule Arbiter.Worker.ContainerSpawnNodeKindTest do
  @moduledoc """
  bd-2cbk73 (#971): the placement row's `kind` is an atom from `Overview`; the cluster
  network script must still be chosen for it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.Overview
  alias Arbiter.Worker.ContainerSpawn

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:arbiter, :data_dir)
    Application.put_env(:arbiter, :data_dir, Path.join(dir, "data"))

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :data_dir, v)
        :error -> Application.delete_env(:arbiter, :data_dir)
      end
    end)

    proxy = Path.join(dir, "proxy.sock")
    arb = Path.join(dir, "arb.sock")
    File.write!(proxy, "")
    File.write!(arb, "")

    request = %{
      name: "arb-t-1",
      image: %{tag: "localhost/x:1", plan: nil},
      worktree: "/work/tree",
      home: "/work/home",
      config_dir: "/work/config",
      config_files: %{},
      tmp_dir: "/work/tmp",
      cli: [],
      prompt_paths: [],
      network: [proxy_socket: proxy, socat: "socat", bridges: [{4848, arb}]],
      env: [],
      services: [],
      limits: %{},
      checkout: nil,
      task_id: "bd-t"
    }

    %{request: request, arb: arb}
  end

  defp command(request, kind, name) do
    {:ok, %{token: token}} =
      Nodes.mint_join_token([name: name, kind: kind], Actor.operator("cli"))

    {:ok, %{node: node}} = Nodes.redeem_join_token(token, %{kind: kind})
    row = Overview.get(node.id)

    request = Map.put(request, :node_kind, ContainerSpawn.node_kind(row))
    {:ok, spec} = ContainerSpawn.remote_spec(request, %{argv: ["claude"], env: []}, "run-1")
    {row, Enum.join(spec["command"], "\n")}
  end

  test "a cluster row (kind :cluster) selects the cluster script", %{request: request} do
    {row, text} = command(request, "cluster", "k3s")
    assert row.kind == :cluster
    refute text =~ "UNIX-CONNECT"
    assert text =~ "ARB_BRIDGE_ADDR"
  end

  test "a machine row (kind :machine) keeps the Unix-socket script", %{request: request} do
    {row, text} = command(request, "machine", "box")
    assert row.kind == :machine
    assert text =~ "UNIX-CONNECT:$2"
  end
end
