defmodule Arbiter.Worker.Image.LocalPublishedTest do
  @moduledoc """
  SI-L (bd-4cq0qt, OD11): a local run takes the SAME published per-repo image as
  every node, served from the local podman store. podman is a stand-in runner
  that records each call and, for `pull`, what the auth file held at that moment.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.ImageGC
  alias Arbiter.Worker.Image.LocalPublished
  alias Arbiter.Worker.Image.LocalRuns
  alias Arbiter.Worker.Image.PublishLedger

  @moduletag :tmp_dir

  @digest String.duplicate("a", 64)
  @ref "registry.example.com/arbiter/vstim/worker@sha256:" <> @digest
  @labels %{
    "arbiter.runtime-contract" => "1",
    "arbiter.cli-set" => "0a1b2c3d",
    "arbiter.cli-providers" => "claude,codex",
    "arbiter.cli.claude.version" => "2.1.310",
    "arbiter.cli.claude.sha256" => String.duplicate("c", 64)
  }
  @registry %{
    registry: "registry.example.com/arbiter",
    username: "ci",
    password: "push-s3cr3t"
  }

  defp runner(test, cfg) do
    fn "podman", args, _opts ->
      send(test, {:podman, args})

      case args do
        ["image", "exists", _ref] ->
          if Map.get(cfg, :present?, false), do: {"", 0}, else: {"", 1}

        ["pull" | rest] ->
          send(test, {:authfile, authfile_seen(rest)})
          Map.get(cfg, :pull, {"Copying blob sha256:1\n", 0})

        ["image", "inspect", "--format", _, _ref] ->
          {"123456\n", 0}

        ["image", "inspect", _ref] ->
          {Jason.encode!([%{"Labels" => Map.get(cfg, :labels, @labels)}]), 0}
      end
    end
  end

  defp authfile_seen(args) do
    case Enum.drop_while(args, &(&1 != "--authfile")) do
      ["--authfile", path | _] -> %{path: path, body: File.read!(path)}
      _ -> nil
    end
  end

  defp opts(ctx, cfg \\ %{}) do
    rt = Path.join(ctx.tmp_dir, "rt")
    File.mkdir_p!(rt)
    mountinfo = Path.join(ctx.tmp_dir, "mountinfo")
    File.write!(mountinfo, "36 35 98:0 / #{rt} rw,noatime - tmpfs none rw\n")

    [
      repo: "vstim",
      run: "arb-local-1",
      provider: "claude",
      expect_cli_set: "0a1b2c3d",
      podman: "podman",
      runner: runner(self(), cfg),
      runtime_dir: rt,
      mountinfo: mountinfo,
      ledger: Path.join(ctx.tmp_dir, "ledger.term"),
      registry_opts: [config: @registry],
      gc: [name: :no_such_local_gc]
    ]
  end

  defp publish!(opts, ref \\ @ref) do
    PublishLedger.record(%{repo: "vstim", repo_path: "/r"},
      ledger: opts[:ledger],
      ref: ref
    )
  end

  describe "resolve/1" do
    test "a cached digest is used with no pull and no network", ctx do
      opts = opts(ctx, %{present?: true})
      publish!(opts)

      assert {:published, %{ref: @ref}} = LocalPublished.resolve(opts)

      assert_received {:podman, ["image", "exists", @ref]}
      refute_received {:podman, ["pull" | _]}
    end

    test "a cold cache pulls the digest through a tmpfs auth file removed afterwards", ctx do
      opts = opts(ctx)
      publish!(opts)

      assert {:published, %{ref: @ref}} = LocalPublished.resolve(opts)

      assert_received {:podman, ["pull", "--quiet", "--authfile", path, @ref]}
      assert_received {:authfile, %{path: ^path, body: body}}
      assert String.starts_with?(path, opts[:runtime_dir])
      assert Jason.decode!(body)["auths"]["registry.example.com"]
      refute File.exists?(path)
    end

    test "an unreachable registry with a cold cache falls back and says why", ctx do
      opts = opts(ctx, %{pull: {"dial tcp: no such host", 125}})
      publish!(opts)

      assert {:fallback, reason} = LocalPublished.resolve(opts)
      assert reason =~ "pull_failed"
    end

    test "an image whose labels do not match the local CLI set falls back", ctx do
      opts = opts(ctx, %{present?: true, labels: Map.put(@labels, "arbiter.cli-set", "ffffffff")})
      publish!(opts)

      assert {:fallback, reason} = LocalPublished.resolve(opts)
      assert reason =~ "contract_mismatch"
    end

    test "no registry configured is just the local build, not a fallback", ctx do
      opts = Keyword.put(opts(ctx), :registry_opts, config: %{})
      assert {:build, nil} = LocalPublished.resolve(opts)
      refute_received {:podman, _}
    end

    test "a registry with nothing published yet falls back to the local build", ctx do
      assert {:fallback, reason} = LocalPublished.resolve(opts(ctx))
      assert reason =~ "never_published"
    end

    test "switched off, it is the local build", ctx do
      opts = Keyword.put(opts(ctx), :published_image, false)
      publish!(opts)
      assert {:build, nil} = LocalPublished.resolve(opts)
    end
  end

  describe "prefetch/3" do
    test "warms the local store with the freshly published digest", ctx do
      opts = opts(ctx)

      assert :ok = LocalPublished.prefetch(%{repo: "vstim"}, %{ref: @ref}, opts)

      assert_received {:podman, ["image", "exists", @ref]}
      assert_received {:podman, ["pull", "--quiet", "--authfile", _, @ref]}

      # and a run that follows finds it cached
      publish!(opts)

      assert {:published, %{ref: @ref}} =
               LocalPublished.resolve(
                 Keyword.put(opts, :runner, runner(self(), %{present?: true}))
               )
    end
  end

  describe "the local store's GC" do
    test "never removes an image a live local run uses", ctx do
      name = :"local_gc_#{System.unique_integer([:positive])}"
      runs = :"local_runs_#{System.unique_integer([:positive])}"
      repo = "registry.example.com/arbiter/vstim/worker@sha256:"
      [live_ref, mid_ref, new_ref] = for c <- ~w(1 2 3), do: repo <> String.duplicate(c, 64)
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 1_000_000)
      test = self()

      runner = fn "podman", args, _ ->
        send(test, {:podman, args})

        case args do
          ["image", "inspect" | _] -> {"10\n", 0}
          ["rmi", _] -> {"", 0}
          _ -> {"", 1}
        end
      end

      start_supervised!({LocalRuns, name: runs})

      start_supervised!(
        LocalPublished.gc_spec(
          name: name,
          runs: runs,
          node_home: ctx.tmp_dir,
          runner: runner,
          podman: "podman",
          interval_ms: :infinity,
          collect_on_pull: false,
          grace_s: 0,
          now_fun: fn -> :counters.get(clock, 1) end,
          space_fun: fn -> {1_000_000_000_000, 900_000_000_000} end
        )
      )

      owner = spawn(fn -> Process.sleep(:infinity) end)
      :ok = LocalRuns.track("arb-live", owner, name: runs)

      # the live run's image is the OLDEST: outside the newest two, only the live run saves it
      for {ref, run} <- [{live_ref, "arb-live"}, {mid_ref, "arb-x"}, {new_ref, "arb-y"}] do
        :counters.add(clock, 1, 10)
        :ok = ImageGC.pulled(ref, run, name: name)
      end

      :counters.add(clock, 1, 10)
      assert {:ok, %{removed: [], kept: kept}} = ImageGC.collect(name: name)
      assert kept[live_ref] == :live
      refute_received {:podman, ["rmi", ^live_ref]}

      # once the run's owner is gone the image is an ordinary one and goes
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}
      _ = :sys.get_state(runs)

      assert {:ok, %{removed: [^live_ref]}} = ImageGC.collect(name: name)
      assert_received {:podman, ["rmi", ^live_ref]}
    end
  end
end
