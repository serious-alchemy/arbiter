defmodule Arbiter.Worker.ArbCliTest do
  @moduledoc """
  bd-59m96o: the `arb` escript a worker container gets runs on an Erlang/OTP
  that can load it, whatever Erlang the repo's image pins.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Test.ArbEscriptFixture
  alias Arbiter.Worker.ArbCli

  @moduletag :tmp_dir

  describe "built_otp/1" do
    test "reads the OTP release from the escript's comment line", %{tmp_dir: dir} do
      path = ArbEscriptFixture.build!(dir, stamp: "29")
      assert ArbCli.built_otp(path) == {:ok, "29"}
    end

    test "an escript built before the stamp existed is unknown", %{tmp_dir: dir} do
      path = ArbEscriptFixture.build!(dir, stamp: nil)
      assert ArbCli.built_otp(path) == :error
    end

    test "a missing file, or one that is not an escript, is unknown", %{tmp_dir: dir} do
      assert ArbCli.built_otp(Path.join(dir, "nope")) == :error

      script = Path.join(dir, "script")
      File.write!(script, "#!/bin/sh\nexec true\n")
      assert ArbCli.built_otp(script) == :error
    end
  end

  describe "runtime_otp/1" do
    test "is the release the host's arb was built on", %{tmp_dir: dir} do
      arb = ArbEscriptFixture.build!(dir, stamp: "31")
      assert ArbCli.runtime_otp(arb_path: arb) == "31"
    end

    test "is the server's own release for an arb without the stamp, or no arb", %{tmp_dir: dir} do
      arb = ArbEscriptFixture.build!(dir, stamp: nil)
      assert ArbCli.runtime_otp(arb_path: arb) == System.otp_release()
      assert ArbCli.runtime_otp(arb_path: nil) == System.otp_release()
    end
  end

  describe "launcher_file/1 and mounts/2" do
    test "writes the launcher once, executable, named by its content", %{tmp_dir: dir} do
      assert {:ok, path} = ArbCli.launcher_file(launcher_dir: dir)
      assert Path.dirname(path) == dir
      assert File.read!(path) == ArbCli.launcher()
      assert Bitwise.band(File.stat!(path).mode, 0o111) == 0o111

      %File.Stat{mtime: written} = File.stat!(path, time: :posix)
      assert {:ok, ^path} = ArbCli.launcher_file(launcher_dir: dir)
      assert File.stat!(path, time: :posix).mtime == written
      assert File.ls!(dir) == [Path.basename(path)]
    end

    test "a launcher dir that cannot be made is an error", %{tmp_dir: dir} do
      blocker = Path.join(dir, "a-file")
      File.write!(blocker, "")

      assert {:error, {:arb_launcher_unwritable, _path, _reason}} =
               ArbCli.launcher_file(launcher_dir: Path.join(blocker, "cli"))
    end

    test "binds the launcher as arb and the escript beside it", %{tmp_dir: dir} do
      assert {:ok,
              [{launcher, "/opt/arbiter/cli/arb"}, {"/h/arb", "/opt/arbiter/cli/arb.escript"}]} =
               ArbCli.mounts("/h/arb", launcher_dir: dir)

      assert File.read!(launcher) == ArbCli.launcher()
    end
  end

  # The launcher is run for real: `sh`, `sed`, this VM's own OTP install as the
  # runtime the base image carries for arb, and a stand-in for the image's own
  # Erlang (an `erl` that prints a release and an `escript` that says it ran).
  describe "launcher/1" do
    setup %{tmp_dir: dir} do
      %{otp: System.otp_release(), runtime: to_string(:code.root_dir()), tools: tools!(dir)}
    end

    test "runs the escript on the runtime for arb, not on the image's older Erlang", ctx do
      script = ArbEscriptFixture.build!(ctx.tmp_dir)
      image = image_erlang!(ctx.tmp_dir, older(ctx.otp))

      assert {out, 0} = launch(ctx, script, image, ["version", "--json"])
      assert out =~ "arbfix otp=#{ctx.otp} args=version,--json"
      refute out =~ "image escript"
    end

    test "without a runtime, runs on the image's own Erlang when it is new enough", ctx do
      script = ArbEscriptFixture.build!(ctx.tmp_dir)
      image = image_erlang!(ctx.tmp_dir, ctx.otp)

      assert {out, 0} = launch(%{ctx | runtime: missing(ctx)}, script, image, ["inbox"])
      assert out =~ "image escript: #{script} inbox"
    end

    test "without a runtime, refuses an older Erlang clearly instead of running it", ctx do
      script = ArbEscriptFixture.build!(ctx.tmp_dir)
      image = image_erlang!(ctx.tmp_dir, older(ctx.otp))
      runtime = missing(ctx)

      assert {out, 69} = launch(%{ctx | runtime: runtime}, script, image, ["inbox"])
      assert out =~ "built on Erlang/OTP #{ctx.otp}"
      assert out =~ "the image's own Erlang is OTP #{older(ctx.otp)}"
      assert out =~ "no runtime for arb at #{runtime}"
      assert out =~ "ARBITER_BASE"
      refute out =~ "image escript"
    end

    test "with no Erlang at all and no runtime, says there is none", ctx do
      script = ArbEscriptFixture.build!(ctx.tmp_dir)
      empty = Path.join(ctx.tmp_dir, "no-erlang")
      File.mkdir_p!(empty)

      assert {out, 69} = launch(%{ctx | runtime: missing(ctx)}, script, empty, [])
      assert out =~ "the image's own Erlang is missing"
    end

    test "a runtime older than the escript is passed over", ctx do
      script = ArbEscriptFixture.build!(ctx.tmp_dir)
      stale = stale_runtime!(ctx.tmp_dir, older(ctx.otp))

      new_enough = image_erlang!(Path.join(ctx.tmp_dir, "new"), ctx.otp)
      assert {out, 0} = launch(%{ctx | runtime: stale}, script, new_enough, [])
      assert out =~ "image escript: #{script}"
      refute out =~ "stale runtime"

      too_old = image_erlang!(Path.join(ctx.tmp_dir, "old"), older(ctx.otp))
      assert {out, 69} = launch(%{ctx | runtime: stale}, script, too_old, [])
      assert out =~ "its runtime for arb (#{stale}) is OTP #{older(ctx.otp)}"
    end

    test "an escript without the stamp keeps the old behaviour", ctx do
      script = ArbEscriptFixture.build!(ctx.tmp_dir, stamp: nil)
      image = image_erlang!(ctx.tmp_dir, older(ctx.otp))

      assert {out, 0} = launch(ctx, script, image, ["x"])
      assert out =~ "arbfix otp=#{ctx.otp} args=x"

      assert {out, 0} = launch(%{ctx | runtime: missing(ctx)}, script, image, ["x"])
      assert out =~ "image escript: #{script} x"
    end

    test "an ERL_ROOTDIR in the worker's environment does not redirect the runtime", ctx do
      script = ArbEscriptFixture.build!(ctx.tmp_dir)
      image = image_erlang!(ctx.tmp_dir, older(ctx.otp))

      assert {out, 0} =
               launch(ctx, script, image, [], [{"ERL_ROOTDIR", Path.join(ctx.tmp_dir, "nope")}])

      assert out =~ "arbfix otp=#{ctx.otp}"
    end

    # The bug itself, on a real older Erlang/OTP: point ARB_TEST_OLD_OTP_ROOT at
    # an install of one (e.g. 27.1.2; `builds.hex.pm` has prebuilt ones).
    @tag skip:
           if(System.get_env("ARB_TEST_OLD_OTP_ROOT") in [nil, ""],
             do: "set ARB_TEST_OLD_OTP_ROOT to an older Erlang/OTP install (e.g. 27.1.2)"
           )
    test "a real older OTP cannot load the escript, and through the launcher it runs", ctx do
      old_bin = Path.join(System.fetch_env!("ARB_TEST_OLD_OTP_ROOT"), "bin")
      script = ArbEscriptFixture.build!(ctx.tmp_dir)

      {loaded, _} =
        System.cmd(Path.join(old_bin, "escript"), [script],
          env: [{"PATH", "#{old_bin}:#{ctx.tools}"}],
          stderr_to_stdout: true
        )

      assert loaded =~ "corrupt atom table"

      assert {out, 0} = launch(ctx, script, old_bin, ["version"])
      assert out =~ "arbfix otp=#{ctx.otp} args=version"

      {old, 0} =
        System.cmd(
          Path.join(old_bin, "erl"),
          ["-noshell", "-eval", "io:put_chars(erlang:system_info(otp_release)), halt()."],
          env: [{"PATH", "#{old_bin}:#{ctx.tools}"}]
        )

      assert {out, 69} = launch(%{ctx | runtime: missing(ctx)}, script, old_bin, [])
      assert out =~ "the image's own Erlang is OTP #{old}"
    end
  end

  # Write the launcher for `script` and `ctx.runtime` and run it with only
  # `image_bin` and the tools it needs on PATH.
  defp launch(ctx, script, image_bin, args, env \\ []) do
    launcher = Path.join(ctx.tmp_dir, "arb")
    File.write!(launcher, ArbCli.launcher(script: script, runtime: ctx.runtime))
    File.chmod!(launcher, 0o755)

    System.cmd(launcher, args,
      env: [{"PATH", "#{image_bin}:#{ctx.tools}"} | env],
      stderr_to_stdout: true
    )
  end

  # The few external commands `sh` scripts here use, and nothing Erlang.
  defp tools!(dir) do
    bin = Path.join(dir, "tools")
    File.mkdir_p!(bin)

    for tool <- ~w(sed dirname basename readlink cat uname grep head),
        exe = System.find_executable(tool),
        do: File.ln_s!(exe, Path.join(bin, tool))

    bin
  end

  # A stand-in for the Erlang a repo's image puts on PATH.
  defp image_erlang!(dir, release) do
    bin = Path.join(dir, "image-bin")
    File.mkdir_p!(bin)
    exe!(Path.join(bin, "erl"), "#!/bin/sh\nprintf '%s' '#{release}'\n")
    exe!(Path.join(bin, "escript"), "#!/bin/sh\necho \"image escript: $*\"\n")
    bin
  end

  # An install root whose release is older than the escript's.
  defp stale_runtime!(dir, release) do
    root = Path.join(dir, "stale-otp")
    File.mkdir_p!(Path.join(root, "releases/#{release}"))
    File.mkdir_p!(Path.join(root, "bin"))
    exe!(Path.join(root, "bin/escript"), "#!/bin/sh\necho stale runtime\n")
    root
  end

  defp missing(ctx), do: Path.join(ctx.tmp_dir, "no-runtime")

  defp older(release), do: Integer.to_string(String.to_integer(release) - 2)

  defp exe!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end
end
