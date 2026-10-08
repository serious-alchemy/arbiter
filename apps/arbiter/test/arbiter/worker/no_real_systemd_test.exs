defmodule Arbiter.Worker.NoRealSystemdTest do
  # bd-8h3h3z: a test that reached the real `systemctl` stopped every live
  # `arb-run-*` scope on the host. In :test the resolved binaries must be the stubs.
  use ExUnit.Case, async: true

  alias Arbiter.Worker.MemoryScope

  @stub_dir Path.expand("../../support/stub_bin", __DIR__)

  test "systemctl and systemd-run resolve to the harmless stubs by default" do
    assert MemoryScope.systemctl_path([]) == Path.join(@stub_dir, "systemctl")
    assert MemoryScope.systemd_run_path([]) == Path.join(@stub_dir, "systemd-run")

    for bin <- ["systemctl", "systemd-run"] do
      refute MemoryScope.systemctl_path([]) == System.find_executable(bin)
      refute MemoryScope.systemd_run_path([]) == System.find_executable(bin)
    end
  end

  test "the stubs refuse to do anything" do
    for bin <- ["systemctl", "systemd-run"] do
      assert {_, 1} =
               System.cmd(Path.join(@stub_dir, bin), ["--user", "stop", "x.scope"],
                 stderr_to_stdout: true
               )
    end
  end

  test "listing and stopping through the default binary touch nothing" do
    assert MemoryScope.list([]) == []
    assert {:error, _} = MemoryScope.stop("arb-run-nonexistent-0000.scope", [])
  end
end
