defmodule Arbiter.NodeAgent.ImageGCTest do
  @moduledoc """
  SI6 (`docs/design/remote-workers.md` §21.4): the safety rules of image GC on a node.
  `plan/3` is pure and carries one test per keep rule; the server tests drive it with a
  stand-in podman that records every argv, so "`rmi` only, never `prune`" and "legacy
  images are listed, never removed" are asserted on what was actually run.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.{Config, ImageGC}

  @moduletag :tmp_dir
  @now 1_800_000_000
  @hour 3600
  @day 24 * @hour
  @gib 1024 * 1024 * 1024
  @repo "registry.example.com/arbiter/vstim/worker"

  defp ref(n), do: @repo <> "@sha256:" <> String.duplicate(Integer.to_string(n), 64)

  defp entry(n, age_s, opts \\ []) do
    ref = Keyword.get(opts, :ref, ref(n))
    t = @now - age_s

    {ref,
     %{
       "ref" => ref,
       "repo" => ImageGC.repo(ref),
       "pulled_at" => t,
       "last_used" => t,
       "runs" => Keyword.get(opts, :runs, []),
       "size" => 100,
       "seed" => Keyword.get(opts, :seed)
     }}
  end

  defp ctx(overrides \\ []) do
    Map.merge(%{now: @now, live_runs: [], retained_runs: [], gate_images: []}, Map.new(overrides))
  end

  describe "plan/3 keep rules" do
    test "a live or preparing run's image is kept, however old and however much pressure" do
      entries = Map.new([entry(1, 30 * @day, runs: ["r-live"]), entry(2, 31 * @day)])
      # three more newer ones so neither 1 nor 2 is among the newest
      entries = Map.merge(entries, Map.new([entry(3, 3 * @day), entry(4, 2 * @day)]))

      for pressure? <- [false, true] do
        plan = ImageGC.plan(entries, ctx(live_runs: ["r-live"]), pressure?: pressure?)
        assert plan.keep[ref(1)] == :live
        refute ref(1) in plan.remove
        assert ref(2) in plan.remove
      end
    end

    test "a retained run's image is kept" do
      entries =
        Map.new([entry(1, 30 * @day, runs: ["r-ret"]), entry(3, 3 * @day), entry(4, @day)])

      plan = ImageGC.plan(entries, ctx(retained_runs: ["r-ret"]), pressure?: true)
      assert plan.keep[ref(1)] == :retained
      refute ref(1) in plan.remove
    end

    test "an image an Exec gate context still names is kept" do
      entries = Map.new([entry(1, 30 * @day), entry(3, 3 * @day), entry(4, @day)])

      plan = ImageGC.plan(entries, ctx(gate_images: [ref(1)]), pressure?: true)
      assert plan.keep[ref(1)] == :gate
      refute ref(1) in plan.remove
    end

    test "an image pulled or used in the last 24 h is kept; one older is not" do
      entries =
        Map.new([
          entry(1, 23 * @hour),
          entry(2, 25 * @hour),
          entry(3, 26 * @hour),
          entry(4, 27 * @hour)
        ])

      plan = ImageGC.plan(entries, ctx())
      assert plan.keep[ref(1)] == :recent
      # 1 (recent) and 2 are the newest two by last use; 3 and 4 go
      assert plan.remove == [ref(3), ref(4)]
    end

    test "the newest two per repository by last use are kept" do
      entries = Map.new([entry(1, 5 * @day), entry(2, 4 * @day), entry(3, 3 * @day)])

      plan = ImageGC.plan(entries, ctx())
      assert plan.remove == [ref(1)]
      assert plan.keep[ref(2)] == :newest
      assert plan.keep[ref(3)] == :newest
    end

    test "the newest two are counted per repository, not across the ledger" do
      other = "registry.example.com/arbiter/other/worker@sha256:" <> String.duplicate("9", 64)
      entries = Map.new([entry(1, 5 * @day), entry(2, 4 * @day), entry(0, 6 * @day, ref: other)])

      assert ImageGC.plan(entries, ctx()).remove == []
    end

    test "under pressure the grace is dropped and only the newest per repository survives" do
      entries = Map.new([entry(1, 5 * @day), entry(2, 2 * @hour), entry(3, @hour)])

      plan = ImageGC.plan(entries, ctx(), pressure?: true)
      assert plan.remove == [ref(1), ref(2)]
      assert plan.keep == %{ref(3) => :newest}
    end

    test "a legacy image in the ledger is never planned for removal" do
      legacy = "localhost/arbiter-dev/abc123:latest"

      entries =
        Map.new([entry(1, 90 * @day, ref: legacy), entry(2, 5 * @day), entry(3, 4 * @day)])

      plan = ImageGC.plan(entries, ctx(), pressure?: true)
      assert plan.keep[legacy] == :legacy
      refute legacy in plan.remove
    end
  end

  test "pressure?/2 is free below 15 % or below 20 GiB" do
    gib = @gib
    assert ImageGC.pressure?(1000 * gib, 100 * gib)
    assert ImageGC.pressure?(100 * gib, 19 * gib)
    refute ImageGC.pressure?(100 * gib, 50 * gib)
    refute ImageGC.pressure?(0, 0)
  end

  test "repo/1 strips the digest and a tag" do
    assert ImageGC.repo(ref(1)) == @repo
    assert ImageGC.repo("localhost:5000/a/b:1.2") == "localhost:5000/a/b"
    assert ImageGC.repo("a/b") == "a/b"
  end

  describe "the server" do
    setup %{tmp_dir: tmp} do
      test = self()
      home = Path.join(tmp, "node")
      File.mkdir_p!(home)
      store = start_supervised!({Agent, fn -> %{"rmi_fail" => []} end})

      runner = fn _cmd, args, _opts ->
        send(test, {:podman, args})

        case args do
          ["rmi", ref] ->
            if ref in Agent.get(store, & &1["rmi_fail"]),
              do: {"Error: image used by container abc", 2},
              else: {"Untagged: #{ref}", 0}

          ["image", "inspect" | _] ->
            {"4096\n", 0}

          ["image", "ls" | _] ->
            {"localhost/arbiter-dev/aaa:latest\nlocalhost/arbiter-dev/bbb:latest\n", 0}

          _ ->
            {"", 0}
        end
      end

      {:ok, home: home, store: store, runner: runner, tmp: tmp}
    end

    defp start_gc(ctx, extra \\ []) do
      name = :"gc_#{System.unique_integer([:positive])}"
      clock = start_supervised!({Agent, fn -> @now end}, id: {:clock, name})

      opts =
        [
          name: name,
          config: %Config{node_home: ctx.home, node_id: "n"},
          runner: ctx.runner,
          interval_ms: :infinity,
          collect_on_pull: false,
          now_fun: fn -> Agent.get(clock, & &1) end,
          runs_fun: fn -> [] end,
          retained_fun: fn -> [] end,
          gate_fun: fn -> [] end,
          space_fun: fn -> {1000 * @gib, 900 * @gib} end
        ]
        |> Keyword.merge(extra)

      start_supervised!({ImageGC, opts}, id: name)
      {name, clock}
    end

    defp rmis do
      Stream.repeatedly(fn ->
        receive do
          {:podman, ["rmi", ref]} -> ref
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))
    end

    test "ledger: only an image the agent pulled is ever removed", ctx do
      {name, clock} = start_gc(ctx)
      opts = [name: name]

      # five pulled digests of one repository, each last used long ago
      for n <- 1..5 do
        Agent.update(clock, fn _ -> @now - (40 - n) * @day end)
        :ok = ImageGC.pulled(ref(n), "run-#{n}", opts)
      end

      Agent.update(clock, fn _ -> @now end)
      # a digest the owner pulled: claimed by a run, but never "pulled" by the agent
      owner = "registry.example.com/arbiter/vstim/worker@sha256:" <> String.duplicate("f", 64)
      :ok = ImageGC.claim(owner, "run-x", opts)

      assert {:ok, result} = ImageGC.collect(opts)
      assert Enum.sort(result.removed) == [ref(1), ref(2), ref(3)]
      assert Enum.sort(rmis()) == [ref(1), ref(2), ref(3)]
      refute owner in rmis()
      assert ImageGC.stats(opts)["count"] == 2
    end

    test "podman is only ever asked for rmi, image inspect, image ls, info — never prune", ctx do
      {name, clock} = start_gc(ctx, space_fun: fn -> {100, 5} end)
      opts = [name: name]
      pull_all(clock, opts, 1..3)
      Agent.update(clock, fn _ -> @now + 3 * @day end)
      assert {:ok, %{pressure: true}} = ImageGC.collect(opts)

      argvs = drain_argvs([])
      assert Enum.any?(argvs, &match?(["rmi", _], &1))
      refute Enum.any?(argvs, fn argv -> "prune" in argv or "-f" in argv or "--force" in argv end)
      assert Enum.all?(argvs, fn [verb | _] -> verb in ["rmi", "image", "info"] end)
    end

    test "a refused rmi leaves the image in the ledger, with no force", ctx do
      {name, clock} = start_gc(ctx)
      opts = [name: name]
      pull_all(clock, opts, 1..3)
      Agent.update(ctx.store, &Map.put(&1, "rmi_fail", [ref(1)]))
      Agent.update(clock, fn _ -> @now + 3 * @day end)

      assert {:ok, %{removed: []}} = ImageGC.collect(opts)
      assert ImageGC.stats(opts)["count"] == 3
      assert ["rmi", ref(1)] in drain_argvs([])
    end

    test "legacy images are listed in the stats and never removed", ctx do
      {name, clock} = start_gc(ctx, space_fun: fn -> {100, 5} end)
      opts = [name: name]
      pull_all(clock, opts, 1..3)
      Agent.update(clock, fn _ -> @now + 3 * @day end)
      assert {:ok, _} = ImageGC.collect(opts)

      assert ImageGC.stats(opts)["legacy"] == [
               "localhost/arbiter-dev/aaa:latest",
               "localhost/arbiter-dev/bbb:latest"
             ]

      refute Enum.any?(drain_argvs([]), fn
               ["rmi", "localhost/arbiter-dev/" <> _] -> true
               _ -> false
             end)
    end

    test "a live run keeps its image through the server", ctx do
      {name, clock} = start_gc(ctx, runs_fun: fn -> ["r1"] end)
      opts = [name: name]
      pull_all(clock, opts, 1..4)
      Agent.update(clock, fn _ -> @now + 30 * @day end)

      assert {:ok, result} = ImageGC.collect(opts)
      assert ref(1) in Map.keys(result.kept)
      refute ref(1) in result.removed
    end

    test "pressure that survives GC is reported", ctx do
      {name, _clock} = start_gc(ctx, space_fun: fn -> {100, 5} end)
      opts = [name: name]
      :ok = ImageGC.pulled(ref(1), "r1", opts)
      assert {:ok, %{pressure: true, pressure_unrelieved: true}} = ImageGC.collect(opts)
      assert ImageGC.stats(opts)["pressure_unrelieved"] == true
    end

    test "a removed image takes its seed layer, unless a kept image shares it", ctx do
      root = Path.join(ctx.home, "deps-cache")
      layer = "layer-" <> String.duplicate("a", 12) <> "-" <> String.duplicate("b", 12)
      shared = "layer-" <> String.duplicate("c", 12) <> "-" <> String.duplicate("d", 12)
      for dir <- [layer, shared], do: File.mkdir_p!(Path.join([root, dir, "deps"]))

      {name, clock} = start_gc(ctx)
      opts = [name: name]
      pull_all(clock, opts, 1..4)
      :ok = ImageGC.seed(ref(1), layer, opts)
      :ok = ImageGC.seed(ref(2), shared, opts)
      :ok = ImageGC.seed(ref(4), shared, opts)
      Agent.update(clock, fn _ -> @now + 30 * @day end)

      assert {:ok, result} = ImageGC.collect(opts)
      assert ref(1) in result.removed
      assert ref(2) in result.removed
      refute File.exists?(Path.join(root, layer))
      # ref(4) is kept and uses the shared layer
      assert File.dir?(Path.join(root, shared))
      assert result.seeds_removed == [layer]
    end

    test "the ledger survives a restart", ctx do
      {name, _} = start_gc(ctx)
      :ok = ImageGC.pulled(ref(1), "r1", name: name)
      assert File.regular?(Path.join(ctx.home, "images.json"))
      stop_supervised!(name)

      {name2, _} = start_gc(ctx)
      assert ImageGC.stats(name: name2)["count"] == 1
    end
  end

  test "the agent never invokes a podman prune" do
    sources = Path.wildcard(Path.expand("../../../lib/arbiter/node_agent/**/*.ex", __DIR__))
    assert sources != []

    for file <- sources do
      body = File.read!(file)
      # The moduledoc and comments may name it; no code may pass it to podman.
      code =
        body
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*(#|\*|@moduledoc|@doc)/))
        |> Enum.join("\n")

      refute code =~ ~r/"(image |system |container |volume )?prune"/,
             "#{Path.relative_to_cwd(file)} passes prune to podman"
    end
  end

  defp drain_argvs(acc) do
    receive do
      {:podman, argv} -> drain_argvs([argv | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Each digest is pulled one second after the last, so "newest" is never a tie.
  defp pull_all(clock, opts, range) do
    for n <- range do
      Agent.update(clock, fn _ -> @now + n end)
      :ok = ImageGC.pulled(ref(n), "r#{n}", opts)
    end
  end
end
