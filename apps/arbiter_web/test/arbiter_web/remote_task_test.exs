defmodule ArbiterWeb.RemoteTaskTest do
  @moduledoc """
  bd-6ypj2y, end to end across the real halves: a `task` / `research` ticket's
  run placed on a node with the **read-only inspect checkout** `Dispatch` hands a
  podman run of one (a `PrivateClone.create_review/3` clone of the target tip).

  The real agent seeds its shadow clone from that clone over real HTTP, a stand-in
  `podman` plays the agent (it edits and, in one test, *commits* in the shadow and
  writes a session transcript), and the **real egress run and `arb` bridge** carry
  the agent's `ticket_update_progress` call back to the real endpoint. Asserted:

    * the node is seeded at the target tip;
    * notes written from the node land on the primary's ticket, exactly as a local
      run's do, and the transcript is mirrored into the run's config dir;
    * nothing comes back as work: no checkpoint ref, a clean home clone, the
      agent's commit never reaches it or the main repo, and there is nothing to
      collect;
    * the ticket then completes with `pr_ref: nil` and no PR/branch ever existed.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.MCP.Scope
  alias Arbiter.NodeAgent.{Bridge, Config, Connection, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Reviews.Checkout
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias Arbiter.Worker.PrivateClone
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"

  setup %{tmp_dir: tmp_dir} do
    # Unix socket paths live under it: the deep worker TMPDIR would exceed the limit.
    root =
      Path.join(Arbiter.Config.Paths.socket_root(), "rt-#{System.unique_integer([:positive])}")

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

    endpoint =
      start_supervised!(
        {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
        id: :arbiter_endpoint
      )

    {:ok, {_address, api_port}} = ThousandIsland.listener_info(endpoint)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "task-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    File.write!(Path.join(stub, "edit"), "")
    home = Path.join(root, "nh")
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
        live_runs_fun: &Runs.inventory/0,
        run_opts: [
          podman: podman,
          runtime_dir: rt,
          require_tmpfs: false,
          image_fun: fn _image, _opts -> :ok end,
          files_fun: fn _sha, _name -> {:ok, cli} end,
          delegated_fun: fn -> ["memory", "pids", "cpu"] end,
          bridges_fun: &Bridge.listen/2,
          bridges_release_fun: &Bridge.release/1
        ]
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)
    start_supervised!({Bridge, node_home: home})
    start_supervised!({Connection, config: config})
    assert_receive {:node_state, _id, :online}, 10_000

    # The primary's repo and the read-only inspect checkout `Dispatch` cuts from it.
    repo = Path.join(root, "primary")
    tip = repo!(repo)
    refs = refs(repo)

    {:ok, %{path: clone}} =
      Checkout.provision_branch(repo, "main",
        path: Path.join(root, "inspect"),
        layout: :private_clone,
        base: "main"
      )

    ws =
      Ash.create!(Workspace, %{
        name: "rt-#{System.unique_integer([:positive])}",
        prefix: "rt#{System.unique_integer([:positive])}",
        config: %{}
      })

    task = Ash.create!(Issue, %{title: "investigate", workspace_id: ws.id, issue_type: :research})

    %{
      node: node,
      root: root,
      stub: stub,
      home: home,
      api_port: api_port,
      repo: repo,
      tip: tip,
      refs: refs,
      clone: clone,
      task: task,
      config_dir: Path.join(root, "primary-config"),
      egress_dir: Path.join(root, "eg")
    }
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

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", args,
        cd: dir,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}],
        stderr_to_stdout: true
      )

    String.trim_trailing(out)
  end

  defp repo!(repo) do
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "lib/a.txt"), "a\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  # The branches and remote refs of the main repo: what a push or sync-back would move.
  defp refs(repo),
    do:
      git!(repo, [
        "for-each-ref",
        "--format=%(refname) %(objectname)",
        "refs/heads",
        "refs/remotes"
      ])

  defp egress_run!(ctx) do
    owner = start_supervised!({Agent, fn -> :ok end}, id: make_ref())

    {:ok, _network, run} =
      JailRun.start(
        owner: owner,
        dir: ctx.egress_dir,
        arbiter_url: "http://127.0.0.1:#{ctx.api_port}/mcp",
        arb_token: Scope.mint_worker(ctx.task),
        task_id: ctx.task.id,
        enforce: true,
        infra: [],
        allow_local_dial: true
      )

    on_exit(fn -> Egress.stop_run(run) end)
    run
  end

  defp spec(ctx, run) do
    %{
      "version" => 1,
      "run" => run,
      "task" => ctx.task.id,
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
      "secrets" => %{},
      "limits" => %{"memory" => "1g"},
      "bridges" => [
        %{"name" => "proxy", "path" => Egress.socket_path(run, ctx.egress_dir)},
        %{"name" => "arb", "path" => Egress.bridge_path(run, "arb", ctx.egress_dir)}
      ],
      "command" => ["claude", "--print"],
      "checkout" => %{
        "branch" => PrivateClone.branch(ctx.clone),
        "base" => "main",
        "read_only" => true
      }
    }
  end

  # The checkout block `ContainerSpawn.remote_checkout/3` builds for the clone.
  defp place(ctx, run) do
    checkout = %{
      home: ctx.clone,
      branch: PrivateClone.branch(ctx.clone),
      base: "main",
      seeded_paths: [],
      config_dir: ctx.config_dir,
      read_only?: PrivateClone.read_only?(ctx.clone)
    }

    Executor.prepare(ctx.node.id, spec(ctx, run), owner: self(), checkout: checkout)
  end

  defp await_exit(handle) do
    receive do
      {^handle, {:exit_status, status}} -> status
      {^handle, _other} -> await_exit(handle)
    after
      15_000 -> flunk("no exit for #{inspect(handle)}")
    end
  end

  defp assert_nothing_came_back(ctx) do
    assert git!(ctx.clone, ["status", "--porcelain"]) == ""
    assert git!(ctx.clone, ["rev-parse", "HEAD"]) == ctx.tip
    assert git!(ctx.clone, ["for-each-ref", "refs/arbiter/checkpoint"]) == ""
    assert git!(ctx.repo, ["for-each-ref", "refs/arbiter/checkpoint"]) == ""
    assert refs(ctx.repo) == ctx.refs
    refute File.exists?(Path.join(ctx.clone, "edited.txt"))
  end

  test "notes from the node reach the primary, the transcript comes back, and the ticket completes with no PR",
       ctx do
    assert PrivateClone.read_only?(ctx.clone)
    egress = egress_run!(ctx)
    StubPodman.write_mode(ctx.stub, "slow")

    assert {:ok, prepared} = place(ctx, egress)
    assert {:ok, handle} = Executor.open(prepared)
    assert_receive {^handle, {:data, {:eol, "line-1"}}}, 10_000

    # Seeded at the target tip.
    assert File.read!(Path.join(ctx.stub, "seeded.head")) |> String.trim() == ctx.tip

    # `ticket_update_progress`, from the node's `arb` bridge, to the primary's endpoint.
    bridge = Path.join([ctx.home, "runs", egress, "bridge", "arb.sock"])

    reply =
      http(bridge, "POST", "/mcp",
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "ticket_update_progress",
            "arguments" => %{"notes" => "## Findings\n\nFrom the node."}
          }
        }
      )

    assert reply.status == 200
    refute reply.body["error"]
    assert Ash.get!(Issue, ctx.task.id).notes =~ "From the node."

    # A live run has nothing to collect.
    assert {:ok, :read_only} = Executor.collect(handle, :checkout)

    File.write!(Path.join(ctx.stub, "go"), "")
    assert 0 = await_exit(handle)

    # The transcript is mirrored into the run's config dir, as a local run's is.
    transcript = Path.join(ctx.config_dir, "projects/-work-tree/s1.jsonl")
    assert wait_until(fn -> File.exists?(transcript) end)
    assert File.read!(transcript) =~ "summary"

    assert_nothing_came_back(ctx)

    # Completion is the ticket's own: closed with no PR, since there was no branch.
    {:ok, closed} = Ash.update(Ash.get!(Issue, ctx.task.id), %{}, action: :close)
    assert closed.state == :closed
    assert closed.pr_ref == nil
    assert closed.notes =~ "From the node."
  end

  test "a commit the agent makes in the node's checkout is discarded and never pushed", ctx do
    File.write!(Path.join(ctx.stub, "commit"), "")
    assert {:ok, prepared} = place(ctx, "c1")
    assert {:ok, handle} = Executor.open(prepared)
    assert 0 = await_exit(handle)

    # The agent really committed, in the shadow on the node...
    committed = File.read!(Path.join(ctx.stub, "committed.head")) |> String.trim()
    refute committed == ctx.tip

    # ...and the commit went nowhere: not into the clone, not into the main repo.
    assert_nothing_came_back(ctx)
    assert {_, code} = System.cmd("git", ["cat-file", "-e", committed], cd: ctx.clone)
    assert code != 0
    assert {_, code} = System.cmd("git", ["cat-file", "-e", committed], cd: ctx.repo)
    assert code != 0

    # And the clone cannot publish it either.
    assert {:error, :read_only_clone} = PrivateClone.sync_back(ctx.clone)
  end

  # ---- a tiny HTTP client over the bridge's unix socket ------------------------

  defp http(path, method, url, opts) do
    body = Jason.encode!(Keyword.fetch!(opts, :json))

    head =
      "host: 127.0.0.1\r\nconnection: close\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\n"

    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false])

    :ok = :gen_tcp.send(sock, "#{method} #{url} HTTP/1.1\r\n#{head}\r\n#{body}")
    raw = recv_all(sock, "")
    :gen_tcp.close(sock)
    parse(raw)
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, _} -> acc
    end
  end

  defp parse(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    "HTTP/1.1 " <> rest = head
    {status, _} = Integer.parse(rest)
    %{status: status, body: decode(body)}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          50 -> wait_until(fun, attempts - 1)
        end
    end
  end
end
