defmodule Arbiter.Worker.PodmanReadinessTest do
  # bd-46xndf (P1): every probe command is stubbed, so this runs on a host with
  # no podman at all.
  use ExUnit.Case, async: true

  alias Arbiter.Worker.PodmanReadiness

  @info %{
    "host" => %{
      "cgroupVersion" => "v2",
      "ociRuntime" => %{"name" => "crun"},
      "networkBackend" => "netavark",
      "security" => %{"rootless" => true}
    },
    "store" => %{"graphDriverName" => "overlay", "graphOptions" => %{}}
  }

  # A scripted host: map of "cmd arg arg" prefix => {output, status}. The
  # bridge `podman run` is answered by label mode.
  defp runner(overrides \\ %{}) do
    base = %{
      "podman --version" => {"podman version 5.8.7\n", 0},
      "podman info --format json" => {Jason.encode!(@info), 0},
      "getenforce" => {"Enforcing\n", 0},
      "podman image exists" => {"", 0},
      "podman run label=disable" => {"pong\n", 0},
      "podman run default" => {"connect: Permission denied\n", 1}
    }

    table = Map.merge(base, overrides)

    fn cmd, args, _opts ->
      key =
        cond do
          cmd == "podman" and List.first(args) == "run" and "label=disable" in args ->
            "podman run label=disable"

          cmd == "podman" and List.first(args) == "run" ->
            "podman run default"

          cmd == "podman" and Enum.take(args, 2) == ["image", "exists"] ->
            "podman image exists"

          true ->
            Enum.join([cmd | args], " ")
        end

      Map.get(table, key, {"unexpected: #{key}", 127})
    end
  end

  defp read_file(files \\ %{}) do
    base = %{
      "/etc/subuid" => "ryan:524288:65536\n",
      "/etc/subgid" => "ryan:524288:65536\n",
      "/proc/sys/user/max_user_namespaces" => "126539\n"
    }

    table = Map.merge(base, files)

    fn path ->
      case Map.fetch(table, path) do
        {:ok, body} -> {:ok, body}
        :error -> {:error, :enoent}
      end
    end
  end

  defp diagnose(runner_overrides \\ %{}, files \\ %{}) do
    PodmanReadiness.diagnose(
      runner: runner(runner_overrides),
      read_file: read_file(files),
      user: "ryan"
    )
  end

  defp check(report, id), do: Enum.find(report.checks, &(&1.id == id))

  test "a healthy Fedora-like host is ready and every check passes" do
    report = diagnose()
    assert report.ready
    assert report.installed
    assert Enum.all?(report.checks, &(&1.status in ["ok", "warn"]))

    for id <-
          ~w(podman rootless storage_driver subid user_namespaces selinux cgroups socket_bridge) do
      assert check(report, id).status == "ok", "#{id} should be ok"
    end

    assert check(report, "podman").detail =~ "5.8.7"
    assert check(report, "selinux").detail =~ "Enforcing"
  end

  test "podman missing is a single failure with an install hint" do
    report = diagnose(%{"podman --version" => {"enoent", 127}})
    refute report.ready
    refute report.installed
    assert [%{id: "podman", status: "fail", hint: hint}] = report.checks
    assert hint =~ "podman"
  end

  test "missing subuid range fails with an usermod hint" do
    report = diagnose(%{}, %{"/etc/subuid" => "other:100000:65536\n"})
    refute report.ready
    c = check(report, "subid")
    assert c.status == "fail"
    assert c.hint =~ "usermod --add-subuids"
  end

  test "a too-small subgid range fails" do
    report = diagnose(%{}, %{"/etc/subgid" => "ryan:524288:1000\n"})
    assert check(report, "subid").status == "fail"
  end

  test "user namespaces disabled fails with the sysctl hint" do
    report = diagnose(%{}, %{"/proc/sys/user/max_user_namespaces" => "0\n"})
    c = check(report, "user_namespaces")
    assert c.status == "fail"
    assert c.hint =~ "user.max_user_namespaces"
  end

  test "SELinux disabled or absent is ok" do
    report = diagnose(%{"getenforce" => {"enoent", 127}})
    assert check(report, "selinux").status == "ok"
    assert check(report, "selinux").detail =~ "not installed"
  end

  test "cgroups v1 warns (no rootless resource limits) but is not a failure" do
    info = put_in(@info, ["host", "cgroupVersion"], "v1")
    report = diagnose(%{"podman info --format json" => {Jason.encode!(info), 0}})
    c = check(report, "cgroups")
    assert c.status == "warn"
    assert c.hint =~ "cgroup"
    assert report.ready
  end

  test "fuse-overlayfs storage warns about copy throughput" do
    info =
      put_in(@info, ["store", "graphOptions"], %{
        "overlay.mount_program" => %{"Executable" => "/usr/bin/fuse-overlayfs"}
      })

    report = diagnose(%{"podman info --format json" => {Jason.encode!(info), 0}})
    c = check(report, "storage_driver")
    assert c.status == "warn"
    assert c.detail =~ "fuse-overlayfs"
    assert report.ready
  end

  test "the vfs storage driver fails" do
    info = put_in(@info, ["store", "graphDriverName"], "vfs")
    report = diagnose(%{"podman info --format json" => {Jason.encode!(info), 0}})
    assert check(report, "storage_driver").status == "fail"
    refute report.ready
  end

  test "rootful podman fails the rootless check" do
    info = put_in(@info, ["host", "security", "rootless"], false)
    report = diagnose(%{"podman info --format json" => {Jason.encode!(info), 0}})
    assert check(report, "rootless").status == "fail"
  end

  test "socket bridge: label=disable denied is a failure with the SELinux hint" do
    report = diagnose(%{"podman run label=disable" => {"connect: Permission denied\n", 1}})
    c = check(report, "socket_bridge")
    assert c.status == "fail"
    assert c.detail =~ "Permission denied"
    assert c.hint =~ "label=disable"
    refute report.ready
  end

  test "socket bridge: default label working too is noted in the detail" do
    report = diagnose(%{"podman run default" => {"pong\n", 0}})
    c = check(report, "socket_bridge")
    assert c.status == "ok"
    assert c.detail =~ "default"
  end

  test "socket bridge: a missing probe image fails with a pull hint" do
    report = diagnose(%{"podman image exists" => {"", 1}})
    c = check(report, "socket_bridge")
    assert c.status == "fail"
    assert c.hint =~ "podman pull"
  end

  test "the bridge self-test really listens on a unix socket the stub can reach" do
    test_pid = self()

    runner = fn
      "podman", ["run" | args], _opts ->
        mount = Enum.find(args, &String.contains?(&1, ":/proxy"))
        [dir, _] = String.split(mount, ":/proxy")
        send(test_pid, {:probe_dir, dir})

        {:ok, sock} =
          :gen_tcp.connect({:local, String.to_charlist(Path.join(dir, "bridge.sock"))}, 0, [
            :binary,
            active: false
          ])

        {:ok, data} = :gen_tcp.recv(sock, 0, 2000)
        :gen_tcp.close(sock)
        {data, 0}

      cmd, args, opts ->
        runner().(cmd, args, opts)
    end

    report =
      PodmanReadiness.diagnose(runner: runner, read_file: read_file(), user: "ryan")

    assert check(report, "socket_bridge").status == "ok"
    assert_received {:probe_dir, dir}
    refute File.exists?(dir)
  end
end
