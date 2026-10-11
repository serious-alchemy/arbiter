defmodule ArbiterWeb.SocketPathRootTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards against Unix socket paths built from `System.tmp_dir!()`, which
  overflows `sun_path` under podman's deep TMPDIR (bd-1m47qc).
  """

  @files [
    "apps/arbiter_web/test/arbiter_web/node_bridge_e2e_test.exs",
    "apps/arbiter_web/test/arbiter_web/worker_bridge_identity_test.exs",
    "apps/arbiter_web/test/spike/bridge_mux_test.exs",
    "apps/arbiter_web/test/spike/bridge_mux_product_test.exs",
    "apps/arbiter/test/arbiter/mcp/operator_socket_test.exs",
    "apps/arbiter_cli/test/support/fake_operator_socket.ex"
  ]

  test "socket-binding tests root at Paths.socket_root/0" do
    root = Path.expand("../../../..", __DIR__)

    for f <- @files do
      src = File.read!(Path.join(root, f))
      refute src =~ "System.tmp_dir!", "#{f} builds a socket path under System.tmp_dir!"
      assert src =~ "socket_root()", "#{f} must use Paths.socket_root/0"
    end
  end

  test "socket_root stays short even with a deep TMPDIR" do
    deep = "/tmp/" <> String.duplicate("d", 120)
    old = System.get_env("TMPDIR")
    System.put_env("TMPDIR", deep)

    try do
      path = Path.join(Arbiter.Config.Paths.socket_root(), "be-123456789/node.sock")
      assert byte_size(path) < 100
    after
      if old, do: System.put_env("TMPDIR", old), else: System.delete_env("TMPDIR")
    end
  end
end
