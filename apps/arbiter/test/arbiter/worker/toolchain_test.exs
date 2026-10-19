defmodule Arbiter.Worker.ToolchainTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Toolchain

  @moduletag :tmp_dir

  defp worktree(tmp_dir, tool_versions) do
    dir = Path.join(tmp_dir, "wt")
    File.mkdir_p!(dir)
    if tool_versions, do: File.write!(Path.join(dir, ".tool-versions"), tool_versions)
    dir
  end

  defp install!(root, tool, version) do
    bin = Path.join([root, tool, version, "bin"])
    File.mkdir_p!(bin)
    exe = if tool == "elixir", do: "elixir", else: "erl"
    File.write!(Path.join(bin, exe), "#!/bin/sh\n")
    File.chmod!(Path.join(bin, exe), 0o755)
    bin
  end

  # A stand-in for `elixir --version` that reports what the pinned install claims.
  defp runner(output, status \\ 0), do: fn _path -> {output, status} end

  defp version_output(elixir, otp) do
    "Erlang/OTP #{otp} [erts-17.1] [64-bit]\n\nElixir #{elixir} (compiled with Erlang/OTP #{otp})\n"
  end

  describe "parse/1" do
    test "reads the elixir and erlang pins, with the otp major from the elixir suffix" do
      assert {:ok, pins} =
               Toolchain.parse("erlang 29.1.1\nelixir 1.20.4-otp-29 # comment\nnodejs 22.1.0\n")

      assert pins.elixir == "1.20.4"
      assert pins.elixir_dir == "1.20.4-otp-29"
      assert pins.erlang == "29.1.1"
      assert pins.otp == "29"
    end

    test "takes the otp major from erlang when elixir has no suffix" do
      assert {:ok, %{otp: "27", elixir: "1.17.3", elixir_dir: "1.17.3"}} =
               Toolchain.parse("erlang 27.1.2\nelixir 1.17.3\n")
    end

    test "no elixir or erlang line is :none" do
      assert Toolchain.parse("nodejs 22.1.0\n") == {:ok, :none}
      assert Toolchain.parse("") == {:ok, :none}
    end

    test "a pin that is not a plain version is refused, not ignored" do
      for bad <- ["system", "latest", "ref:main", "path:/opt/elixir", "1.x"] do
        assert {:error, {:unsupported_pin, "elixir", ^bad}} = Toolchain.parse("elixir #{bad}\n")
      end

      assert {:error, {:unsupported_pin, "erlang", "system"}} = Toolchain.parse("erlang system\n")
    end
  end

  describe "env/3" do
    test "an unpinned worktree is left alone", %{tmp_dir: tmp} do
      env = [{"PATH", "/usr/local/bin:/usr/bin"}]
      assert {:ok, ^env} = Toolchain.env(worktree(tmp, nil), env, roots: [Path.join(tmp, "i")])
    end

    test "puts the pinned bin dirs first on PATH", %{tmp_dir: tmp} do
      root = Path.join(tmp, "installs")
      ebin = install!(root, "elixir", "1.20.4-otp-29")
      obin = install!(root, "erlang", "29.1.1")
      wt = worktree(tmp, "erlang 29.1.1\nelixir 1.20.4-otp-29\n")

      assert {:ok, env} =
               Toolchain.env(wt, [{"PATH", "/usr/local/bin:/usr/bin"}],
                 roots: [root],
                 runner: runner(version_output("1.20.4", "29"))
               )

      assert {"PATH", path} = List.keyfind(env, "PATH", 0)
      assert path == "#{ebin}:#{obin}:/usr/local/bin:/usr/bin"
    end

    test "falls back to the server's PATH when the env carries none", %{tmp_dir: tmp} do
      root = Path.join(tmp, "installs")
      ebin = install!(root, "elixir", "1.17.3")
      wt = worktree(tmp, "elixir 1.17.3\n")

      assert {:ok, [{"PATH", path}]} =
               Toolchain.env(wt, [],
                 roots: [root],
                 runner: runner(version_output("1.17.3", "27"))
               )

      assert String.starts_with?(path, ebin <> ":")
    end

    test "fails closed when the pinned version is not installed and cannot be provisioned",
         %{tmp_dir: tmp} do
      root = Path.join(tmp, "installs")
      install!(root, "elixir", "1.19.4")
      wt = worktree(tmp, "elixir 1.20.4-otp-29\n")

      assert {:error, {:toolchain_unavailable, message}} =
               Toolchain.env(wt, [{"PATH", "/usr/local/bin"}],
                 roots: [root],
                 provision: fn _tools -> {:error, "no mise on this host"} end
               )

      assert message =~ "elixir 1.20.4-otp-29"
      assert message =~ "no mise on this host"
      assert message =~ "host"
    end

    test "provisions the missing version, then uses it", %{tmp_dir: tmp} do
      root = Path.join(tmp, "installs")
      wt = worktree(tmp, "erlang 29.1.1\nelixir 1.20.4-otp-29\n")
      test_pid = self()

      provision = fn tools ->
        send(test_pid, {:provision, tools})
        install!(root, "elixir", "1.20.4-otp-29")
        install!(root, "erlang", "29.1.1")
        :ok
      end

      assert {:ok, [{"PATH", path}]} =
               Toolchain.env(wt, [{"PATH", "/usr/bin"}],
                 roots: [root],
                 provision: provision,
                 runner: runner(version_output("1.20.4", "29"))
               )

      assert_received {:provision, ["erlang@29.1.1", "elixir@1.20.4-otp-29"]}
      assert path =~ "elixir/1.20.4-otp-29/bin"
    end

    test "provisioning that leaves the version missing still fails closed", %{tmp_dir: tmp} do
      wt = worktree(tmp, "elixir 1.20.4\n")

      assert {:error, {:toolchain_unavailable, message}} =
               Toolchain.env(wt, [], roots: [Path.join(tmp, "i")], provision: fn _ -> :ok end)

      assert message =~ "still not installed"
    end

    test "provisioning is skipped when disabled", %{tmp_dir: tmp} do
      wt = worktree(tmp, "elixir 1.20.4\n")

      assert {:error, {:toolchain_unavailable, message}} =
               Toolchain.env(wt, [],
                 roots: [Path.join(tmp, "i")],
                 provision: fn _ -> flunk("must not provision") end,
                 provision?: false
               )

      assert message =~ "not installed"
    end

    test "refuses an install that reports a different OTP", %{tmp_dir: tmp} do
      root = Path.join(tmp, "installs")
      install!(root, "elixir", "1.20.4-otp-29")
      wt = worktree(tmp, "elixir 1.20.4-otp-29\n")

      assert {:error, {:toolchain_unavailable, message}} =
               Toolchain.env(wt, [{"PATH", "/usr/bin"}],
                 roots: [root],
                 runner: runner(version_output("1.20.4", "28"))
               )

      assert message =~ "OTP 28"
    end

    test "refuses an install that reports a different Elixir", %{tmp_dir: tmp} do
      root = Path.join(tmp, "installs")
      install!(root, "elixir", "1.20.4-otp-29")
      wt = worktree(tmp, "elixir 1.20.4-otp-29\n")

      assert {:error, {:toolchain_unavailable, message}} =
               Toolchain.env(wt, [{"PATH", "/usr/bin"}],
                 roots: [root],
                 runner: runner(version_output("1.19.4", "28"))
               )

      assert message =~ "1.19.4"
    end

    test "refuses an install whose elixir does not run", %{tmp_dir: tmp} do
      root = Path.join(tmp, "installs")
      install!(root, "elixir", "1.20.4")
      wt = worktree(tmp, "elixir 1.20.4\n")

      assert {:error, {:toolchain_unavailable, message}} =
               Toolchain.env(wt, [{"PATH", "/usr/bin"}], roots: [root], runner: runner("boom", 1))

      assert message =~ "boom"
    end

    test "an unsupported pin is a toolchain error, never the host's elixir", %{tmp_dir: tmp} do
      wt = worktree(tmp, "elixir system\n")

      assert {:error, {:toolchain_unavailable, message}} =
               Toolchain.env(wt, [{"PATH", "/usr/local/bin"}], roots: [Path.join(tmp, "i")])

      assert message =~ "system"
    end

    test "a later root is used when the first lacks the version", %{tmp_dir: tmp} do
      empty = Path.join(tmp, "mise")
      asdf = Path.join(tmp, "asdf")
      ebin = install!(asdf, "elixir", "1.20.4")
      wt = worktree(tmp, "elixir 1.20.4\n")

      assert {:ok, [{"PATH", path}]} =
               Toolchain.env(wt, [{"PATH", "/usr/bin"}],
                 roots: [empty, asdf],
                 runner: runner(version_output("1.20.4", "29"))
               )

      assert String.starts_with?(path, ebin <> ":")
    end
  end

  describe "check_containerfile/2" do
    test "agrees when the Containerfile FROM matches the pin" do
      cf = "FROM docker.io/hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20240904\n"
      assert Toolchain.check_containerfile("erlang 27.1.2\nelixir 1.17.3-otp-27\n", cf) == :ok
    end

    test "agrees for the official library image tag" do
      cf = "FROM docker.io/library/elixir:1.20.4-otp-29-slim AS build\n"
      assert Toolchain.check_containerfile("elixir 1.20.4-otp-29\n", cf) == :ok
    end

    test "refuses a different Elixir" do
      cf = "FROM hexpm/elixir:1.19.4-erlang-28.2-debian-bookworm\n"

      assert {:error, {:containerfile_pin_mismatch, message}} =
               Toolchain.check_containerfile("erlang 29.1.1\nelixir 1.20.4-otp-29\n", cf)

      assert message =~ "1.19.4"
      assert message =~ "1.20.4"
    end

    test "refuses a different OTP major" do
      cf = "FROM hexpm/elixir:1.20.4-erlang-28.2-debian-bookworm\n"

      assert {:error, {:containerfile_pin_mismatch, message}} =
               Toolchain.check_containerfile("erlang 29.1.1\nelixir 1.20.4\n", cf)

      assert message =~ "OTP 28"
    end

    test "cannot judge a templated FROM, so it passes" do
      cf = "ARG V=1\nFROM hexpm/elixir:${V}-erlang-28.2\n"
      assert Toolchain.check_containerfile("elixir 1.20.4-otp-29\n", cf) == :ok
    end

    test "no Containerfile, no pin, or no Elixir image is fine" do
      assert Toolchain.check_containerfile("elixir 1.20.4\n", nil) == :ok
      assert Toolchain.check_containerfile(nil, "FROM hexpm/elixir:1.1.1-erlang-1\n") == :ok
      assert Toolchain.check_containerfile("elixir 1.20.4\n", "FROM debian:trixie\n") == :ok
    end

    test "an unsupported pin is refused" do
      assert {:error, {:unsupported_pin, "elixir", "latest"}} =
               Toolchain.check_containerfile("elixir latest\n", "FROM debian\n")
    end
  end
end
