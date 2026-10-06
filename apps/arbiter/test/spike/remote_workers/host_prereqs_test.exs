defmodule Arbiter.Spike.HostPrereqsTest do
  @moduledoc """
  RW2 spike (bd-6tx1xv), docs/design/remote-workers.md **U9** (linger) and
  **U10** (memory-controller delegation detection). The probes are the bash in
  `prereq_checks.sh` (a prototype of the join script's checks); fixtures cover
  the layouts this host cannot produce, and the live host proves the real read.

  Excluded by default: `mix test --include spike_rw <this file>`.
  """
  use ExUnit.Case, async: false

  @moduletag :spike_rw
  @moduletag :tmp_dir

  @script Path.expand("prereq_checks.sh", __DIR__)

  defp run(snippet, env \\ [], path_prefix \\ nil) do
    path =
      if path_prefix,
        do: path_prefix <> ":" <> System.get_env("PATH"),
        else: System.get_env("PATH")

    System.cmd("bash", ["-c", ". #{@script}; #{snippet}"],
      env: [{"PATH", path} | env],
      stderr_to_stdout: true
    )
  end

  # A fixture cgroup tree: <root>/user.slice/user-<uid>.slice/user@<uid>.service/{cgroup.controllers,cgroup.subtree_control}
  defp cgroup_fixture(tmp, name, controllers, subtree) do
    root = Path.join(tmp, name)
    mgr = Path.join(root, "user.slice/user-4242.slice/user@4242.service")
    File.mkdir_p!(mgr)
    File.write!(Path.join(root, "cgroup.controllers"), "cpu io memory pids\n")
    if controllers, do: File.write!(Path.join(mgr, "cgroup.controllers"), controllers <> "\n")
    if subtree, do: File.write!(Path.join(mgr, "cgroup.subtree_control"), subtree <> "\n")
    [{"PC_CGROOT", root}, {"PC_UID", "4242"}, {"PC_FIXTURE", "1"}]
  end

  describe "U10 memory-controller delegation" do
    test "delegated memory (Fedora/Ubuntu default shape) passes", %{tmp_dir: tmp} do
      env = cgroup_fixture(tmp, "ok", "cpu io memory pids", "cpu io memory pids")
      assert {_, 0} = run("pc_cgroup_v2 && pc_delegated memory && pc_delegated pids", env)
      assert {"cpu io memory pids\n", 0} = run("pc_delegated_list", env)
    end

    test "memory listed but not enabled for children is NOT delegated", %{tmp_dir: tmp} do
      env = cgroup_fixture(tmp, "nosub", "cpu io memory pids", "cpu pids")
      assert {_, 1} = run("pc_delegated memory", env)
      assert {_, 0} = run("pc_delegated cpu", env)
    end

    test "older systemd default (cpu pids only; no memory) fails the memory check but not cpu", %{
      tmp_dir: tmp
    } do
      env = cgroup_fixture(tmp, "pidsonly", "pids", "pids")
      assert {_, 1} = run("pc_delegated memory", env)
      assert {_, 1} = run("pc_delegated cpu", env)
      assert {_, 0} = run("pc_delegated pids", env)
    end

    test "no user manager cgroup at all (no `systemctl --user`, e.g. a container) fails closed",
         %{tmp_dir: tmp} do
      env = cgroup_fixture(tmp, "nomgr", nil, nil)
      File.rm_rf!(Path.join(tmp, "nomgr/user.slice"))
      assert {_, 1} = run("pc_delegated memory", env)
    end

    test "cgroup v1 (no unified cgroup.controllers at the root) is refused", %{tmp_dir: tmp} do
      root = Path.join(tmp, "v1")
      File.mkdir_p!(Path.join(root, "memory"))
      assert {_, 1} = run("pc_cgroup_v2", [{"PC_CGROOT", root}, {"PC_FIXTURE", "1"}])
    end

    test "a substring is not a controller: `memory_hugetlb`-style names do not satisfy `memory`",
         %{tmp_dir: tmp} do
      env = cgroup_fixture(tmp, "substr", "cpu hugetlb_memory", "cpu hugetlb_memory")
      assert {_, 1} = run("pc_delegated memory", env)
    end

    test "the live host: cgroup2 + delegated memory, agreeing with what podman itself reports" do
      {out, 0} =
        run(
          "echo \"v2=$(pc_cgroup_v2 && echo y || echo n) mem=$(pc_delegated memory && echo y || echo n)\"; pc_podman_controllers"
        )

      [flags | rest] = String.split(out, "\n", trim: true)
      assert flags == "v2=y mem=y"
      assert Enum.join(rest, " ") =~ "memory"
    end

    test "the functional probe agrees: --memory is accepted on a delegated host" do
      if System.find_executable("podman") do
        {out, 0} =
          run("pc_podman_memory_probe docker.io/library/debian:12", [
            {"XDG_RUNTIME_DIR", System.get_env("XDG_RUNTIME_DIR") || "/run/user/1000"}
          ])

        assert String.trim(out) == "ok"
      end
    end
  end

  describe "U9 linger" do
    defp shim_loginctl(tmp, script) do
      bin = Path.join(tmp, "bin")
      File.mkdir_p!(bin)
      path = Path.join(bin, "loginctl")
      File.write!(path, "#!/bin/sh\n" <> script)
      File.chmod!(path, 0o755)
      bin
    end

    test "detection parses yes / no / failure", %{tmp_dir: tmp} do
      yes = shim_loginctl(tmp, ~s(echo yes\n))
      assert {"yes\n", 0} = run("pc_linger", [], yes)
      no = shim_loginctl(tmp, ~s(echo no\n))
      assert {"no\n", 0} = run("pc_linger", [], no)
      boom = shim_loginctl(tmp, "exit 1\n")
      assert {"unknown\n", 0} = run("pc_linger", [], boom)
    end

    test "enable-linger is attempted without a password prompt and a refusal is surfaced", %{
      tmp_dir: tmp
    } do
      log = Path.join(tmp, "argv.log")
      denied = shim_loginctl(tmp, ~s(echo "$@" >> #{log}\nexit 1\n))
      assert {_, 1} = run("pc_try_enable_linger", [{"PC_USER", "someone"}], denied)
      assert File.read!(log) =~ "--no-ask-password enable-linger someone"
    end

    test "the live host reports its real linger state and enable-linger is a no-op that succeeds without sudo" do
      {out, 0} = run("pc_linger")
      assert String.trim(out) in ["yes", "no"]

      if String.trim(out) == "yes" do
        assert {_, 0} = run("pc_try_enable_linger")
      end
    end
  end
end
