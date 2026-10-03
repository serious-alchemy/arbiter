defmodule Arbiter.Worker.MemoryScope.DiagnosisTest do
  use ExUnit.Case, async: false

  alias Arbiter.Worker.MemoryScope
  alias Arbiter.Worker.MemoryScope.Diagnosis

  @user_cgroup "0::/user.slice/user-1000.slice/user@1000.service/app.slice/arbiter.service\n"
  @system_cgroup "0::/system.slice/arbiter.service\n"

  setup do
    prev = Application.get_env(:arbiter, :worker_memory_max)
    prev_env = System.get_env("ARBITER_WORKER_MEMORY_MAX")
    System.delete_env("ARBITER_WORKER_MEMORY_MAX")
    MemoryScope.reset_probe()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :worker_memory_max, prev),
        else: Application.delete_env(:arbiter, :worker_memory_max)

      if prev_env, do: System.put_env("ARBITER_WORKER_MEMORY_MAX", prev_env)
      MemoryScope.reset_probe()
    end)
  end

  # `systemd-run` probes answer like a healthy host; `systemctl show` answers
  # with the given OOMPolicy.
  defp cmd(oom_policy, test_pid \\ self()) do
    fn bin, args, _opts ->
      send(test_pid, {:cmd, Path.basename(bin), args})

      cond do
        Path.basename(bin) == "systemctl" ->
          {"OOMPolicy=#{oom_policy}\nMemoryMax=infinity\n", 0}

        "printf" in args ->
          {"$$\n", 0}

        true ->
          {"12884901888\n", 0}
      end
    end
  end

  defp opts(cgroup, oom_policy),
    do: [
      cgroup: cgroup,
      cmd: cmd(oom_policy),
      systemd_run: "/bin/systemd-run",
      systemctl: "/bin/systemctl",
      runtime_dir: "/run/user/1000"
    ]

  test "reports OOMPolicy=stop for the user unit the server runs in, with the cap active" do
    Application.put_env(:arbiter, :worker_memory_max, "12G")

    assert %{
             "service_unit" => "arbiter.service",
             "service_manager" => "user",
             "oom_policy" => "stop",
             "memory_max" => "infinity",
             "enabled" => true,
             "available" => true,
             "capped" => true,
             "cap" => "12G"
           } = Diagnosis.run(opts(@user_cgroup, "stop"))

    assert_received {:cmd, "systemctl", ["--user", "show", "arbiter.service" | _]}
  end

  test "asks the system manager (no --user) for a system unit" do
    Diagnosis.run(opts(@system_cgroup, "continue"))

    assert_received {:cmd, "systemctl", ["show", "arbiter.service" | _]}
  end

  test "an uncapped server is reported as such" do
    Application.put_env(:arbiter, :worker_memory_max, "off")

    assert %{"enabled" => false, "capped" => false, "cap" => nil} =
             Diagnosis.run(opts(@user_cgroup, "stop"))
  end

  test "an enabled cap the host cannot provide says why" do
    Application.put_env(:arbiter, :worker_memory_max, "12G")

    failing = fn
      _bin, ["show" | _], _ -> {"", 1}
      _bin, _args, _ -> {"Failed to connect to user scope bus", 1}
    end

    result = Diagnosis.run(Keyword.put(opts(@user_cgroup, "stop"), :cmd, failing))

    assert %{"enabled" => true, "available" => false, "capped" => false} = result
    assert result["unavailable_reason"] =~ "user scope bus"
  end

  test "a server that is not a systemd service has no unit or policy" do
    result = Diagnosis.run(opts("0::/user.slice/user-1000.slice/session-3.scope\n", "stop"))

    assert result["service_unit"] == nil
    assert result["oom_policy"] == nil
  end

  test "service_unit/1 never mistakes the user manager itself for the service" do
    assert Diagnosis.service_unit(
             cgroup: "0::/user.slice/user-1000.slice/user@1000.service/init.scope\n"
           ) ==
             nil
  end
end
