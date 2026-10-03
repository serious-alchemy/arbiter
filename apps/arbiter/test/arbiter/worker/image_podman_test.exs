defmodule Arbiter.Worker.ImagePodmanTest do
  @moduledoc """
  bd-9r5jdt (P4): the image lifecycle against a REAL rootless podman and the
  real registry.

  Opt-in (`@moduletag :podman`): it pulls `debian:trixie-slim` and runs the
  base layer's `apt-get install`, so it needs network and a minute or two:

      cd apps/arbiter && mix test --include podman test/arbiter/worker/image_podman_test.exs

  It removes the images it built, by exact tag (never a pattern).
  """
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Builder
  alias Arbiter.Worker.Image.Pins

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

  test "builds from the default branch with a digest-pinned base, caches, lists and prunes" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    dir = Path.join(System.tmp_dir!(), "img-podman-#{suffix}")
    root = Path.join(dir, "state")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, ".arbiter"))
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(repo, ["init", "-q", "-b", "main"])

    File.write!(
      Path.join(repo, ".arbiter/Containerfile"),
      "FROM ${ARBITER_BASE}\nRUN echo default-branch-#{suffix} > /toolchain-marker\n"
    )

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])
    git!(repo, ["checkout", "-q", "-b", "worker/evil"])

    File.write!(
      Path.join(repo, ".arbiter/Containerfile"),
      "FROM ${ARBITER_BASE}\nRUN echo evil > /toolchain-marker\n"
    )

    git!(repo, ["commit", "-q", "-am", "evil"])

    builder = start_supervised!({Builder, name: nil})
    opts = [root: root, scratch: Path.join(dir, "scratch"), server: builder, repo_name: suffix]

    {:ok, plan} = Image.plan(repo, "main", opts)

    on_exit(fn ->
      for tag <- [plan.tag, plan.base.tag], do: System.cmd("podman", ["rmi", tag])
    end)

    assert {:ok, %{tag: tag, built: built}} = Image.ensure(repo, "main", opts)
    assert tag == plan.tag
    assert built == [plan.base.tag, plan.tag]

    # The base was pinned by digest, and the pin was stored.
    assert plan.base.containerfile =~
             ~r/FROM docker\.io\/library\/debian:trixie-slim@sha256:[0-9a-f]{64}/

    assert Pins.load(root: root).pins["docker.io/library/debian:trixie-slim"]["digest"] =~
             "sha256:"

    # The default branch's file was built, not the worker branch's.
    {marker, 0} =
      System.cmd("podman", ["run", "--rm", "--pull=never", tag, "cat", "/toolchain-marker"])

    assert String.trim(marker) == "default-branch-#{suffix}"

    # The base carries the tools the design lists, and the CLI mount point.
    {tools, 0} =
      System.cmd("podman", [
        "run",
        "--rm",
        "--pull=never",
        tag,
        "sh",
        "-c",
        "command -v git socat pgrep && test -d /opt/arbiter/cli && echo cli-dir"
      ])

    assert tools =~ "cli-dir"

    # Asking again builds nothing.
    assert {:ok, %{built: []}} = Image.ensure(repo, "main", opts)

    # It is listed, and not pruned (it is the newest of its name).
    assert {:ok, images} = Image.list()
    assert Enum.any?(images, &(&1.tag == plan.tag and &1.kind == :toolchain))
    assert Enum.any?(images, &(&1.tag == plan.base.tag and &1.kind == :base))
    assert {:ok, %{removed: removed}} = Image.prune()
    refute plan.tag in removed
  end

  test "the generated default has a working Elixir/Erlang toolchain (and Node when pinned)" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    dir = Path.join(System.tmp_dir!(), "img-podman-gen-#{suffix}")
    root = Path.join(dir, "state")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(repo, ["init", "-q", "-b", "main"])

    File.write!(
      Path.join(repo, ".tool-versions"),
      "erlang 28.2\nelixir 1.19.4-otp-28\nnodejs 22.11.0\n"
    )

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])

    builder = start_supervised!({Builder, name: nil})
    opts = [root: root, scratch: Path.join(dir, "scratch"), server: builder]
    {:ok, plan} = Image.plan(repo, "main", opts)
    assert plan.source == :generated

    on_exit(fn ->
      for tag <- [plan.tag, plan.base.tag], do: System.cmd("podman", ["rmi", tag])
    end)

    assert {:ok, %{tag: tag}} = Image.ensure(repo, "main", opts)

    {out, status} =
      System.cmd(
        "podman",
        [
          "run",
          "--rm",
          "--pull=never",
          tag,
          "sh",
          "-c",
          "elixir --version; node --version; npm --version; git --version"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "Elixir 1.19.4"
    assert out =~ "Erlang/OTP 28"
    assert out =~ "v22.11.0"
  end
end
