defmodule Arbiter.Config.SocketRootTest do
  use ExUnit.Case, async: true

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.{Egress, SshAgent}

  # sockaddr_un.sun_path is 108 bytes on Linux, 104 on macOS/BSD.
  @sun_path_limit 104

  # A real run id is ~30 bytes; budget 48 (the 64-byte validation cap would
  # overflow any non-trivial root) plus the longest bridge name (16).
  @run_id String.duplicate("r", 48)

  test "socket_root/0 is independent of how deep HOME/TMPDIR/scratch are" do
    deep = Path.join(["/home/ryan/.cache/arbiter/scratch/worker-tmp", String.duplicate("x", 60)])
    prior = Application.get_env(:arbiter, :scratch_root)
    Application.put_env(:arbiter, :scratch_root, deep)

    try do
      refute String.starts_with?(Paths.socket_root(), deep)
      assert byte_size(Paths.socket_root()) <= 20
    after
      if prior,
        do: Application.put_env(:arbiter, :scratch_root, prior),
        else: Application.delete_env(:arbiter, :scratch_root)
    end
  end

  test "default egress, bridge and ssh-agent socket paths stay under sun_path" do
    paths = [
      Egress.socket_path(@run_id),
      Egress.bridge_path(@run_id, String.duplicate("b", 16)),
      SshAgent.socket_path(self(), SshAgent.default_dir())
    ]

    for path <- paths do
      assert byte_size(path) < @sun_path_limit, "#{path} is #{byte_size(path)} bytes"
    end
  end
end
