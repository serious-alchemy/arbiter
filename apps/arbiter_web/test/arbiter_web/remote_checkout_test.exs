defmodule ArbiterWeb.RemoteCheckoutTest do
  @moduledoc """
  RW11 (`docs/design/remote-workers.md` §9), end to end across the real halves: a run
  placed with a `checkout` block is seeded by the **real agent** over real HTTP
  (`GET /nodes/runs/:run/seed.bundle` through a Bandit listener), a stand-in
  `podman` edits the shadow, and the agent's snapshot bundle is `PUT` back through
  the primary's quarantine (`Arbiter.Nodes.Checkout`) into the home clone: at a
  checkpoint (`Executor.collect/2`) while the run is live, and at exit.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.NodeAgent.{Config, Connection, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"
  @branch "arbiter/e2e"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(System.tmp_dir!(), "rc-#{System.unique_integer([:positive])}")
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

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "co-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    File.write!(Path.join(stub, "edit"), "")
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
    assert_receive {:node_state, _id, :online}, 10_000

    repo = Path.join(root, "primary-home")
    base = home!(repo)

    %{
      node: node,
      stub: stub,
      repo: repo,
      base: base,
      node_home: home,
      config_dir: Path.join(root, "primary-config")
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

  defp home!(repo) do
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "lib/a.txt"), "a\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "-q", "-b", @branch])
    base
  end

  defp spec(run) do
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
      "secrets" => %{},
      "limits" => %{"memory" => "1g"},
      "command" => ["claude", "--print"],
      "checkout" => %{"branch" => @branch, "base" => "main"}
    }
  end

  defp place(ctx, run) do
    checkout = %{
      home: ctx.repo,
      branch: @branch,
      base: "main",
      seeded_paths: [],
      config_dir: ctx.config_dir
    }

    Executor.prepare(ctx.node.id, spec(run), owner: self(), checkout: checkout)
  end

  defp await_exit(handle) do
    receive do
      {^handle, {:exit_status, status}} -> status
      {^handle, _other} -> await_exit(handle)
    after
      15_000 -> flunk("no exit for #{inspect(handle)}")
    end
  end

  test "the agent seeds its shadow from the primary and the final snapshot lands in the home clone",
       ctx do
    assert {:ok, prepared} = place(ctx, "c1")
    assert {:ok, handle} = Executor.open(prepared)
    assert 0 = await_exit(handle)

    # the shadow was the primary's tree, then the run edited it; the snapshot came back
    assert File.read!(Path.join(ctx.repo, "edited.txt")) == "edited by the run\n"
    assert git!(ctx.repo, ["rev-parse", @branch]) == ctx.base
    assert git!(ctx.repo, ["status", "--porcelain"]) =~ "edited.txt"
    # the primary-side filter dropped the injected config the "container" left behind
    refute File.exists?(Path.join(ctx.repo, ".mcp.json"))
    assert git!(ctx.repo, ["rev-parse", "refs/arbiter/checkpoint/c1"]) != ""

    # the session JSONL came back through the sanitising extractor, to the run's config dir
    assert File.read!(Path.join(ctx.config_dir, "projects/-work-tree/s1.jsonl")) =~ "summary"
  end

  test "collect/2 takes a checkpoint of a live run and the home clone has it before the run ends",
       ctx do
    StubPodman.write_mode(ctx.stub, "slow")
    {:ok, prepared} = place(ctx, "c2")
    {:ok, handle} = Executor.open(prepared)
    assert_receive {^handle, {:data, {:eol, "line-1"}}}, 10_000

    refute File.exists?(Path.join(ctx.repo, "edited.txt"))
    assert {:ok, %{head: head, filtered: [".mcp.json"]}} = Executor.collect(handle, :checkout)
    assert head == ctx.base
    assert File.read!(Path.join(ctx.repo, "edited.txt")) == "edited by the run\n"
    assert Executor.live?(handle)

    File.write!(Path.join(ctx.stub, "go"), "")
    assert 0 = await_exit(handle)
  end

  test "a repo the primary vetoes (submodule) is never seeded: the run is refused", ctx do
    git!(ctx.repo, [
      "update-index",
      "--add",
      "--cacheinfo",
      "160000,#{String.duplicate("a", 40)},vendor/dep"
    ])

    git!(ctx.repo, ["commit", "-q", "-m", "submodule"])
    assert {:error, {:refused, _code, detail}} = place(ctx, "c3")
    assert detail =~ "submodule"
    assert Runs.run_ids() == []
  end
end
