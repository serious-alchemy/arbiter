defmodule Arbiter.NodeAgent.RunTest do
  @moduledoc """
  RW9: the agent's run supervisor against a stub `podman` (a real Port, the
  real `Container.wrap/2` argv, a real exit path). Covers the acceptance
  criteria for the agent half: stdout streams with ack/replay across a channel
  blip, exit status and OOMKilled are reported, unsafe specs are refused, and a
  provider token never reaches persistent storage on the node (no `-e`, no
  podman graph copy, no file under the node's home) — only a tmpfs file that
  is gone once the container is.
  """
  # async: false — the stub reads STUB_PODMAN_DIR from the process environment.
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.{Config, Run, Runs, StubPodman}
  alias Arbiter.Nodes.StdoutFrame

  @token "sk-ant-oat01-SECRETMARKER-7f3a"

  setup do
    root = Path.join(System.tmp_dir!(), "ra-#{System.unique_integer([:positive])}")
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

    %{root: root, stub: stub_dir, home: home, rt: rt, opts: opts}
  end

  defp spec(run, overrides \\ %{}) do
    Map.merge(
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
          %{
            "kind" => "config_dir",
            "path" => "/work/config",
            "files" => %{"settings.json" => Base.encode64("{}")}
          },
          %{"kind" => "tmp", "path" => "/work/tmp"},
          %{
            "kind" => "cli",
            "name" => "claude",
            "sha256" => String.duplicate("a", 64),
            "path" => "/opt/arbiter/cli/claude"
          }
        ],
        "env" => %{"ARB_HOST" => "http://127.0.0.1:4848"},
        "secrets" => %{"CLAUDE_CODE_OAUTH_TOKEN" => @token},
        "limits" => %{"memory" => "2g", "cpus" => "2"},
        "command" => ["claude", "--print"]
      },
      overrides
    )
  end

  # Every frame the run pushed so far, as {offset, bytes}, plus the non-frame events.
  defp drain(run, acc \\ []) do
    receive do
      {:run_push, ^run, "stdout", {:binary, frame}} ->
        {:ok, ^run, offset, bytes} = StdoutFrame.decode(frame)
        drain(run, [{:stdout, offset, bytes} | acc])

      {:run_push, ^run, event, payload} ->
        drain(run, [{event, payload} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # The run process is gone (a refused or acked run stops itself).
  defp assert_gone(run) do
    case Registry.lookup(Arbiter.NodeAgent.RunRegistry, run) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      [] ->
        :ok
    end

    wait_until(fn -> run not in Runs.run_ids() end, 5_000)
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  defp wait_event(run, event) do
    assert_receive {:run_push, ^run, ^event, payload}, 5_000
    payload
  end

  describe "worktree files (bd-8y8ztm)" do
    test "the injected agent config is written into the worktree mount before the container starts",
         %{opts: opts, home: home, stub: stub} do
      body =
        ~s({"mcpServers":{"arbiter":{"headers":{"Authorization":"Bearer ${ARBITER_MCP_TOKEN}"}}}})

      spec =
        spec("rwf", %{
          "mounts" => [
            %{
              "kind" => "worktree",
              "path" => "/work/tree",
              "files" => %{
                ".mcp.json" => Base.encode64(body),
                ".claude/skills/tdd/SKILL.md" => Base.encode64("# tdd")
              }
            },
            %{"kind" => "home", "path" => "/work/home"},
            %{"kind" => "config_dir", "path" => "/work/config"},
            %{"kind" => "tmp", "path" => "/work/tmp"}
          ],
          "secrets" => %{"ARBITER_MCP_TOKEN" => "mcp-tok-123"}
        })

      assert {:ok, "rwf"} = Runs.assign(spec, opts)
      wait_event("rwf", "exit")

      tree = Path.join([home, "runs", "rwf", "worktree"])
      assert File.read!(Path.join(tree, ".mcp.json")) == body
      assert File.read!(Path.join(tree, ".claude/skills/tdd/SKILL.md")) == "# tdd"

      # the host side of the mount is the dir the files were written to
      argv = File.read!(Path.join(stub, "run.argv")) |> String.split("\n", trim: true)
      assert Enum.any?(argv, &(&1 == tree <> ":/work/tree:rw,Z"))

      # the token never lands in a file under the node's home
      {out, _} = System.cmd("grep", ["-rl", "mcp-tok-123", home])
      assert out == ""
    end
  end

  describe "a run to completion" do
    test "streams stdout, reports exit status 0 and oom false", %{opts: opts, stub: stub} do
      File.write!(Path.join(stub, "lines"), "5")
      assert {:ok, "r1"} = Runs.assign(spec("r1"), opts)

      assert %{"container" => "arb-r1"} = wait_event("r1", "run.ready")
      exit = wait_event("r1", "exit")
      assert %{"status" => 0, "oom" => false, "cancelled" => false, "run" => "r1"} = exit

      events = drain("r1")
      bytes = for {:stdout, _, b} <- events, into: "", do: b
      assert bytes == "line-1\nline-2\nline-3\nline-4\nline-5\n"
      assert exit["size"] == byte_size(bytes)
      assert Runs.run_ids() == ["r1"]

      assert :ok = Run.ack_exit("r1")
      assert_gone("r1")
    end

    test "the container is run by the agent's own hardened argv, kept (no --rm), capped, labelled",
         %{opts: opts, stub: stub} do
      assert {:ok, "r2"} = Runs.assign(spec("r2"), opts)
      wait_event("r2", "exit")

      argv = File.read!(Path.join(stub, "run.argv")) |> String.split("\n", trim: true)
      refute "--rm" in argv
      assert "--read-only" in argv
      assert "--cap-drop=all" in argv
      assert "no-new-privileges" in argv
      assert "--network=none" in argv
      assert "--memory" in argv and "2g" in argv
      assert "--cpus" in argv

      assert "arbiter.run=r2" in argv and "arbiter.node=n1" in argv and
               "arbiter.install=inst1" in argv

      # path transparency: the container sees the primary's paths
      assert Enum.any?(argv, &String.ends_with?(&1, ":/work/tree:rw,Z"))
      assert "/opt/arbiter/cli/claude" in Enum.map(argv, &(&1 |> String.split(":") |> Enum.at(1)))

      for flag <- ~w(--privileged --cap-add --device --pid=host --network=host --userns=host) do
        refute flag in argv
      end
    end

    test "OOMKilled is read from the kept container and reported", %{opts: opts, stub: stub} do
      StubPodman.write_mode(stub, "oom")
      assert {:ok, "r3"} = Runs.assign(spec("r3"), opts)
      assert %{"status" => 137, "oom" => true} = wait_event("r3", "exit")
      calls = File.read!(Path.join(stub, "calls"))
      assert calls =~ "inspect"
      # removed by name after the flag was read
      assert calls =~ "rm --force --ignore --time 0 arb-r3"
    end

    test "limits for a controller that is not delegated are not emitted; no memory controller is refused",
         %{opts: opts, stub: stub} do
      opts = Keyword.put(opts, :delegated_fun, fn -> ["memory"] end)
      assert {:ok, "r4"} = Runs.assign(spec("r4"), opts)
      wait_event("r4", "exit")
      argv = File.read!(Path.join(stub, "run.argv")) |> String.split("\n", trim: true)
      assert "--memory" in argv
      refute "--cpus" in argv

      opts = Keyword.put(opts, :delegated_fun, fn -> ["pids"] end)
      assert {:ok, "r5"} = Runs.assign(spec("r5"), opts)
      assert %{"reason" => "unschedulable", "detail" => detail} = wait_event("r5", "run.refused")
      assert detail =~ "memory_not_delegated"
    end
  end

  describe "stdout ack and replay across a channel blip" do
    test "a detach and re-attach resends from the last ack; nothing lost or duplicated by offset",
         %{opts: opts, stub: stub} do
      StubPodman.write_mode(stub, "hang")
      assert {:ok, "b1"} = Runs.assign(spec("b1"), opts)
      wait_event("b1", "run.ready")
      assert_receive {:run_push, "b1", "stdout", {:binary, frame}}, 5_000
      assert {:ok, "b1", 0, "line-1\n"} = StdoutFrame.decode(frame)

      # The channel drops before the primary acks anything.
      Runs.detach_all()
      _ = Run.info("b1")
      File.write!(Path.join(stub, "removed"), "")
      # more output is not pushed while detached ...
      refute_receive {:run_push, "b1", "stdout", _}, 200

      # ... and the exit is held until the channel returns.
      Runs.attach_all()
      events = drain("b1")
      assert {:stdout, 0, "line-1\n"} in events
      assert Enum.any?(events, &match?({"exit", %{"status" => 137, "cancelled" => false}}, &1))

      # An ack moves the replay point: a second blip resends nothing already acked.
      Run.ack("b1", 7)
      Runs.detach_all()
      Runs.attach_all()
      events = drain("b1")
      assert Enum.filter(events, &match?({:stdout, _, _}, &1)) == []
      # the exit is resent until acked
      assert Enum.any?(events, &match?({"exit", _}, &1))
    end

    test "no more than 256 KiB is in flight; an ack opens the window", %{opts: opts, stub: stub} do
      StubPodman.write_mode(stub, "big")
      System.put_env("STUB_BYTES", "600000")
      on_exit(fn -> System.delete_env("STUB_BYTES") end)
      assert {:ok, "w1"} = Runs.assign(spec("w1"), opts)
      wait_event("w1", "exit")

      events = drain("w1")
      sent = for {:stdout, _, b} <- events, do: byte_size(b)
      assert Enum.sum(sent) == 262_144
      assert Enum.max(sent) <= 16_384

      Run.ack("w1", 262_144)
      events = drain("w1")

      assert events
             |> Enum.filter(&match?({:stdout, _, _}, &1))
             |> Enum.map(&elem(&1, 2))
             |> Enum.map(&byte_size/1)
             |> Enum.sum() == 262_144

      Run.ack("w1", 524_288)
      events = drain("w1")

      assert events
             |> Enum.filter(&match?({:stdout, _, _}, &1))
             |> Enum.map(&elem(&1, 2))
             |> Enum.map(&byte_size/1)
             |> Enum.sum() == 600_001 - 524_288
    end
  end

  describe "cancel" do
    test "removes the container by name and reports a cancelled exit", %{opts: opts, stub: stub} do
      StubPodman.write_mode(stub, "hang")
      assert {:ok, "c1"} = Runs.assign(spec("c1"), opts)
      wait_event("c1", "run.ready")
      assert :ok = Run.cancel("c1", "operator")
      assert %{"cancelled" => true, "reason" => "operator"} = wait_event("c1", "exit")
      assert File.read!(Path.join(stub, "calls")) =~ "rm --force --ignore --time 0 arb-c1"
    end

    test "fence_all stops every container", %{opts: opts, stub: stub} do
      StubPodman.write_mode(stub, "hang")
      {:ok, _} = Runs.assign(spec("f1"), opts)
      wait_event("f1", "run.ready")
      Runs.fence_all()
      assert %{"cancelled" => true, "reason" => "fenced"} = wait_event("f1", "exit")
    end
  end

  describe "unsafe specs are refused" do
    test "a spec asking for an unsafe flag starts nothing", %{opts: opts, stub: stub} do
      for flag <- [
            "--privileged",
            "--cap-add=SYS_ADMIN",
            "--device=/dev/kvm",
            "--userns=host",
            "--pid=host",
            "--network=host"
          ] do
        assert {:error, {:refused, {:unsafe_flag, _}}} =
                 Runs.assign(spec("u1", %{"extra_args" => [flag]}), opts)
      end

      assert {:error, {:refused, {:unknown_field, "privileged"}}} =
               Runs.assign(spec("u1", %{"privileged" => true}), opts)

      refute File.exists?(Path.join(stub, "calls"))
      assert Runs.run_ids() == []
    end
  end

  describe "secrets never reach persistent storage on the node (RW2/U13)" do
    test "no -e, no podman graph copy, no file under the node home; a tmpfs file only while the container lives",
         %{opts: opts, stub: stub, home: home, rt: rt} do
      StubPodman.write_mode(stub, "hang")
      assert {:ok, "s1"} = Runs.assign(spec("s1", %{"env" => %{"PLAIN" => "visible"}}), opts)
      wait_event("s1", "run.ready")
      # the stub prints its first line after it has recorded its argv and env
      assert_receive {:run_push, "s1", "stdout", _}, 5_000

      # While running: the file is on the runtime (tmpfs) dir, 0600, with the value.
      file = Path.join([rt, "arbiter-node", "s1", "secrets.env"])
      assert File.regular?(file)
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
      assert File.read!(file) =~ @token

      argv = File.read!(Path.join(stub, "run.argv"))
      # no secret on argv, no `-e NAME` for it, and the wrapper sources the file
      refute argv =~ @token
      refute argv =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert argv =~ ". /run/arbiter/secrets.env; exec \"$@\""
      assert argv =~ "#{file}:/run/arbiter/secrets.env:ro"
      # non-secret env still travels the ordinary way
      assert argv =~ "PLAIN=visible"

      # What the container saw mounted is the file; the client's env and what
      # podman would persist (graph/config.json) hold no copy.
      assert File.read!(Path.join(stub, "secrets.seen")) =~ @token
      refute File.read!(Path.join(stub, "run.env")) =~ @token
      refute File.read!(Path.join([stub, "graph", "config.json"])) =~ @token

      File.write!(Path.join(stub, "removed"), "")
      wait_event("s1", "exit")

      # After exit: the tmpfs file and its directory are gone, and a scan of
      # everything persistent (the node's home, everything the stub recorded
      # outside the mounted-file copy it made for the test) finds nothing.
      refute File.exists?(file)
      refute File.exists?(Path.dirname(file))

      persistent =
        home
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map_join("\n", &File.read!/1)

      refute persistent =~ @token

      recorded =
        stub
        |> StubPodman.recorded()
        |> String.replace(File.read!(Path.join(stub, "secrets.seen")), "")

      refute recorded =~ @token
    end

    test "with no tmpfs runtime dir the run is refused and nothing is written", %{
      opts: opts,
      root: root,
      rt: rt
    } do
      on_disk = Path.join(root, "mountinfo-disk")
      File.write!(on_disk, "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n")
      opts = opts |> Keyword.put(:require_tmpfs, true) |> Keyword.put(:mountinfo, on_disk)

      assert {:ok, "s2"} = Runs.assign(spec("s2"), opts)
      assert %{"reason" => "unschedulable", "detail" => detail} = wait_event("s2", "run.refused")
      assert detail =~ "secrets_not_on_tmpfs"
      assert_gone("s2")
      refute File.exists?(Path.join(rt, "arbiter-node"))
      refute Enum.any?(drain("s2"), &match?({:stdout, _, _}, &1))
    end

    test "a tmpfs runtime dir is accepted", %{opts: opts, root: root, rt: rt} do
      tmpfs = Path.join(root, "mountinfo-tmpfs")

      File.write!(
        tmpfs,
        "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:30 / #{rt} rw - tmpfs tmpfs rw\n"
      )

      opts = opts |> Keyword.put(:require_tmpfs, true) |> Keyword.put(:mountinfo, tmpfs)
      assert {:ok, "s3"} = Runs.assign(spec("s3"), opts)
      assert %{"status" => 0} = wait_event("s3", "exit")
    end
  end

  describe "bridges" do
    test "a spec that names bridges is refused until a listener provider exists (RW10)", %{
      opts: opts
    } do
      spec =
        spec("g1", %{
          "bridges" => [%{"name" => "proxy", "path" => "/run/arbiter-bridge/proxy.sock"}]
        })

      assert {:ok, "g1"} = Runs.assign(spec, opts)
      assert %{"reason" => "unschedulable", "detail" => detail} = wait_event("g1", "run.refused")
      assert detail =~ "bridges_unavailable"
      assert_gone("g1")
    end
  end

  describe "quiesce (RW12: the primary does not know the run)" do
    test "a running run is stopped and retained locally, with no exit for the primary to ack",
         %{opts: opts, stub: stub, home: home} do
      StubPodman.write_mode(stub, "hang")
      assert {:ok, "q1"} = Runs.assign(spec("q1"), opts)
      wait_event("q1", "run.ready")

      assert :ok = Run.quiesce("q1")

      assert %{"run" => "q1", "task" => "bd-abc", "checkout" => nil} =
               wait_event("q1", "retained")

      assert_gone("q1")
      refute_received {:run_push, "q1", "exit", _}

      # the container was removed by name, and the manifest is on disk for hello
      assert File.read!(Path.join(stub, "calls")) =~ "rm --force --ignore --time 0 arb-q1"
      config = Keyword.fetch!(opts, :config)
      assert [%{"run" => "q1", "pulled" => false}] = Arbiter.NodeAgent.Retained.list(config)
      assert File.dir?(Path.join([home, "runs", "q1"]))
    end

    test "a run that already exited (exit unacked) is retained the same way", %{opts: opts} do
      assert {:ok, "q2"} = Runs.assign(spec("q2"), opts)
      wait_event("q2", "exit")

      assert :ok = Run.quiesce("q2")
      assert %{"run" => "q2"} = wait_event("q2", "retained")
      assert_gone("q2")
    end

    test "quiescing a run twice or an unknown run is harmless", %{opts: opts, stub: stub} do
      assert {:error, :not_found} = Run.quiesce("nope")
      StubPodman.write_mode(stub, "hang")
      assert {:ok, "q3"} = Runs.assign(spec("q3"), opts)
      wait_event("q3", "run.ready")
      assert :ok = Run.quiesce("q3")
      _ = Run.quiesce("q3")
      assert %{"run" => "q3"} = wait_event("q3", "retained")
      assert_gone("q3")
    end
  end
end
