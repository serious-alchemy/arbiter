defmodule Arbiter.Doctor.SpawnCanaryTest do
  # bd-8t4yui: the doctor's end-to-end canary spawn. Every agent CLI is a stub
  # (`Arbiter.TestSandbox` puts them first on PATH), so the real spawn pipeline
  # runs — RunTmp, the adapters' own argv + env, SpawnEnv, the memory scope's
  # wrapper, the Port — against fake agents.
  use Arbiter.DataCase, async: false

  alias Arbiter.Doctor.SpawnCanary
  alias Arbiter.Providers.Pause
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  @all_providers ["claude", "gemini", "codex", "grok"]

  setup do
    SpawnCanary.reset_cache()
    on_exit(&SpawnCanary.reset_cache/0)

    prev_tmp_root = Application.get_env(:arbiter, :worker_tmp_root)
    tmp_root = Path.join(Arbiter.Config.Paths.scratch_root(), "canary-#{unique()}")
    File.mkdir_p!(tmp_root)
    Application.put_env(:arbiter, :worker_tmp_root, tmp_root)

    on_exit(fn ->
      if prev_tmp_root,
        do: Application.put_env(:arbiter, :worker_tmp_root, prev_tmp_root),
        else: Application.delete_env(:arbiter, :worker_tmp_root)

      File.rm_rf(tmp_root)
    end)

    %{tmp_root: tmp_root}
  end

  defp unique, do: System.unique_integer([:positive])

  defp workspace!(types) do
    Ash.create!(Workspace, %{
      name: "canary-#{unique()}",
      config: %{"agent" => %{"type" => types}}
    })
  end

  # A stub CLI that logs its argv (`$0` is its name) and answers `--version`.
  defp version_stub(log), do: ~s(echo "$0 $@" >> #{log}\necho "stub 9.9.9"\nexit 0\n)

  defp provision!(stubs \\ %{}) do
    sandbox = TestSandbox.provision!("canary")
    # A stub is written for every binary; override per name with `stubs`.
    defaults = Map.new(TestSandbox.agent_binaries(), &{&1, version_stub(sandbox.log)})
    write_stubs!(sandbox, Map.merge(defaults, stubs))
    sandbox
  end

  defp write_stubs!(sandbox, stubs) do
    for {name, body} <- stubs do
      path = Path.join(sandbox.bin, name)
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
    end
  end

  defp calls(sandbox), do: if(File.exists?(sandbox.log), do: File.read!(sandbox.log), else: "")

  defp provider(report, name), do: Enum.find(report.providers, &(&1.provider == name))

  defp counts do
    %{
      issues: Ash.count!(Issue),
      runs: Ash.count!(Run),
      events: Ash.count!(Event)
    }
  end

  defp run_canary!(opts \\ []) do
    assert {:ok, report} = SpawnCanary.run(opts)
    report
  end

  describe "per provider" do
    test "spawns each in-use provider, reaches the agent and reports exit and duration" do
      sandbox = provision!()
      workspace!(@all_providers)

      report = run_canary!()

      assert report.ok
      assert {:ok, _, _} = DateTime.from_iso8601(report.ran_at)

      for name <- @all_providers do
        assert %{
                 status: "ok",
                 spawned: true,
                 reached_agent: true,
                 exit_code: 0,
                 error: nil,
                 detail: "stub 9.9.9"
               } = r = provider(report, name)

        assert is_integer(r.duration_ms) and r.duration_ms >= 0
      end

      # The probe is the CLI's own version flag, last on the argv: no prompt is
      # ever answered, so no model tokens are spent.
      # (a multi-line argv element spans several log lines, so count the ends)
      assert calls(sandbox)
             |> String.split("\n", trim: true)
             |> Enum.count(&String.ends_with?(&1, " --version")) ==
               4
    end

    test "the probe flag is not placed behind codex's `-- <prompt>` separator" do
      # real codex rejects `--version` as a second positional after `--`
      provision!(%{
        "codex" =>
          ~s(for a in "$@"; do [ "$a" = "--" ] && { echo "error: unexpected argument '--version' found" >&2; exit 2; }; done\necho "codex-cli 9.9.9"\n)
      })

      workspace!(["codex"])

      report = run_canary!()

      assert %{status: "ok", detail: "codex-cli 9.9.9"} = provider(report, "codex")
    end

    test "a provider paused on its account (grok:default) is n/a and never spawned" do
      sandbox = provision!()
      ws = workspace!(["claude", "grok"])
      account = Ash.create!(Arbiter.Accounts.ProviderAccount, %{provider: :grok, slug: "default"})

      Ash.create!(Arbiter.Accounts.WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :grok,
        provider_account_id: account.id
      })

      {:ok, _} = Pause.pause("grok:default", by: "test", reason: "grok login expired")

      report = run_canary!()

      assert report.ok
      assert %{status: "n/a", spawned: false, detail: detail} = provider(report, "grok")
      assert detail =~ "paused"
      assert detail =~ "grok login expired"
      refute calls(sandbox) =~ "/bin/grok "
    end

    test "a provider no workspace uses, or that is paused, is n/a and never spawned" do
      sandbox = provision!()
      workspace!(["claude", "gemini"])
      {:ok, _} = Pause.pause("antigravity", by: "test", reason: "canary test")

      report = run_canary!()

      assert report.ok
      assert %{status: "ok", spawned: true} = provider(report, "claude")
      assert %{status: "n/a", spawned: false, detail: paused} = provider(report, "gemini")
      assert paused =~ "paused"
      assert %{status: "n/a", spawned: false, detail: unused} = provider(report, "codex")
      assert unused =~ "not configured"
      assert %{status: "n/a", spawned: false} = provider(report, "grok")

      invocations = calls(sandbox) |> String.split("\n", trim: true)
      assert [claude] = invocations
      assert claude =~ "claude"
      refute calls(sandbox) =~ "agy"
    end
  end

  describe "agy through the jail's egress run (bd-96r8yw)" do
    setup do
      keys = ~w(worker_isolate_config worker_jail_available worker_jail_network_available
                worker_jail_network worker_jail_bwrap)a
      prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})

      on_exit(fn ->
        Enum.each(prev, fn
          {k, nil} -> Application.delete_env(:arbiter, k)
          {k, v} -> Application.put_env(:arbiter, k, v)
        end)
      end)

      :ok
    end

    test "is spawned with an owner, so the egress run starts, and nothing is left behind" do
      sandbox = provision!(%{"bwrap" => "exit 0\n", "socat" => "exit 0\n"})
      Application.put_env(:arbiter, :worker_isolate_config, true)
      Application.put_env(:arbiter, :worker_jail_available, true)
      Application.put_env(:arbiter, :worker_jail_network_available, true)
      Application.delete_env(:arbiter, :worker_jail_network)
      Application.put_env(:arbiter, :worker_jail_bwrap, Path.join(sandbox.bin, "bwrap"))
      workspace!(["gemini"])
      socks = fn -> Path.wildcard(Path.join(Arbiter.Worker.Egress.socket_dir(), "*.sock")) end
      before = socks.()

      report = run_canary!()

      assert %{status: "ok", spawned: true} = provider(report, "gemini")
      assert socks.() -- before == []
      assert before -- socks.() == []

      assert Registry.select(Arbiter.Worker.Egress.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) ==
               []
    end
  end

  describe "podman-backed workspaces (bd-c2cew2)" do
    setup %{tmp_root: tmp_root} do
      keys = ~w(worker_container_available worker_container_network_available
                worker_container_image worker_container_runner worker_deps_cache)a
      prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})

      Application.put_env(:arbiter, :worker_container_available, true)
      Application.put_env(:arbiter, :worker_container_network_available, true)
      Application.put_env(:arbiter, :worker_container_image, "localhost/arb-test/claude:1")
      Application.put_env(:arbiter, :worker_deps_cache, false)

      test_pid = self()

      Application.put_env(:arbiter, :worker_container_runner, fn cmd, args, _opts ->
        send(test_pid, {:ran, cmd, args})
        {"", 0}
      end)

      on_exit(fn ->
        Enum.each(prev, fn
          {k, nil} -> Application.delete_env(:arbiter, k)
          {k, v} -> Application.put_env(:arbiter, k, v)
        end)
      end)

      proxy = Path.join(tmp_root, "proxy.sock")
      bridge = Path.join(tmp_root, "arb.sock")
      File.write!(proxy, "")
      File.write!(bridge, "")
      arb = Path.join(tmp_root, "arb")
      File.write!(arb, "#!/bin/sh\n")

      egress = fn _opts ->
        send(test_pid, :egress_started)
        {:ok, [proxy_socket: proxy, proxy_port: 3128, bridges: [{4848, bridge}]], "ctest"}
      end

      # Stand-in podman: records the argv it was handed and answers `--version`.
      sandbox = provision!()
      podman = Path.join(sandbox.bin, "podman")

      File.write!(
        podman,
        ~s(#!/bin/sh\necho "podman $@" >> #{sandbox.log}\necho "stub 9.9.9"\nexit 0\n)
      )

      File.chmod!(podman, 0o755)

      %{
        sandbox: sandbox,
        container_opts: [podman: podman, egress: egress, arb_path: arb],
        scratch: tmp_root
      }
    end

    # A missing clone root and an empty one both mean "no clones": the root is
    # created lazily, so a baseline taken before the first clone sees :enoent.
    defp clones(root \\ Arbiter.Config.Paths.worktree_root()) do
      case File.ls(root) do
        {:ok, entries} -> Enum.sort(entries)
        {:error, :enoent} -> []
      end
    end

    test "clones/1 treats a missing root like an empty one but still sees leftovers" do
      root = Path.join(System.tmp_dir!(), "clones-#{System.unique_integer([:positive])}")
      assert clones(root) == []

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      assert clones(root) == []

      File.mkdir_p!(Path.join(root, "leftover-clone"))
      assert clones(root) == ["leftover-clone"]
    end

    defp podman_workspace!(types) do
      Ash.create!(Workspace, %{
        name: "canary-#{unique()}",
        config: %{
          "agent" => %{
            "type" => types,
            "security" => %{"sandbox" => %{"backend" => "podman"}}
          }
        }
      })
    end

    test "claude runs the real podman spawn path and leaves nothing behind", ctx do
      podman_workspace!(["claude"])
      before = counts()
      clones_before = clones()

      report = run_canary!(container_opts: ctx.container_opts)

      assert report.ok

      assert %{status: "ok", spawned: true, reached_agent: true, exit_code: 0} =
               r = provider(report, "claude")

      assert r.detail == "stub 9.9.9"

      log = calls(ctx.sandbox)
      assert log =~ ~r/podman run .*--name arb-canary-claude-/
      assert log =~ "localhost/arb-test/claude:1"
      assert log =~ "--version"

      assert_received :egress_started
      assert_received {:ran, _, ["rm", "--force" | _] = args}
      assert Enum.any?(args, &String.starts_with?(&1, "arb-canary-claude-"))

      assert counts() == before
      assert File.ls!(ctx.scratch) |> Enum.reject(&(&1 in ~w(proxy.sock arb.sock arb))) == []
      assert clones() == clones_before
    end

    test "a failing container spawn fails the report and still cleans up", ctx do
      podman_workspace!(["claude"])
      File.write!(Path.join(ctx.sandbox.bin, "podman"), "#!/bin/sh\necho boom >&2\nexit 125\n")

      report = run_canary!(container_opts: ctx.container_opts)

      refute report.ok

      assert %{status: "fail", exit_code: 125, error: "exit 125: boom"} =
               provider(report, "claude")

      assert_received {:ran, _, ["rm", "--force" | _]}
      assert File.ls!(ctx.scratch) |> Enum.reject(&(&1 in ~w(proxy.sock arb.sock arb))) == []
    end

    test "agy has no container wrap point: canaried through bwrap, labelled", ctx do
      podman_workspace!(["gemini"])

      report = run_canary!(container_opts: ctx.container_opts)

      assert %{status: "ok", spawned: true, detail: detail} = provider(report, "gemini")
      assert detail =~ "canaried through the bwrap path"
      refute calls(ctx.sandbox) =~ "podman run"
    end

    test "a failing bwrap fallback is labelled too", ctx do
      podman_workspace!(["gemini"])
      File.write!(Path.join(ctx.sandbox.bin, "agy"), "#!/bin/sh\necho nope >&2\nexit 3\n")
      File.write!(Path.join(ctx.sandbox.bin, "gemini"), "#!/bin/sh\necho nope >&2\nexit 3\n")

      report = run_canary!(container_opts: ctx.container_opts)

      refute report.ok
      assert %{status: "fail", error: error} = provider(report, "gemini")
      assert error =~ "ran through the bwrap path"
    end

    test "a non-main merge.base with no configured image still resolves the image", ctx do
      Application.delete_env(:arbiter, :worker_container_image)

      Application.put_env(:arbiter, :worker_image_runner, fn
        "skopeo", ["inspect" | _], _ -> {"sha256:" <> String.duplicate("a", 64), 0}
        _, _, _ -> {"", 0}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :worker_image_runner) end)

      Ash.create!(Workspace, %{
        name: "canary-#{unique()}",
        config: %{
          "agent" => %{
            "type" => ["claude"],
            "security" => %{"sandbox" => %{"backend" => "podman"}}
          },
          "merge" => %{"base" => "develop"}
        }
      })

      report = run_canary!(container_opts: ctx.container_opts)

      assert %{status: "ok"} = provider(report, "claude")
    end

    test "a bwrap workspace is unchanged: no container, no scratch repo", ctx do
      workspace!(["claude"])

      report = run_canary!(container_opts: ctx.container_opts)

      assert %{status: "ok", detail: "stub 9.9.9"} = provider(report, "claude")
      refute calls(ctx.sandbox) =~ "podman"
      refute_received :egress_started
    end
  end

  describe "spawn-path failures fail the report with the first error line" do
    test "a FunctionClauseError in RunTmp.create (the 2026-10-04 v0.2.14 shape)" do
      sandbox = provision!()
      workspace!(["claude"])
      # `Paths.worker_tmp_root/0` handing back a non-path is what crashed every
      # spawn that day.
      Application.put_env(:arbiter, :worker_tmp_root, :not_a_path)

      report = run_canary!()

      refute report.ok

      assert %{status: "fail", spawned: false, reached_agent: false, error: error} =
               provider(report, "claude")

      assert error =~ "FunctionClauseError"
      refute String.contains?(error, "\n")
      assert calls(sandbox) == ""
    end

    test "a wrapper that exits 125 before the agent runs (the agy jail shape, bd-c9fqsk)" do
      sandbox =
        provision!(%{
          "claude" =>
            "echo \"bwrap: Can't bind socket path too long (sun_path)\" >&2\necho second >&2\nexit 125\n"
        })

      workspace!(["claude"])

      report = run_canary!()

      refute report.ok

      assert %{
               status: "fail",
               spawned: true,
               reached_agent: false,
               exit_code: 125,
               error: error
             } = provider(report, "claude")

      assert error == "exit 125: bwrap: Can't bind socket path too long (sun_path)"
      assert calls(sandbox) == ""
    end

    test "a missing agent binary fails instead of crashing the report" do
      sandbox = provision!()
      workspace!(["claude", "codex"])
      File.rm!(Path.join(sandbox.bin, "codex"))
      # a real `codex` further down PATH must not answer for the missing stub
      prev = System.get_env("PATH")
      System.put_env("PATH", sandbox.bin <> ":/usr/bin:/bin")
      on_exit(fn -> System.put_env("PATH", prev) end)

      report = run_canary!()

      refute report.ok
      assert %{status: "fail", spawned: false, error: error} = provider(report, "codex")
      assert error =~ "codex"
      assert %{status: "ok"} = provider(report, "claude")
    end

    test "an agent that never stops printing is cut off at the output cap" do
      provision!(%{"claude" => "exec yes 'x'\n"})
      workspace!(["claude"])

      report = run_canary!(timeout_ms: 20_000)

      refute report.ok
      assert %{status: "fail", spawned: true, error: error} = provider(report, "claude")
      assert error =~ "more than 65536 bytes"
    end

    test "an agent that never answers is killed and reported, within the timeout" do
      provision!(%{"claude" => "exec sleep 30\n"})
      workspace!(["claude"])

      report = run_canary!(timeout_ms: 300)

      refute report.ok

      assert %{status: "fail", spawned: true, error: error} = provider(report, "claude")
      assert error =~ "did not finish"
    end
  end

  describe "side effects" do
    test "creates no ticket, run or usage row, and removes its temp dirs", %{tmp_root: tmp_root} do
      provision!()
      workspace!(@all_providers)
      before = counts()

      report = run_canary!()

      assert report.ok
      assert counts() == before
      assert File.ls!(tmp_root) == []
    end

    test "cleans up after a failed spawn too", %{tmp_root: tmp_root} do
      provision!(%{"claude" => "exit 3\n"})
      workspace!(["claude"])
      before = counts()

      report = run_canary!()

      refute report.ok
      assert counts() == before
      assert File.ls!(tmp_root) == []
    end

    test "runs the agent in its own memory scope and stops it afterwards" do
      sandbox = provision!()
      workspace!(["claude"])
      fakes = install_fake_systemd!(sandbox)

      report = run_canary!()

      assert %{status: "ok"} = provider(report, "claude")

      scope_runs =
        fakes.run_log
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&(&1 =~ "arb-run-canary-claude-"))

      assert [scope_run] = scope_runs
      assert scope_run =~ "MemoryMax=512M"
      [_, unit] = Regex.run(~r/--unit=(arb-run-canary-claude-[0-9a-f-]+)/, scope_run)

      ctl = fakes.ctl_log |> File.read!() |> String.split("\n", trim: true)
      assert "--user stop #{unit}.scope" in ctl, inspect(ctl)
    end
  end

  describe "concurrency" do
    test "a second canary while one is running is refused" do
      sandbox = TestSandbox.provision!("canary-busy")
      workspace!(["claude"])

      up = Path.join(sandbox.root, "up.fifo")
      down = Path.join(sandbox.root, "down.fifo")
      {_, 0} = System.cmd("mkfifo", [up, down])

      write_stubs!(sandbox, %{
        "claude" => ~s(echo up > #{up}\ncat #{down} > /dev/null\necho "stub 9.9.9"\n)
      })

      first = Task.async(fn -> SpawnCanary.run() end)
      # the stub announces itself on the fifo once the first canary's agent runs
      reader =
        Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, args: [up]])

      assert_receive {^reader, {:data, "up\n"}}, 10_000

      assert SpawnCanary.run() == {:error, :busy}

      File.write!(down, "go")
      assert {:ok, %{ok: true}} = Task.await(first, 10_000)

      # the guard is released
      write_stubs!(sandbox, %{"claude" => version_stub(sandbox.log)})
      assert {:ok, _} = SpawnCanary.run()
    end
  end

  describe "cached/0" do
    test "is nil until a canary has run this boot, then the last report" do
      provision!()
      workspace!(["claude"])

      assert SpawnCanary.cached() == nil
      report = run_canary!()
      assert SpawnCanary.cached() == report
    end
  end

  # A `systemd-run` that answers the two probes the way a healthy host does and
  # otherwise runs the command that follows `env -u XDG_RUNTIME_DIR`, and a
  # `systemctl` that only records what it was asked.
  defp install_fake_systemd!(sandbox) do
    run_log = Path.join(sandbox.root, "systemd-run.log")
    ctl_log = Path.join(sandbox.root, "systemctl.log")

    File.write!(Path.join(sandbox.bin, "systemd-run"), """
    #!/bin/sh
    echo "$@" >> #{run_log}
    case "$*" in
      *printf*) printf '$'; exit 0 ;;
      *memory.max*) echo 536870912; exit 0 ;;
    esac
    while [ $# -gt 0 ] && [ "$1" != "env" ]; do shift; done
    exec "$@"
    """)

    File.write!(Path.join(sandbox.bin, "systemctl"), """
    #!/bin/sh
    echo "$@" >> #{ctl_log}
    """)

    for bin <- ["systemd-run", "systemctl"], do: File.chmod!(Path.join(sandbox.bin, bin), 0o755)

    prev =
      for k <- [:systemd_run, :systemctl, :worker_memory_max],
          do: {k, Application.get_env(:arbiter, k)}

    Application.put_env(:arbiter, :systemd_run, Path.join(sandbox.bin, "systemd-run"))
    Application.put_env(:arbiter, :systemctl, Path.join(sandbox.bin, "systemctl"))
    Application.put_env(:arbiter, :worker_memory_max, "512M")
    Arbiter.Worker.MemoryScope.reset_probe()

    on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:arbiter, k, v), else: Application.delete_env(:arbiter, k)
      end

      Arbiter.Worker.MemoryScope.reset_probe()
    end)

    %{run_log: run_log, ctl_log: ctl_log}
  end
end
