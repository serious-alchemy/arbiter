defmodule Arbiter.Release.SelfDeployTest do
  # async: false — GITHUB_TOKEN and the :data_dir / :self_deploy app env are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Release.{DeployStatus, SelfDeploy}

  setup do
    home = Path.join(System.tmp_dir!(), "arb-sd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    arb = Path.join(home, "arb")
    File.write!(arb, "#!/bin/sh\n")
    File.chmod!(arb, 0o755)

    previous_dir = Application.fetch_env(:arbiter, :data_dir)
    previous_cfg = Application.fetch_env(:arbiter, :self_deploy)
    Application.put_env(:arbiter, :data_dir, home)

    on_exit(fn ->
      restore(:data_dir, previous_dir)
      restore(:self_deploy, previous_cfg)
      System.delete_env("GITHUB_TOKEN")
      File.rm_rf(home)
    end)

    {:ok, home: home, arb: arb}
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  # A systemctl/systemd-run stand-in that records what it was asked and answers
  # from `responses` (by first matching `{cmd, first_arg_after_--user}`).
  defp stub_cmds(arb, opts \\ []) do
    test_pid = self()
    active = Keyword.get(opts, :active_units, "")
    run = Keyword.get(opts, :systemd_run, {"Running as unit: arbiter-deploy-v1.2.3.service\n", 0})
    list = Keyword.get(opts, :list, {active, 0})

    fun = fn cmd, args, run_opts ->
      send(test_pid, {:cmd, cmd, args, run_opts})

      case {cmd, args} do
        {"systemctl", ["--user", "list-units" | _]} -> list
        {"systemd-run", _} -> run
      end
    end

    Application.put_env(:arbiter, :self_deploy, cmd: fun, arb_path: arb)
  end

  describe "start/1" do
    test "launches the deploy in its own transient systemd user unit", %{home: home, arb: arb} do
      stub_cmds(arb)

      assert {:ok, %{unit: "arbiter-deploy-v1.2.3", tag: "v1.2.3"}} = SelfDeploy.start("v1.2.3")

      assert_received {:cmd, "systemd-run", args, _opts}

      assert "--user" in args
      assert "--unit=arbiter-deploy-v1.2.3" in args
      # Detached from the server's own cgroup, so the restart it causes can't kill it.
      assert "--collect" in args
      # The service's environment (GITHUB_TOKEN, DATABASE_PATH, PATH) comes from
      # the file, never from argv.
      assert ("--property=EnvironmentFile=-" <> Path.join(home, "arbiter.env")) in args

      assert Enum.take(args, -5) == ["server", "deploy", "--version", "v1.2.3", "--json"]
      assert Enum.at(args, -6) == arb
    end

    test "passes ARB_DATA_HOME to the unit so a non-default home is honoured", %{
      home: home,
      arb: arb
    } do
      stub_cmds(arb)
      assert {:ok, _} = SelfDeploy.start("v1.2.3")
      assert_received {:cmd, "systemd-run", args, _}
      assert "--setenv=ARB_DATA_HOME=#{home}" in args
    end

    test "never puts a secret in argv or the logs", %{arb: arb} do
      System.put_env("GITHUB_TOKEN", "ghp_supersecrettokenvalue123")
      stub_cmds(arb)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} = SelfDeploy.start("v1.2.3")
        end)

      assert_received {:cmd, "systemd-run", args, run_opts}
      refute Enum.any?(args, &String.contains?(&1, "ghp_supersecrettokenvalue123"))
      refute inspect(run_opts) =~ "ghp_supersecrettokenvalue123"
      refute log =~ "ghp_supersecrettokenvalue123"
    end

    test "never logs a failing launch's output verbatim if it holds the token", %{arb: arb} do
      System.put_env("GITHUB_TOKEN", "ghp_supersecrettokenvalue123")
      stub_cmds(arb, systemd_run: {"boom ghp_supersecrettokenvalue123", 1})

      log =
        capture_log(fn ->
          assert {:error, {:launch_failed, message}} = SelfDeploy.start("v1.2.3")
          refute message =~ "ghp_supersecrettokenvalue123"
        end)

      refute log =~ "ghp_supersecrettokenvalue123"
    end

    test "only a plain vX.Y.Z release tag is deployable — never a ref, branch or option",
         %{arb: arb} do
      stub_cmds(arb)

      for bad <- [
            "main",
            "v1",
            "v1.2",
            "1.2.3",
            "v1.2.3-rc1",
            "v1.2.3 --force",
            "../x",
            "-h",
            "",
            nil
          ] do
        assert {:error, :invalid_tag} = SelfDeploy.start(bad)
      end

      refute_received {:cmd, "systemd-run", _, _}
    end

    test "refuses a second deploy while a deploy unit is active", %{arb: arb} do
      stub_cmds(arb, active_units: "arbiter-deploy-v1.2.2.service loaded active running x\n")

      assert {:error, :already_running} = SelfDeploy.start("v1.2.3")
      refute_received {:cmd, "systemd-run", _, _}
    end

    test "refuses while the deploy's own status says it is running", %{home: home, arb: arb} do
      stub_cmds(arb)
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      File.write!(
        Path.join(home, "deploy-status.json"),
        Jason.encode!(%{
          "state" => "running",
          "tag" => "v1.2.2",
          "pid" => System.pid(),
          "updated_at" => now
        })
      )

      assert {:error, :already_running} = SelfDeploy.start("v1.2.3")
    end

    test "a 'running' record whose process died does not wedge future deploys",
         %{home: home, arb: arb} do
      stub_cmds(arb)

      File.write!(
        Path.join(home, "deploy-status.json"),
        Jason.encode!(%{"state" => "running", "tag" => "v1.2.2", "pid" => "999999999"})
      )

      assert {:ok, _} = SelfDeploy.start("v1.2.3")
    end

    test "systemd-run losing the unit-name race reads as already running", %{arb: arb} do
      stub_cmds(arb,
        systemd_run:
          {"Failed to start transient service unit: Unit arbiter-deploy-v1.2.3.service was already loaded or has a fragment file.\n",
           1}
      )

      assert {:error, :already_running} = SelfDeploy.start("v1.2.3")
    end

    test "an unreachable systemd is a clear error, not a launch", %{arb: arb} do
      stub_cmds(arb, list: {"Failed to connect to bus: No medium found\n", 1})

      assert {:error, :systemd_unavailable} = SelfDeploy.start("v1.2.3")
      refute_received {:cmd, "systemd-run", _, _}
    end

    test "a missing arb CLI is reported with its path", %{home: home} do
      missing = Path.join(home, "no-such-arb")
      stub_cmds(missing)

      assert {:error, {:cli_missing, ^missing}} = SelfDeploy.start("v1.2.3")
      refute_received {:cmd, "systemd-run", _, _}
    end
  end

  describe "DeployStatus" do
    test "read/0 is nil with no record, and the record once the CLI wrote one", %{home: home} do
      assert DeployStatus.read() == nil

      File.write!(
        Path.join(home, "deploy-status.json"),
        Jason.encode!(%{"state" => "succeeded", "tag" => "v1.2.3"})
      )

      assert %{"state" => "succeeded", "tag" => "v1.2.3"} = DeployStatus.read()
    end

    test "an unparseable record reads as nil", %{home: home} do
      File.write!(Path.join(home, "deploy-status.json"), "{nope")
      assert DeployStatus.read() == nil
    end

    test "running?/1 is false for a dead pid and for finished states" do
      refute DeployStatus.running?(%{"state" => "succeeded"})
      refute DeployStatus.running?(%{"state" => "running", "pid" => "999999999"})
      assert DeployStatus.running?(%{"state" => "running", "pid" => System.pid()})
      refute DeployStatus.running?(nil)
    end
  end
end
