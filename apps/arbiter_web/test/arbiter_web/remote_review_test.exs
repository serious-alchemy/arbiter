defmodule ArbiterWeb.RemoteReviewTest do
  @moduledoc """
  bd-cgdhlu, end to end across the real halves: a **reviewer** run placed with a
  read-only `checkout` block (a ReviewGate reviewer, or a `review: true` dispatch)
  is seeded by the **real agent** over real HTTP at the exact head under review
  (`GET /nodes/runs/:run/seed.bundle` through a Bandit listener), a stand-in
  `podman` plays a reviewer that scribbles in the shadow and writes a session
  transcript, and at exit only the **transcripts** come back: no snapshot bundle is
  uploaded, so the home clone (the reviewer's private clone) is untouched and no
  checkpoint ref appears. The ReviewGate half is `ReviewGateRemotePlacementTest`.
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
      "checkout" => %{"branch" => @branch, "base" => "main", "read_only" => true}
    }
  end

  defp place(ctx, run) do
    checkout = %{
      home: ctx.repo,
      branch: @branch,
      base: "main",
      seeded_paths: [],
      config_dir: ctx.config_dir,
      read_only?: true
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

  test "a reviewer is seeded at the exact head, and only its transcript comes back", ctx do
    assert {:ok, prepared} = place(ctx, "r1")
    assert {:ok, handle} = Executor.open(prepared)
    assert 0 = await_exit(handle)

    # The shadow the reviewer ran in was seeded at the head under review.
    assert File.read!(Path.join(ctx.stub, "seeded.head")) |> String.trim() == ctx.base
    assert git!(ctx.repo, ["rev-parse", @branch]) == ctx.base

    # Nothing it did in the shadow came back: no edit, no checkpoint ref, a clean
    # home clone.
    refute File.exists?(Path.join(ctx.repo, "edited.txt"))
    assert git!(ctx.repo, ["status", "--porcelain"]) == ""
    assert git!(ctx.repo, ["for-each-ref", "refs/arbiter/checkpoint"]) == ""

    # The session transcript is mirrored into the run's config dir, as a local
    # reviewer's would be.
    transcript = Path.join(ctx.config_dir, "projects/-work-tree/s1.jsonl")
    assert wait_until(fn -> File.exists?(transcript) end)
    assert File.read!(transcript) =~ "summary"
  end

  test "a live reviewer has nothing to collect", ctx do
    StubPodman.write_mode(ctx.stub, "slow")
    {:ok, prepared} = place(ctx, "r2")
    {:ok, handle} = Executor.open(prepared)
    assert_receive {^handle, {:data, {:eol, "line-1"}}}, 10_000

    assert {:ok, :read_only} = Executor.collect(handle, :checkout)
    refute File.exists?(Path.join(ctx.repo, "edited.txt"))
    assert git!(ctx.repo, ["for-each-ref", "refs/arbiter/checkpoint"]) == ""

    File.write!(Path.join(ctx.stub, "go"), "")
    assert 0 = await_exit(handle)
    refute File.exists?(Path.join(ctx.repo, "edited.txt"))
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
