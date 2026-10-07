defmodule Arbiter.Worker.ContainerSpawnRemoteSpecTest do
  @moduledoc "RW12: the remote run spec carries the install id the node reaps by (§10.6)."
  use ExUnit.Case, async: false

  alias Arbiter.Nodes.InstallId
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
    File.write!(proxy, "")

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
      network: [proxy_socket: proxy, socat: "socat"],
      env: [],
      services: [],
      limits: %{},
      checkout: nil,
      task_id: "bd-t"
    }

    %{request: request}
  end

  test "the spec names the install", %{request: request} do
    assert {:ok, spec} =
             ContainerSpawn.remote_spec(request, %{argv: ["claude"], env: []}, "run-1")

    assert spec["install"] == InstallId.get()
  end
end
