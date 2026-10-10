defmodule ArbiterWeb.RemoteRunTest do
  @moduledoc """
  RW9 (bd-1o2zh6, `docs/design/remote-workers.md` §7, §10.2, §12), end to end
  across the real halves: `Executor.Node` and the node's `Session` on the
  primary, the real `NodeSocket`/`NodeChannel` over a Bandit listener, and the
  real agent (`Connection`, `Runs`, `Run`) driving a stand-in `podman` through a
  real `Port`.

  What this proves that the unit tests cannot: a run placed with a spec starts on
  the node, its stdout reaches the owner as Port-shaped messages, an exit carries
  status and `OOMKilled`, a channel blip replays unacknowledged output exactly
  once, a spec asking for an unsafe flag is refused by the agent, and the owner's
  death stops the container. The last test drives a real `Arbiter.Worker` through
  `ClaudeSession.start/1` with `node:` set.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.NodeAgent.{Config, Connection, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias ArbiterWeb.{NodeSocket, NodeTestEndpoint, StubPodman}

  @version "1.2.3"
  @token "sk-ant-oat01-REMOTEMARKER-91c"

  setup %{tmp_dir: tmp_dir} do
    # Short, comma-free: `Container` refuses a mount path with `,` or `:`, and a
    # `:tmp_dir` is named after the test.
    root = Path.join(System.tmp_dir!(), "rr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "remote-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    home = Path.join(root, "node-home")
    rt = Path.join(root, "rt")
    File.mkdir_p!(home)
    File.mkdir_p!(rt)
    cli = Path.join(root, "claude")
    File.write!(cli, "#!/bin/sh\n")
    File.chmod!(cli, 0o755)

    {:ok, config} =
      Config.load(
        env: %{},
        primary_url: "http://127.0.0.1:#{NodeTestEndpoint.port()}",
        node_home: home,
        read_credential: fn _ -> {:ok, credential} end,
        version: @version,
        hb_interval_ms: 200,
        fence_after_ms: 60_000,
        backoff: [base: 20, max: 80],
        readiness_fun: fn -> %{ready: true, installed: true, checks: []} end,
        # what `Arbiter.NodeAgent.Supervisor` wires: the agent reports its runs in `hello`/`hb`
        live_runs_fun: &Runs.inventory/0,
        run_opts: [
          podman: podman,
          runtime_dir: rt,
          require_tmpfs: false,
          image_fun: fn _image, _opts -> :ok end,
          files_fun: fn _sha, _name -> {:ok, cli} end,
          delegated_fun: fn -> ["memory", "pids", "cpu"] end,
          bridges_fun: fn _run, bridges -> {:ok, Enum.map(bridges, fn _ -> cli end)} end
        ]
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)
    start_supervised!({Connection, config: config})

    assert_receive {:node_state, id, :online}, 10_000
    assert id == node.id
    session = Registry.lookup(node.id)
    assert is_pid(session)

    %{node: node, session: session, stub: stub, rt: rt, home: home, cli: cli, root: root}
  end

  defp put_env_restoring(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp spec(run, overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "run" => run,
        "task" => "bd-e2e",
        "name" => "arb-#{run}",
        "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
        "cwd" => "/work/tree",
        "mounts" => [
          %{"kind" => "worktree", "path" => "/work/tree"},
          %{"kind" => "home", "path" => "/work/home"},
          %{"kind" => "config_dir", "path" => "/work/config"},
          %{"kind" => "tmp", "path" => "/work/tmp"}
        ],
        "env" => %{},
        "secrets" => %{"CLAUDE_CODE_OAUTH_TOKEN" => @token},
        "limits" => %{"memory" => "1g"},
        "command" => ["claude", "--print"]
      },
      overrides
    )
  end

  defp collect(handle, acc \\ []) do
    receive do
      {^handle, {:data, {_kind, line}}} -> collect(handle, [{:line, line} | acc])
      {^handle, {:outcome, outcome}} -> collect(handle, [{:outcome, outcome} | acc])
      {^handle, {:exit_status, status}} -> Enum.reverse([{:exit, status} | acc])
    after
      10_000 -> flunk("no exit_status for #{inspect(handle)}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  describe "a run placed on the node" do
    test "starts from a spec, streams Port-shaped lines, and ends with its outcome", ctx do
      File.write!(Path.join(ctx.stub, "lines"), "4")
      assert {:ok, prepared} = Executor.prepare(%{id: ctx.node.id}, spec("e1"), owner: self())
      assert {:ok, {:remote, {node_id, "e1", _ref}} = handle} = Executor.open(prepared)
      assert node_id == ctx.node.id

      assert [
               {:line, "line-1"},
               {:line, "line-2"},
               {:line, "line-3"},
               {:line, "line-4"},
               {:outcome, %{oom?: false, exit_code: 0, cancelled?: false}},
               {:exit, 0}
             ] = collect(handle)

      assert {:ok, %{exit_code: 0}} = Executor.outcome(handle)
      refute Executor.live?(handle)
    end

    # bd-9rrrgk: the pre-push recipe of a run placed here runs on the node, after the run's
    # agent has exited and the node has forgotten it.
    test "exec runs a command in a container of the run's shape once the run is over", ctx do
      {:ok, prepared} = Executor.prepare(ctx.node.id, spec("e1x"), owner: self())
      {:ok, handle} = Executor.open(prepared)
      assert [_ | _] = collect(handle)
      assert_eventually(fn -> not Executor.live?(handle) end)

      assert {"line-1\nline-2\nline-3\n", 0} =
               Executor.exec(ctx.node.id, "e1x", "mix format --check-formatted", 30)

      argv = File.read!(Path.join(ctx.stub, "run.argv")) |> String.split("\n", trim: true)
      assert ["sh", "-c", "mix format --check-formatted"] = Enum.take(argv, -3)
      assert "--rm" in argv
      refute Enum.any?(argv, &(&1 =~ "secrets.env"))
    end

    test "exec for a run the node never prepared is an error from the node", ctx do
      assert {:error, {:exec_failed, reason}} = Executor.exec(ctx.node.id, "never", "true", 30)
      assert reason =~ "no_context"
    end

    test "OOMKilled and the exit code are reported", ctx do
      StubPodman.write_mode(ctx.stub, "oom")
      {:ok, prepared} = Executor.prepare(ctx.node.id, spec("e2"), owner: self())
      {:ok, handle} = Executor.open(prepared)

      assert [{:line, "line-1"}, {:outcome, %{oom?: true, exit_code: 137}}, {:exit, 137}] =
               collect(handle)
    end

    test "stop/1 removes the container by name and the owner hears a cancelled exit", ctx do
      StubPodman.write_mode(ctx.stub, "hang")
      {:ok, prepared} = Executor.prepare(ctx.node.id, spec("e3"), owner: self())
      {:ok, handle} = Executor.open(prepared)
      assert Executor.live?(handle)

      assert :ok = Executor.stop(handle)
      assert [{:line, "line-1"}, {:outcome, %{cancelled?: true}}, {:exit, 137}] = collect(handle)
      assert File.read!(Path.join(ctx.stub, "calls")) =~ "rm --force --ignore --time 0 arb-e3"
    end

    test "a dying owner has its container stopped", ctx do
      StubPodman.write_mode(ctx.stub, "hang")
      test = self()

      owner =
        spawn(fn ->
          {:ok, prepared} = Executor.prepare(ctx.node.id, spec("e4"), owner: self())
          send(test, {:placed, prepared.handle})
          Process.sleep(:infinity)
        end)

      assert_receive {:placed, handle}, 10_000
      assert Executor.live?(handle)
      Process.exit(owner, :kill)

      # the session cancels it: the agent removes the container
      assert_eventually(fn ->
        match?({:ok, body} when is_binary(body), File.read(Path.join(ctx.stub, "calls"))) and
          File.read!(Path.join(ctx.stub, "calls")) =~ "rm --force --ignore --time 0 arb-e4"
      end)
    end
  end

  describe "a channel blip" do
    test "loses no output and delivers none twice", ctx do
      StubPodman.write_mode(ctx.stub, "slow")
      {:ok, prepared} = Executor.prepare(ctx.node.id, spec("b1"), owner: self())
      {:ok, handle} = Executor.open(prepared)
      assert_receive {^handle, {:data, {:eol, "line-1"}}}, 10_000

      # Drop the socket under the run, and let the agent come back.
      NodeSocket.disconnect(ctx.node.id)
      assert_receive {:node_connection, _, :down}, 10_000
      assert_receive {:node_connection, _, :up}, 10_000

      # The container kept running through the blip; its remaining output now flows.
      File.write!(Path.join(ctx.stub, "go"), "")

      assert [{:line, "line-2"}, {:line, "line-3"}, {:outcome, %{exit_code: 0}}, {:exit, 0}] =
               collect(handle)

      # line-1 was replayed by the agent after the blip; the primary dropped it.
      refute_received {^handle, {:data, {:eol, "line-1"}}}
    end
  end

  describe "refusals" do
    test "a spec asking for an unsafe flag is refused by the agent and nothing starts", ctx do
      for flag <- ["--privileged", "--cap-add=SYS_ADMIN", "--network=host"] do
        assert {:error, {:refused, "bad_spec", detail}} =
                 Executor.prepare(ctx.node.id, spec("x1", %{"extra_args" => [flag]}),
                   owner: self()
                 )

        assert detail =~ "unsafe_flag"
      end

      refute File.exists?(Path.join(ctx.stub, "calls"))
      assert Runs.run_ids() == []
    end

    test "a node that is not connected cannot take a run" do
      assert {:error, :no_session} = Executor.prepare("no-such-node", spec("x2"), owner: self())
    end
  end

  describe "secrets" do
    test "the token reaches the container only through the tmpfs file: not argv, not -e, not the node's disk",
         ctx do
      StubPodman.write_mode(ctx.stub, "hang")
      {:ok, prepared} = Executor.prepare(ctx.node.id, spec("s1"), owner: self())
      {:ok, handle} = Executor.open(prepared)
      assert_receive {^handle, {:data, {:eol, "line-1"}}}, 10_000

      argv = File.read!(Path.join(ctx.stub, "run.argv"))
      refute argv =~ @token
      refute argv =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert argv =~ "/run/arbiter/secrets.env"
      assert File.read!(Path.join(ctx.stub, "secrets.seen")) =~ @token
      refute File.read!(Path.join([ctx.stub, "graph", "config.json"])) =~ @token

      Executor.stop(handle)
      collect(handle)

      node_disk =
        ctx.home
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map_join("\n", &File.read!/1)

      refute node_disk =~ @token
      refute File.exists?(Path.join([ctx.rt, "arbiter-node", "s1"]))
    end
  end

  describe "through a real Worker" do
    # `ClaudeSession.start/1` with `node:` set: the primary half runs here
    # (egress, published CLI, spec), the run is placed, and the Worker gets the
    # handle's lines on its PubSub topic exactly as it would a port's.
    test "the worker is the owner: output, exit, and a re-open that places the run again", ctx do
      alias Arbiter.Agents.SecurityPolicy
      alias Arbiter.Worker
      alias Arbiter.Worker.ClaudeSession

      for {key, value} <- [
            worker_container_available: true,
            worker_container_network_available: true
          ] do
        put_env_restoring(:arbiter, key, value)
      end

      sockets = Path.join(ctx.root, "sockets")
      File.mkdir_p!(sockets)
      proxy = Path.join(sockets, "proxy.sock")
      bridge = Path.join(sockets, "arb.sock")
      File.write!(proxy, "")
      File.write!(bridge, "")

      egress = fn _opts ->
        {:ok, [proxy_socket: proxy, proxy_port: 38_001, bridges: [{38_002, bridge}]], "rtest"}
      end

      worktree = Path.join(ctx.root, "clone")
      File.mkdir_p!(worktree)

      task_id = "bd-rw9e2e-#{System.unique_integer([:positive])}"
      {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> task_id)

      policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})

      File.write!(Path.join(ctx.stub, "lines"), "2")

      start = fn ->
        ClaudeSession.start(
          owner: pid,
          worktree_path: worktree,
          command: [
            "sh",
            "-c",
            ~s(exec "$@" < /dev/null),
            "sh",
            "/opt/arbiter/cli/claude",
            "--print",
            "go"
          ],
          env: [{"CLAUDE_CODE_OAUTH_TOKEN", @token}, {"ARB_WORKER_BEAD_ID", task_id}],
          security: policy,
          provider: "claude",
          image: "localhost/arbiter-dev/beam:abc123",
          claude_path: ctx.cli,
          arb_path: ctx.cli,
          egress: egress,
          arb_token: "arb-tok",
          node: %{id: ctx.node.id, capacity: %{"mem_total" => 8 * 1024 * 1024 * 1024}}
        )
      end

      assert {:ok, {:remote, {_, _, _}} = handle} = start.()
      assert_receive {:worker_output, ^task_id, "line-1"}, 10_000
      assert_receive {:worker_output, ^task_id, "line-2"}, 10_000
      assert_receive {:worker_exited, ^task_id, 0}, 10_000

      # What the container was started with: the primary's paths, the memory cap
      # from the node's reported memory, the token in the file, not on argv.
      argv = File.read!(Path.join(ctx.stub, "run.argv"))
      assert argv =~ worktree
      assert argv =~ "--memory\n3276m"
      refute argv =~ @token
      assert File.read!(Path.join(ctx.stub, "secrets.seen")) =~ @token

      # The stashed spawn carries the request (not the consumed handle), so a
      # re-open places the run again.
      assert %{remote: %{prepared: nil, request: %{name: name}}} =
               Worker.state(pid).meta.claude_spawn

      assert String.starts_with?(name, "arb-bd-rw9e2e")

      GenServer.stop(pid, :normal)
      _ = handle
    end

    # bd-4ic681: a run placed on a node is assigned before its session opens, so the
    # spec must already carry what the first open runs. For a session resume that is
    # `--resume <sid>` and the terse continue prompt the Worker splices in, not the
    # original work prompt.
    test "a session resume's first open on the node runs --resume <sid>", ctx do
      alias Arbiter.Agents.SecurityPolicy
      alias Arbiter.Worker
      alias Arbiter.Worker.ClaudeSession

      for {key, value} <- [
            worker_container_available: true,
            worker_container_network_available: true
          ] do
        put_env_restoring(:arbiter, key, value)
      end

      sockets = Path.join(ctx.root, "sockets")
      File.mkdir_p!(sockets)
      proxy = Path.join(sockets, "proxy.sock")
      bridge = Path.join(sockets, "arb.sock")
      File.write!(proxy, "")
      File.write!(bridge, "")

      egress = fn _opts ->
        {:ok, [proxy_socket: proxy, proxy_port: 38_011, bridges: [{38_012, bridge}]], "rtest"}
      end

      worktree = Path.join(ctx.root, "clone")
      File.mkdir_p!(worktree)
      sid = "0b5e7a4c-55d6-4c1f-9a51-6f3a1f2d9c01"

      task_id = "bd-rw9resume-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Worker.start(task_id: task_id, repo: "arbiter", meta: %{resume_session_id: sid})

      Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> task_id)

      policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})

      assert {:ok, {:remote, _}} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: worktree,
                 command: [
                   "sh",
                   "-c",
                   ~s(exec "$@" < /dev/null),
                   "sh",
                   "/opt/arbiter/cli/claude",
                   "--print",
                   "the original work prompt"
                 ],
                 env: [{"CLAUDE_CODE_OAUTH_TOKEN", @token}, {"ARB_WORKER_BEAD_ID", task_id}],
                 security: policy,
                 provider: "claude",
                 image: "localhost/arbiter-dev/beam:abc123",
                 claude_path: ctx.cli,
                 arb_path: ctx.cli,
                 egress: egress,
                 arb_token: "arb-tok",
                 node: %{id: ctx.node.id, capacity: %{"mem_total" => 8 * 1024 * 1024 * 1024}}
               )

      assert_receive {:worker_exited, ^task_id, 0}, 10_000

      argv = ctx.stub |> Path.join("run.argv") |> File.read!() |> String.split("\n")
      assert ["--resume", ^sid | _] = Enum.drop_while(argv, &(&1 != "--resume"))
      refute "the original work prompt" in argv

      # What is stashed for later opens is the pristine argv (they splice their own).
      assert %{claude_spawn: %{argv: stashed}} = Worker.state(pid).meta
      refute "--resume" in stashed

      GenServer.stop(pid, :normal)
    end
  end

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          50 -> assert_eventually(fun, tries - 1)
        end
    end
  end
end
