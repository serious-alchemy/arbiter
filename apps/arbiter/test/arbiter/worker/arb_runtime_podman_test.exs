defmodule Arbiter.Worker.ArbRuntimePodmanTest do
  @moduledoc """
  bd-59m96o: `arb` in a REAL worker image whose repo pins Erlang/OTP 27.1.2
  (emricare tonic's `.tool-versions`), and in one with no Erlang of its own,
  against a real rootless podman and the real registry.

  Opt-in (`@moduletag :podman`): it builds the shared base (apt, plus the
  official Erlang image of this VM's OTP release as arb's runtime) and an
  Elixir 1.17.3 / OTP 27 toolchain layer, so it needs network and some
  minutes:

      cd apps/arbiter && mix test --include podman test/arbiter/worker/arb_runtime_podman_test.exs

  The escript is `Arbiter.Test.ArbEscriptFixture`, compiled by the OTP running
  the tests as arb is compiled by the host's, and mounted the way a dispatch
  mounts arb (`ContainerSpawn.cli_mounts/2`) into a container started the way a
  dispatch starts one (`Container.run/2`: read-only root, keep-id, no network,
  no capabilities). It removes the images it built, by exact tag.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Test.ArbEscriptFixture
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Builder

  @moduletag :podman
  @moduletag timeout: 1_800_000

  # The release OTP 27 cannot load: anything from OTP 28 on.
  @moduletag skip:
               if(String.to_integer(System.otp_release()) < 28,
                 do: "needs a VM on OTP 28 or newer, whose BEAM files OTP 27 cannot load"
               )

  setup do
    dir = Path.join(System.tmp_dir!(), "arb-otp-podman-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    escript = ArbEscriptFixture.build!(Path.join(dir, "cli"))
    claude = Path.join(dir, "claude")
    File.write!(claude, "#!/bin/sh\n")
    File.chmod!(claude, 0o755)

    {:ok, mounts} =
      ContainerSpawn.cli_mounts("claude",
        claude_path: claude,
        arb_path: escript,
        launcher_dir: Path.join(dir, "launcher")
      )

    %{dir: dir, mounts: mounts, builder: start_supervised!({Builder, name: nil})}
  end

  test "an image pinned to OTP 27 keeps its Erlang, and arb runs on the base's runtime", ctx do
    image = image!(ctx, %{".tool-versions" => "erlang 27.1.2\nelixir 1.17.3-otp-27\n"})

    # The repo's Erlang is the one it pins...
    assert {"27", 0} =
             run!(ctx, image, [
               "erl",
               "-noshell",
               "-eval",
               "io:put_chars(erlang:system_info(otp_release)), halt()."
             ])

    # ...which cannot load arb: the bug, still there for the image's own Erlang...
    assert {loaded, status} = run!(ctx, image, ["escript", "/opt/arbiter/cli/arb.escript"])
    assert status != 0
    assert loaded =~ "corrupt atom table"

    # ...and `arb` runs it on the runtime the base carries for it.
    assert {out, 0} = run!(ctx, image, ["arb", "version"])
    assert out =~ "arbfix otp=#{System.otp_release()} args=version"
  end

  test "an image with no Erlang of its own runs arb too", ctx do
    image = image!(ctx, %{".arbiter/Containerfile" => "FROM ${ARBITER_BASE}\n"})

    assert {_, status} = run!(ctx, image, ["sh", "-c", "command -v erl"])
    assert status != 0

    assert {out, 0} = run!(ctx, image, ["arb", "inbox"])
    assert out =~ "arbfix otp=#{System.otp_release()} args=inbox"
  end

  defp image!(ctx, files) do
    repo = Path.join(ctx.dir, "repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])

    for {path, body} <- files do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), body)
    end

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])

    opts = [
      root: Path.join(ctx.dir, "state"),
      scratch: Path.join(ctx.dir, "scratch"),
      server: ctx.builder,
      repo_name: "arb-otp",
      arb_otp: System.otp_release()
    ]

    {:ok, plan} = Image.plan(repo, "main", opts)

    on_exit(fn ->
      for tag <- [plan.tag, plan.base.tag], do: System.cmd("podman", ["rmi", tag])
    end)

    assert {:ok, %{tag: tag}} = Image.ensure(repo, "main", opts)
    tag
  end

  defp run!(ctx, image, command) do
    name = Container.name_for("arb-otp-#{System.unique_integer([:positive])}")
    on_exit(fn -> Container.stop(name) end)

    assert {:ok, {out, status}} =
             Container.run(command,
               worktree: ctx.dir,
               name: name,
               image: image,
               cli_mounts: ctx.mounts,
               timeout: 120_000
             )

    {String.trim(out), status}
  end

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
end
