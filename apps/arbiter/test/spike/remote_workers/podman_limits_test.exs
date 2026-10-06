defmodule Arbiter.Spike.PodmanLimitsTest do
  @moduledoc """
  RW2 spike (bd-6tx1xv), docs/design/remote-workers.md **U8** (rootless memory
  cap + OOMKilled without `--rm`) and **U13** (secrets never reach disk on the
  node). Real rootless podman, so excluded by default:
  `mix test --include spike_rw <this file>`.

  Anything that can allocate runs under
  `systemd-run --user --scope -p MemoryMax=3G` so a regression cannot take the
  host down (the laptop shares RAM with live workers).
  """
  use ExUnit.Case, async: false

  @moduletag :spike_rw
  @moduletag timeout: 300_000

  @image System.get_env("SPIKE_IMAGE", "docker.io/library/debian:12")
  @xdg System.get_env("XDG_RUNTIME_DIR") || "/run/user/#{System.get_env("UID", "1000")}"

  setup_all do
    if System.find_executable("podman") == nil, do: raise("podman not installed")
    {out, code} = podman(["image", "exists", @image])
    if code != 0, do: raise("image #{@image} not present (podman pull it): #{out}")
    :ok
  end

  defp env, do: [{"XDG_RUNTIME_DIR", @xdg}]

  defp podman(args, extra_env \\ [], capped? \\ true) do
    {cmd, argv} =
      if capped?,
        do:
          {"systemd-run",
           ["--user", "--scope", "-q", "-p", "MemoryMax=3G", "--", "podman" | args]},
        else: {"podman", args}

    System.cmd(cmd, argv, env: env() ++ extra_env, stderr_to_stdout: true)
  end

  defp name(prefix), do: "rw2-#{prefix}-#{System.unique_integer([:positive])}"

  defp inspect_fmt(name, fmt) do
    {out, 0} =
      System.cmd("podman", ["inspect", name, "--format", fmt], env: env(), stderr_to_stdout: true)

    String.trim(out)
  end

  defp rm(name),
    do: System.cmd("podman", ["rm", "-f", "-t", "0", name], env: env(), stderr_to_stdout: true)

  # 300 MB resident: `reverse` forces a second copy, so 64 MiB cannot hold it.
  @hog ~s|print scalar reverse("a" x 300000000)|

  describe "U8 memory cap" do
    test "--memory/--memory-swap are enforced rootless and OOMKilled survives without --rm" do
      n = name("oom")
      on_exit(fn -> rm(n) end)

      {_out, code} =
        podman([
          "run",
          "--name",
          n,
          "--memory=64m",
          "--memory-swap=64m",
          "--cpus=1",
          @image,
          "perl",
          "-e",
          @hog
        ])

      assert code == 137
      assert inspect_fmt(n, "{{.State.OOMKilled}}") == "true"
      assert inspect_fmt(n, "{{.State.ExitCode}}") == "137"

      assert inspect_fmt(
               n,
               "{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.NanoCpus}}"
             ) ==
               "67108864 67108864 1000000000"
    end

    test "control: a run inside the cap exits 0 with OOMKilled=false" do
      n = name("ok")
      on_exit(fn -> rm(n) end)

      {_out, code} =
        podman([
          "run",
          "--name",
          n,
          "--memory=64m",
          "--memory-swap=64m",
          @image,
          "perl",
          "-e",
          ~s|print scalar reverse("a" x 10000000)|
        ])

      assert code == 0
      assert inspect_fmt(n, "{{.State.OOMKilled}}") == "false"
    end

    test "with --rm the container (and its OOMKilled flag) is gone before anyone can read it" do
      n = name("rm")

      {_out, code} =
        podman([
          "run",
          "--rm",
          "--name",
          n,
          "--memory=64m",
          "--memory-swap=64m",
          @image,
          "perl",
          "-e",
          @hog
        ])

      assert code == 137
      assert {_, code} = System.cmd("podman", ["inspect", n], env: env(), stderr_to_stdout: true)
      assert code != 0
    end

    test "the in-container cgroup carries the limit" do
      {out, 0} =
        podman([
          "run",
          "--rm",
          "--memory=64m",
          "--memory-swap=64m",
          @image,
          "cat",
          "/sys/fs/cgroup/memory.max",
          "/sys/fs/cgroup/memory.swap.max"
        ])

      assert String.split(out) == ["67108864", "0"]
    end

    test "a controller that is not delegated is a hard OCI error, not a silent no-op (cpuset here)" do
      {controllers, 0} =
        System.cmd(
          "podman",
          ["info", "--format", "{{range .Host.CgroupControllers}}{{.}} {{end}}"],
          env: env()
        )

      if "cpuset" in String.split(controllers) do
        flunk("cpuset is delegated on this host; the negative case cannot be shown here")
      else
        {out, code} = podman(["run", "--rm", "--cpuset-cpus=0", @image, "true"])
        assert code != 0
        assert out =~ "controller `cpuset` is not available"
      end
    end
  end

  describe "U13 secrets on disk" do
    @tag :tmp_dir
    test "env passed with -e NAME (the design's inherit_env path) IS persisted by podman; a tmpfs env-file mount is not",
         %{tmp_dir: _} do
      marker = "ARBSPIKE_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      roots =
        [
          Path.expand("~/.local/share/containers"),
          Path.join(@xdg, "containers"),
          Path.join(@xdg, "libpod"),
          Path.expand("~/.config/containers")
        ]
        |> Enum.filter(&File.exists?/1)

      scan = fn ->
        {out, _} = System.cmd("grep", ["-rlaFs", marker | roots], stderr_to_stdout: true)
        out |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "grep:"))
      end

      # A. the design's path: value in the podman client's environment, `-e NAME`.
      a = name("secret-env")
      on_exit(fn -> rm(a) end)

      {_, 0} =
        podman(
          ["run", "-d", "--name", a, "-e", "SPIKE_TOKEN", @image, "sleep", "30"],
          [{"SPIKE_TOKEN", marker}],
          false
        )

      hits_env = scan.()
      rm(a)
      hits_env_after_rm = scan.()

      # B. fallback: the value only exists in a 0600 file on tmpfs, bind-mounted and sourced in-container.
      dir = Path.join(@xdg, "rw2-spike-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      file = Path.join(dir, "secrets.env")
      File.write!(file, "export SPIKE_TOKEN=#{marker}\n")
      File.chmod!(file, 0o600)
      on_exit(fn -> File.rm_rf(dir) end)
      b = name("secret-file")
      on_exit(fn -> rm(b) end)

      {_, 0} =
        podman(
          [
            "run",
            "-d",
            "--name",
            b,
            "-v",
            "#{file}:/run/arbiter/secrets.env:ro,Z",
            @image,
            "sh",
            "-c",
            ". /run/arbiter/secrets.env; exec sleep 30"
          ],
          [],
          false
        )

      Process.sleep(500)
      # the process really has it (so the fallback is functional, not just silent)...
      {raw_environ, 0} = System.cmd("podman", ["exec", b, "cat", "/proc/1/environ"], env: env())
      environ = String.replace(raw_environ, <<0>>, "\n")

      assert environ =~ "SPIKE_TOKEN=#{marker}"
      hits_file = scan.()
      {inspect_out, 0} = System.cmd("podman", ["inspect", b], env: env())
      refute inspect_out =~ marker
      rm(b)
      File.rm_rf!(dir)
      hits_file_after_rm = scan.()

      IO.puts(
        "SPIKE_RESULT " <>
          Jason.encode!(%{
            u13: %{
              env_inherit_hits_while_running:
                Enum.map(hits_env, &Path.relative_to(&1, Path.expand("~"))),
              env_inherit_hits_after_rm: hits_env_after_rm,
              tmpfs_file_hits_while_running: hits_file,
              tmpfs_file_hits_after_rm: hits_file_after_rm,
              xdg_runtime_dir_fstype:
                elem(System.cmd("stat", ["-f", "-c", "%T", @xdg]), 0) |> String.trim(),
              graphroot_fstype:
                elem(
                  System.cmd("stat", ["-f", "-c", "%T", Path.expand("~/.local/share/containers")]),
                  0
                )
                |> String.trim()
            }
          })
      )

      # Characterisation of the NO-GO: the env value is written to the OCI spec / state DB on disk.
      assert Enum.any?(hits_env, &String.ends_with?(&1, "/userdata/config.json")),
             "expected the OCI config.json under the graph root to hold the env value: #{inspect(hits_env)}"

      assert Enum.any?(hits_env, &String.ends_with?(&1, "/db.sql")),
             "expected podman's state DB to hold the env value: #{inspect(hits_env)}"

      # ...and that is on the *graph root* (persistent), not $XDG_RUNTIME_DIR (tmpfs).
      assert Enum.all?(hits_env, &String.contains?(&1, "/.local/share/containers/"))
      # The fallback leaves no hit anywhere podman writes.
      assert hits_file == []
      assert hits_file_after_rm == []
    end
  end
end
