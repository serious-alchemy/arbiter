defmodule Arbiter.Worker.WorktreePushEnvTest do
  @moduledoc """
  `Worktree.push/2` runs git with the `:env` it is given (a scoped host-side
  credential, `Arbiter.Worker.HostCredential`) on top of the server's own env.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Worktree

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    repo = Path.join(tmp, "work")
    remote = Path.join(tmp, "remote.git")

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "a"), "a\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "a"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "init"])
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])

    # A pre-push hook that records what the push's environment looked like.
    probe = Path.join(tmp, "probe")
    hook = Path.join(repo, ".git/hooks/pre-push")

    File.write!(hook, """
    #!/bin/sh
    printf '%s|%s' "${ARB_PROBE:-unset}" "${SSH_AUTH_SOCK:-unset}" > "#{probe}"
    """)

    File.chmod!(hook, 0o755)

    prior = System.get_env("SSH_AUTH_SOCK")
    System.put_env("SSH_AUTH_SOCK", "/operator/agent.sock")

    on_exit(fn ->
      if prior,
        do: System.put_env("SSH_AUTH_SOCK", prior),
        else: System.delete_env("SSH_AUTH_SOCK")
    end)

    %{repo: repo, probe: probe}
  end

  test "pushes with the given env: extra vars set, nil entries unset", %{repo: repo, probe: probe} do
    assert {:ok, _} =
             Worktree.push(repo, env: [{"ARB_PROBE", "scoped"}, {"SSH_AUTH_SOCK", nil}])

    assert File.read!(probe) == "scoped|unset"
  end

  test "without :env the server's own environment is inherited", %{repo: repo, probe: probe} do
    assert {:ok, _} = Worktree.push(repo)
    assert File.read!(probe) == "unset|/operator/agent.sock"
  end
end
