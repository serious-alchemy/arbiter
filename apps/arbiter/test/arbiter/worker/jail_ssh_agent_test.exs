defmodule Arbiter.Worker.JailSshAgentTest do
  @moduledoc """
  G14 (bd-ld8qde): a `prod_ssh` worker's per-worker `ssh-agent` socket is the
  only agent socket its jail can see, exported as `SSH_AUTH_SOCK`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Jail

  @sock "/scratch/ssh-agent/a1.sock"

  defp spec(extra \\ %{}),
    do: Map.merge(%{bwrap: "/usr/bin/bwrap", worktree: "/w/wt"}, extra)

  defp pairs(argv, flag) do
    argv
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [f | _] -> f == flag end)
    |> Enum.map(fn [_, a, b] -> {a, b} end)
  end

  test "no agent: no extra mount and no SSH_AUTH_SOCK" do
    argv = Jail.argv(spec(), ["agy"])
    refute {"SSH_AUTH_SOCK", @sock} in pairs(argv, "--setenv")
    refute @sock in argv
  end

  test "binds only the agent's own socket over a blanked agent dir, after the root bind" do
    argv = Jail.argv(spec(%{ssh_agent: @sock}), ["agy"])

    tmpfs =
      argv
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_index(&(&1 == ["--tmpfs", Path.dirname(@sock)]))

    assert tmpfs
    assert {@sock, @sock} in pairs(argv, "--ro-bind")

    root = Enum.find_index(argv, &(&1 == "--ro-bind"))
    sock = Enum.find_index(argv, &(&1 == @sock))
    assert root < tmpfs
    assert tmpfs < sock
  end

  test "exports SSH_AUTH_SOCK pointing at it" do
    argv = Jail.argv(spec(%{ssh_agent: @sock}), ["agy"])
    assert {"SSH_AUTH_SOCK", @sock} in pairs(argv, "--setenv")
  end

  test "wrap/2 turns the :ssh_agent option into the spec" do
    dir = Path.join(System.tmp_dir!(), "jsa#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "wt"))
    on_exit(fn -> File.rm_rf(dir) end)
    sock = Path.join(dir, "a.sock")
    File.write!(sock, "")

    {_, 0} = System.cmd("git", ["init", "-q", Path.join(dir, "wt")])

    assert {:ok, argv} = Jail.wrap(["true"], worktree: Path.join(dir, "wt"), ssh_agent: sock)
    assert {"SSH_AUTH_SOCK", sock} in pairs(argv, "--setenv")
  end

  test "wrap/2 refuses an agent socket that is not there: never silently run without it" do
    dir = Path.join(System.tmp_dir!(), "jsa#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "wt"))
    on_exit(fn -> File.rm_rf(dir) end)
    {_, 0} = System.cmd("git", ["init", "-q", Path.join(dir, "wt")])

    assert {:error, {:ssh_agent_socket_missing, _}} =
             Jail.wrap(["true"],
               worktree: Path.join(dir, "wt"),
               ssh_agent: Path.join(dir, "nope.sock")
             )
  end
end
