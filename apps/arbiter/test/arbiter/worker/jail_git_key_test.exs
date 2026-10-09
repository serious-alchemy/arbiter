defmodule Arbiter.Worker.JailGitKeyTest do
  @moduledoc """
  G16 (bd-9cygoo): an agy worker's repo-scoped deploy key is the only identity its
  jail offers — bound at its own path over a blanked key dir, named by
  `GIT_SSH_COMMAND` (with the egress `ProxyCommand` composed on), and the
  operator's default identities are not bound back.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.Jail

  @moduletag :tmp_dir

  defp pairs(argv, flag) do
    argv
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [f | _] -> f == flag end)
    |> Enum.map(fn [_, a, b] -> {a, b} end)
  end

  defp repo(tmp) do
    wt = Path.join(tmp, "wt")
    File.mkdir_p!(wt)
    {_, 0} = System.cmd("git", ["init", "-q", wt])
    wt
  end

  test "every jail blanks the key dir, so a sibling worker's key is unreachable" do
    assert GitCredential.default_dir() in Jail.mask_paths()
  end

  test "the own key is bound read-only at its own path, after the root bind and the blanking" do
    key = Path.join(GitCredential.default_dir(), "abc/key")
    argv = Jail.argv(%{bwrap: "/usr/bin/bwrap", worktree: "/w/wt", git_ssh_key: key}, ["agy"])

    assert {key, key} in pairs(argv, "--ro-bind")
    root = Enum.find_index(argv, &(&1 == "--ro-bind"))
    assert root < Enum.find_index(argv, &(&1 == key))
  end

  test "no key: nothing is bound" do
    argv = Jail.argv(%{bwrap: "/usr/bin/bwrap", worktree: "/w/wt"}, ["agy"])
    refute Enum.any?(argv, &String.ends_with?(&1, "/key"))
  end

  test "wrap/2 names the key in GIT_SSH_COMMAND and refuses a key that is missing", %{
    tmp_dir: tmp
  } do
    wt = repo(tmp)
    key = Path.join(tmp, "key")
    File.write!(key, "K\n")

    assert {:ok, argv} = Jail.wrap(["true"], worktree: wt, git_ssh_key: key)
    assert {"GIT_SSH_COMMAND", cmd} = List.keyfind(pairs(argv, "--setenv"), "GIT_SSH_COMMAND", 0)
    assert cmd =~ "-i #{key}"
    assert cmd =~ "IdentitiesOnly=yes"
    assert cmd =~ "IdentityAgent=none"
    refute Enum.any?(pairs(argv, "--setenv"), &(elem(&1, 0) == "SSH_AUTH_SOCK"))

    assert {:error, {:git_ssh_key_missing, _}} =
             Jail.wrap(["true"], worktree: wt, git_ssh_key: Path.join(tmp, "nope"))
  end

  test "a scoped token credential (no deploy key) binds back no operator ssh identity or gh login",
       %{tmp_dir: tmp} do
    wt = repo(tmp)

    assert {:ok, argv} =
             Jail.wrap(["true"], worktree: wt, hide_reads: true, hide_repos: [], scoped_git: true)

    refute Enum.any?(argv, &Regex.match?(~r{/\.ssh/(id_[^/]*|[^/]*\.id_[^/]*)$}, &1))
    refute Enum.any?(argv, &String.ends_with?(&1, "/.config/gh/hosts.yml"))
    refute Enum.any?(pairs(argv, "--setenv"), &(elem(&1, 0) == "SSH_AUTH_SOCK"))
  end

  test "in network mode the proxy ProxyCommand is composed onto the key command", %{tmp_dir: tmp} do
    cmd = Jail.ssh_command("ssh " <> GitCredential.ssh_options("/k/key"), %{proxy_port: 3128})
    assert [{"GIT_SSH_COMMAND", value}] = cmd
    assert value =~ "-i /k/key"
    assert value =~ "ProxyCommand socat - PROXY:127.0.0.1:%h:%p,proxyport=3128"
    _ = tmp
  end
end
