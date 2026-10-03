defmodule Arbiter.Worker.MemoryScopeTest do
  # bd-6zuoo6: the per-spawn memory-capped scope. The argv shape, the config
  # surface and the OOM detection are exercised against an injected command
  # runner; the real-systemd behaviour is in
  # `Arbiter.Integration.WorkerMemoryCapTest` (`:live_systemd`).
  use ExUnit.Case, async: false

  alias Arbiter.Worker.MemoryScope

  setup do
    prev_env = System.get_env("ARBITER_WORKER_MEMORY_MAX")
    prev_app = Application.get_env(:arbiter, :worker_memory_max)
    System.delete_env("ARBITER_WORKER_MEMORY_MAX")
    Application.delete_env(:arbiter, :worker_memory_max)
    MemoryScope.reset_probe()

    on_exit(fn ->
      if prev_env,
        do: System.put_env("ARBITER_WORKER_MEMORY_MAX", prev_env),
        else: System.delete_env("ARBITER_WORKER_MEMORY_MAX")

      if prev_app,
        do: Application.put_env(:arbiter, :worker_memory_max, prev_app),
        else: Application.delete_env(:arbiter, :worker_memory_max)

      MemoryScope.reset_probe()
    end)

    :ok
  end

  # A fake `systemd-run` that answers the two probe invocations the way a
  # healthy host does. `expands?` models whether it expands `$`.
  defp healthy_cmd(expands?, memory_max \\ "12884901888") do
    fn _bin, args, _opts ->
      cond do
        "printf" in args -> {if(expands?, do: "$\n", else: "$$\n"), 0}
        "sh" in args -> {memory_max <> "\n", 0}
      end
    end
  end

  defp probe_opts(cmd), do: [cmd: cmd, systemd_run: "/usr/bin/systemd-run", runtime_dir: "/run/user/1"]

  defp port_args(env \\ []) do
    %{
      exec: "/usr/bin/claude",
      argv: ["claude", "--print", "cost $5 and ${HOME}"],
      cd: "/tmp",
      env: env
    }
  end

  describe "configured_max/0" do
    test "defaults to a percentage of RAM" do
      assert MemoryScope.configured_max() == {:ok, "40%"}
    end

    test "environment beats application config" do
      Application.put_env(:arbiter, :worker_memory_max, "8G")
      assert MemoryScope.configured_max() == {:ok, "8G"}

      System.put_env("ARBITER_WORKER_MEMORY_MAX", "12g")
      assert MemoryScope.configured_max() == {:ok, "12G"}
    end

    test "off-ish values disable the cap" do
      for v <- ~w(off 0 none infinity OFF) do
        System.put_env("ARBITER_WORKER_MEMORY_MAX", v)
        assert MemoryScope.configured_max() == :disabled, v
      end
    end

    test "an invalid value falls back to the default instead of disabling" do
      for v <- ["lots", "12 gigs", "0G", "150%x", "-1"] do
        System.put_env("ARBITER_WORKER_MEMORY_MAX", v)
        assert MemoryScope.configured_max() == {:ok, "40%"}, v
      end
    end
  end

  describe "wrap/3" do
    test "wraps the agent in a capped, kill-on-OOM scope with the original argv last" do
      System.put_env("ARBITER_WORKER_MEMORY_MAX", "12G")

      {wrapped, scope} = MemoryScope.wrap(port_args(), "bd-abc123", probe_opts(healthy_cmd(false)))

      assert wrapped.exec == "/usr/bin/systemd-run"
      assert [_argv0 | args] = wrapped.argv
      assert "--user" in args and "--scope" in args
      assert "MemoryMax=12G" in args
      assert "MemorySwapMax=0" in args
      assert "OOMPolicy=kill" in args
      assert "--unit=" <> unit = Enum.find(args, &String.starts_with?(&1, "--unit="))
      assert unit =~ ~r/\Aarb-run-bd-abc123-[0-9a-f]{8}\z/
      assert scope == %{unit: unit <> ".scope", max: "12G"}

      # `env -u XDG_RUNTIME_DIR <exec> <rest…>` is the tail, argument for argument.
      tail = Enum.drop(args, Enum.find_index(args, &(&1 == "-u")) - 1)
      assert [_env, "-u", "XDG_RUNTIME_DIR", "/usr/bin/claude", "--print", prompt] = tail
      assert prompt == "cost $5 and ${HOME}"
      assert wrapped.cd == "/tmp"
    end

    test "restores XDG_RUNTIME_DIR for systemd-run only" do
      {wrapped, _} =
        MemoryScope.wrap(
          port_args([{"XDG_RUNTIME_DIR", false}, {"FOO", "bar"}]),
          "t",
          probe_opts(healthy_cmd(false))
        )

      assert {"XDG_RUNTIME_DIR", "/run/user/1"} in wrapped.env
      assert {"FOO", "bar"} in wrapped.env
      assert "-u" in wrapped.argv
    end

    test "an XDG_RUNTIME_DIR the spawn env set explicitly is left alone" do
      {wrapped, _} =
        MemoryScope.wrap(
          port_args([{"XDG_RUNTIME_DIR", "/custom"}]),
          "t",
          probe_opts(healthy_cmd(false))
        )

      assert wrapped.env == [{"XDG_RUNTIME_DIR", "/custom"}]
      refute "-u" in wrapped.argv
    end

    test "doubles `$` when this systemd-run expands it, so prompts survive" do
      {wrapped, _} = MemoryScope.wrap(port_args(), "t", probe_opts(healthy_cmd(true)))

      assert List.last(wrapped.argv) == "cost $$5 and $${HOME}"
    end

    test "passes the argv through untouched when systemd-run does not expand" do
      {wrapped, _} = MemoryScope.wrap(port_args(), "t", probe_opts(healthy_cmd(false)))

      assert List.last(wrapped.argv) == "cost $5 and ${HOME}"
    end

    test "returns the args untouched and no scope when the cap is disabled" do
      System.put_env("ARBITER_WORKER_MEMORY_MAX", "off")
      args = port_args()

      assert {^args, nil} = MemoryScope.wrap(args, "t", probe_opts(healthy_cmd(false)))
    end

    test "returns the args untouched when systemd-run cannot create the scope" do
      failing = fn _bin, _args, _opts -> {"Failed to connect to user scope bus", 1} end
      args = port_args()

      assert {^args, nil} = MemoryScope.wrap(args, "t", probe_opts(failing))
    end

    test "treats a limit the user manager did not apply as unavailable" do
      args = port_args()

      assert {^args, nil} =
               MemoryScope.wrap(args, "t", probe_opts(healthy_cmd(false, "max")))
    end
  end

  describe "outcome/2" do
    @scope %{unit: "arb-run-t-1.scope", max: "12G"}

    defp ctl_cmd(show_output, test_pid) do
      fn _bin, args, _opts ->
        send(test_pid, {:systemctl, args})

        case args do
          ["--user", "show" | _] -> {show_output, 0}
          ["--user", "reset-failed" | _] -> {"", 0}
        end
      end
    end

    test "reports an OOM kill with the peak and clears the failed scope" do
      out = "Result=oom-kill\nMemoryPeak=12884901888\n"

      assert {:memory_cap_exceeded, %{peak: 12_884_901_888, max: "12G"}} =
               MemoryScope.outcome(@scope, cmd: ctl_cmd(out, self()), systemctl: "/bin/systemctl")

      assert_received {:systemctl, ["--user", "reset-failed", "arb-run-t-1.scope"]}
    end

    test "a scope that ended normally is :ok and is not reset" do
      out = "Result=success\nMemoryPeak=1048576\n"

      assert :ok =
               MemoryScope.outcome(@scope, cmd: ctl_cmd(out, self()), systemctl: "/bin/systemctl")

      refute_received {:systemctl, ["--user", "reset-failed" | _]}
    end

    test "an unreadable systemctl answer is :ok rather than a crash" do
      boom = fn _, _, _ -> raise "no bus" end
      assert :ok = MemoryScope.outcome(@scope, cmd: boom, systemctl: "/bin/systemctl")
    end

    test "tolerates an unset MemoryPeak" do
      out = "Result=oom-kill\nMemoryPeak=[not set]\n"

      assert {:memory_cap_exceeded, %{peak: nil}} =
               MemoryScope.outcome(@scope, cmd: ctl_cmd(out, self()), systemctl: "/bin/systemctl")
    end
  end
end
