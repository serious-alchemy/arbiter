defmodule Arbiter.Worker.Image.KnownHostsPodmanTest do
  @moduledoc """
  bd-290vof: the pinned forge host keys inside a REAL built worker base image.

  Opt-in (`@moduletag :podman`), needs network and a minute or two:

      cd apps/arbiter && mix test --include podman test/arbiter/worker/image/known_hosts_podman_test.exs

  It removes the images it built, by exact tag (never a pattern).
  """
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Builder

  @moduletag :podman
  @moduletag timeout: 900_000

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ++
          args,
        stderr_to_stdout: true
      )

    out
  end

  defp run!(tag, script) do
    {out, 0} =
      System.cmd("podman", ["run", "--rm", "--pull=never", tag, "sh", "-c", script],
        stderr_to_stdout: true
      )

    out
  end

  test "a built image verifies gitlab.com and github.com against /etc/ssh/ssh_known_hosts" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    dir = Path.join(System.tmp_dir!(), "img-hostkeys-#{suffix}")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, ".arbiter"))
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, ".arbiter/Containerfile"), "FROM ${ARBITER_BASE}\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])

    builder = start_supervised!({Builder, name: nil})
    opts = [root: Path.join(dir, "state"), scratch: Path.join(dir, "scratch"), server: builder]

    {:ok, plan} = Image.plan(repo, "main", opts)

    on_exit(fn ->
      for tag <- [plan.tag, plan.base.tag], do: System.cmd("podman", ["rmi", tag])
    end)

    assert {:ok, %{tag: tag}} = Image.ensure(repo, "main", opts)

    for host <- ["gitlab.com", "github.com"] do
      # The key is in the image's system file ...
      assert run!(tag, "ssh-keygen -F #{host} -f /etc/ssh/ssh_known_hosts") =~ "ssh-ed25519"

      # ... and ssh run the way the worker's GIT_SSH_COMMAND does (`-F /dev/null`,
      # a fresh HOME) reads it, with strict checking still on.
      cfg = run!(tag, "HOME=$(mktemp -d) ssh -G -F /dev/null git@#{host}")
      assert cfg =~ "globalknownhostsfile /etc/ssh/ssh_known_hosts"
      refute cfg =~ ~r/stricthostkeychecking (false|no|off|accept-new)/
    end
  end

  @tag :network
  test "git fetch over SSH from a built image gets past host key verification (BatchMode)" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    dir = Path.join(System.tmp_dir!(), "img-hostkeys-net-#{suffix}")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, ".arbiter"))
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, ".arbiter/Containerfile"), "FROM ${ARBITER_BASE}\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])

    builder = start_supervised!({Builder, name: nil})
    opts = [root: Path.join(dir, "state"), scratch: Path.join(dir, "scratch"), server: builder]
    {:ok, plan} = Image.plan(repo, "main", opts)

    on_exit(fn ->
      for tag <- [plan.tag, plan.base.tag], do: System.cmd("podman", ["rmi", tag])
    end)

    assert {:ok, %{tag: tag}} = Image.ensure(repo, "main", opts)

    # No credentials, so the forge refuses the key: that is the point. What must
    # not appear is the host key failure.
    out =
      run_any(
        tag,
        "HOME=$(mktemp -d) GIT_SSH_COMMAND='ssh -F /dev/null -o BatchMode=yes' " <>
          "git ls-remote git@gitlab.com:gitlab-org/gitlab.git 2>&1"
      )

    refute out =~ "Host key verification failed"
    assert out =~ "Permission denied"
  end

  defp run_any(tag, script) do
    {out, _} =
      System.cmd("podman", ["run", "--rm", "--pull=never", tag, "sh", "-c", script],
        stderr_to_stdout: true
      )

    out
  end
end
