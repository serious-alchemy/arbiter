defmodule Arbiter.Worker.SshAgentTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.SshAgent

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    for bin <- ~w(ssh-agent ssh-add ssh-keygen), is_nil(System.find_executable(bin)) do
      flunk("#{bin} is required for this test")
    end

    key_path = Path.join(tmp, "id_test")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key_path])
    # a short dir: AF_UNIX paths are capped at 107 bytes
    dir = Path.join(System.tmp_dir!(), "sa#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{key: File.read!(key_path), dir: dir}
  end

  defp keys(socket) do
    System.cmd("ssh-add", ["-l"], env: [{"SSH_AUTH_SOCK", socket}], stderr_to_stdout: true)
  end

  test "holds exactly the one key, at a socket only this dir exposes", %{key: key, dir: dir} do
    {:ok, agent} = SshAgent.start(owner: self(), key: key, dir: dir)

    assert File.exists?(agent.socket)
    assert Path.dirname(agent.socket) == dir
    assert {out, 0} = keys(agent.socket)
    assert out =~ "ED25519"
    assert length(String.split(out, "\n", trim: true)) == 1
  end

  test "the key never stays on disk", %{key: key, dir: dir} do
    {:ok, _agent} = SshAgent.start(owner: self(), key: key, dir: dir)
    files = dir |> File.ls!() |> Enum.reject(&String.ends_with?(&1, ".sock"))
    assert files == []
  end

  test "a second start for the same owner reuses the live agent", %{key: key, dir: dir} do
    {:ok, a} = SshAgent.start(owner: self(), key: key, dir: dir)
    {:ok, b} = SshAgent.start(owner: self(), key: key, dir: dir)
    assert a.socket == b.socket
    assert {_, 0} = keys(b.socket)
  end

  test "stop/1 removes the socket and the agent stops answering", %{key: key, dir: dir} do
    {:ok, agent} = SshAgent.start(owner: self(), key: key, dir: dir)
    ref = Process.monitor(agent.pid)
    :ok = SshAgent.stop(agent)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    refute File.exists?(agent.socket)
  end

  test "dies with its owner", %{key: key, dir: dir} do
    test = self()

    owner =
      spawn(fn ->
        {:ok, agent} = SshAgent.start(owner: self(), key: key, dir: dir)
        send(test, {:agent, agent})
        Process.sleep(:infinity)
      end)

    assert_receive {:agent, agent}, 10_000
    ref = Process.monitor(agent.pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    refute File.exists?(agent.socket)
  end

  test "a bad key is an error and leaves nothing running", %{dir: dir} do
    assert {:error, {:ssh_add_failed, _}} =
             SshAgent.start(owner: self(), key: "not a key\n", dir: dir)

    assert Path.wildcard(Path.join(dir, "*.sock")) == []
  end

  test "refuses a socket path past the AF_UNIX limit", %{key: key} do
    long = Path.join(System.tmp_dir!(), String.duplicate("d", 120))

    assert {:error, {:socket_path_too_long, _}} =
             SshAgent.start(owner: self(), key: key, dir: long)
  end
end
