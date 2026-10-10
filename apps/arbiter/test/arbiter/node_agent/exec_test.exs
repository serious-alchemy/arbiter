defmodule Arbiter.NodeAgent.ExecTest do
  @moduledoc """
  bd-9rrrgk: a command run in a node run's container after the run's agent has
  ended (the pre-push recipe). The agent rebuilds the run's hardened container
  from the spec it was assigned with, against a stub `podman`.
  """
  # async: false: the stub reads STUB_PODMAN_DIR from the process environment.
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.{Backend, Config, Exec, Run, Runs, StubPodman}

  @token "sk-ant-oat01-SECRETMARKER-exec"

  setup do
    root = Path.join(System.tmp_dir!(), "rx-#{System.unique_integer([:positive])}")
    stub_dir = Path.join(root, "stub")
    home = Path.join(root, "home")
    rt = Path.join(root, "rt")
    File.mkdir_p!(home)
    File.mkdir_p!(rt)
    podman = StubPodman.install(stub_dir)
    cli = Path.join(root, "claude")
    File.write!(cli, "#!/bin/sh\n")
    File.chmod!(cli, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)

    config = %Config{
      node_home: home,
      credential: "arbn_x.y",
      primary_url: "http://127.0.0.1:1",
      node_id: "n1"
    }

    opts = [
      config: config,
      podman: podman,
      runtime_dir: rt,
      require_tmpfs: false,
      sink: self(),
      node_id: "n1",
      image_fun: fn _image, _opts -> :ok end,
      files_fun: fn _sha, _name -> {:ok, cli} end,
      delegated_fun: fn -> ["memory", "pids", "cpu"] end,
      exit_retention_ms: 60_000
    ]

    %{stub: stub_dir, opts: opts}
  end

  defp spec(run) do
    %{
      "version" => 1,
      "run" => run,
      "task" => "bd-abc",
      "name" => "arb-#{run}",
      "install" => "inst1",
      "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
      "cwd" => "/work/tree",
      "mounts" => [
        %{"kind" => "worktree", "path" => "/work/tree"},
        %{"kind" => "home", "path" => "/work/home"},
        %{"kind" => "config_dir", "path" => "/work/config"},
        %{"kind" => "tmp", "path" => "/work/tmp"}
      ],
      "env" => %{"ARB_HOST" => "http://127.0.0.1:4848"},
      "secrets" => %{"CLAUDE_CODE_OAUTH_TOKEN" => @token},
      "limits" => %{"memory" => "2g"},
      "command" => ["claude", "--print"]
    }
  end

  # Run `spec` to its end and let the node forget the run, as it does once the
  # primary has acked the exit.
  defp finished_run(run, opts) do
    assert {:ok, ^run} = Runs.assign(spec(run), opts)
    assert_receive {:run_push, ^run, "exit", _}, 5_000
    assert :ok = Run.ack_exit(run)
    wait_until(fn -> run not in Runs.run_ids() end)
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn ->
      if fun.() or System.monotonic_time(:millisecond) > deadline,
        do: :done,
        else: Process.sleep(15)
    end)
    |> Enum.find(&(&1 == :done))

    assert fun.()
  end

  defp argv(stub), do: File.read!(Path.join(stub, "run.argv")) |> String.split("\n", trim: true)

  test "runs the command in the run's own image and mounts after the run is gone", %{
    opts: opts,
    stub: stub
  } do
    finished_run("x1", opts)

    assert {"line-1\nline-2\nline-3\n", 0} =
             Exec.run("x1", "mix format --check-formatted", 30, opts)

    argv = argv(stub)
    assert ["sh", "-c", "mix format --check-formatted"] = Enum.take(argv, -3)
    assert "localhost/arbiter-dev/beam:abc123" in argv
    assert "--rm" in argv
    assert "--read-only" in argv and "--cap-drop=all" in argv
    assert "--network=none" in argv
    assert Enum.any?(argv, &String.ends_with?(&1, ":/work/tree:rw,Z"))
    assert Enum.any?(argv, &String.ends_with?(&1, ":/work/home:rw,Z"))

    # not the agent's container name (it could still be on its way out), and labelled for the reaper
    name = argv |> Enum.drop_while(&(&1 != "--name")) |> Enum.at(1)
    assert String.starts_with?(name, "arb-x1-") and name != "arb-x1"
    assert "arbiter.run=x1" in argv
  end

  test "none of the agent's secrets are in the command's container", %{opts: opts, stub: stub} do
    finished_run("x2", opts)
    assert {_, 0} = Exec.run("x2", "true", 30, opts)

    # `run.argv` / `run.env` are the exec container's (the agent's own run is over).
    argv = argv(stub)
    refute Enum.any?(argv, &(&1 =~ "secrets.env" or &1 =~ @token))
    refute File.read!(Path.join(stub, "run.env")) =~ @token
  end

  test "the container is removed by name afterwards", %{opts: opts, stub: stub} do
    finished_run("x3", opts)
    assert {_, 0} = Exec.run("x3", "true", 30, opts)
    assert File.read!(Path.join(stub, "calls")) =~ ~r/rm --force --ignore --time 0 arb-x3-/
  end

  test "a run the agent never prepared has no context: an error, nothing started", %{
    opts: opts,
    stub: stub
  } do
    assert {:error, :no_context} = Exec.run("never-assigned", "true", 30, opts)
    refute File.exists?(Path.join(stub, "calls"))
  end

  test "the Podman backend serves it", %{opts: opts} do
    finished_run("x4", opts)
    assert {_, 0} = Backend.Podman.exec("x4", "true", 30, opts)
    assert {:error, :no_context} = Backend.Podman.exec("nope", "true", 30, opts)
  end
end
