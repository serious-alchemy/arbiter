defmodule Arbiter.Worker.DepsCacheTest do
  @moduledoc """
  bd-1wm14e (P6): the image-keyed deps cache for container workers.

  The seed job is a stand-in `podman` runner that plays the container: it writes
  a `deps/` and a compiled `_build/` into the directory it was told to work in
  (`-w`). The real-podman half is `deps_cache_podman_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.DepsCache

  @image_a "localhost/arbiter-dev/beam-1.19.4-28.2:aaaaaaaaaaaa"
  @image_b "localhost/arbiter-dev/beam-1.17.3-27.1.2:bbbbbbbbbbbb"

  setup do
    ctx =
      GitFixture.forge_and_checkout(
        %{"mix.exs" => "# app\n", "mix.lock" => "%{\"jason\" => 1}\n"},
        parent: tmp_parent()
      )

    root = Path.join(ctx.root, "cache")
    scratch = Path.join(ctx.root, "scratch")
    File.mkdir_p!(scratch)
    test = self()

    # Plays the container. Every `podman` call is reported; a `run` leaves
    # behind what `mix deps.get && mix deps.compile` would, stamped with the
    # image so a test can tell which seed a worker was handed.
    runner = fn _podman, args, _opts ->
      send(test, {:podman, args})

      case args do
        ["run" | _] ->
          work = args |> Enum.drop_while(&(&1 != "-w")) |> Enum.at(1)
          image = args |> Enum.drop_while(&(&1 != "--")) |> Enum.at(1)
          File.mkdir_p!(Path.join(work, "deps/jason"))
          File.write!(Path.join(work, "deps/jason/mix.exs"), "# jason\n")
          File.mkdir_p!(Path.join(work, "_build/test/lib/jason/ebin"))
          File.write!(Path.join(work, "_build/test/lib/jason/ebin/jason.beam"), image)
          File.mkdir_p!(Path.join(work, "_build/dev/lib/jason/ebin"))
          File.write!(Path.join(work, "_build/dev/lib/jason/ebin/jason.beam"), image)
          {"", 0}

        _ ->
          {"", 0}
      end
    end

    opts = [root: root, scratch: scratch, runner: runner, podman: "/usr/bin/podman"]
    Map.merge(ctx, %{root_dir: root, opts: opts, runner: runner, scratch: scratch})
  end

  # The fixture helper wants a parent that exists; keep it out of the worktree.
  defp tmp_parent do
    dir = Path.join(System.tmp_dir!(), "depscache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp runs do
    receive do
      {:podman, ["run" | _] = args} -> [args | runs()]
      {:podman, _} -> runs()
    after
      0 -> []
    end
  end

  describe "key/4" do
    test "includes the image tag: a toolchain change misses the cache", ctx do
      assert {:ok, a} = DepsCache.key(ctx.checkout, "main", @image_a, ctx.opts)
      assert {:ok, a_again} = DepsCache.key(ctx.checkout, "main", @image_a, ctx.opts)
      assert {:ok, b} = DepsCache.key(ctx.checkout, "main", @image_b, ctx.opts)

      assert a.dir == a_again.dir
      assert a.lock_hash == b.lock_hash
      assert a.dir != b.dir
      assert b.image_tag == @image_b
    end

    test "includes the lockfile hash: a lock bump misses the cache", ctx do
      assert {:ok, before} = DepsCache.key(ctx.checkout, "main", @image_a, ctx.opts)

      GitFixture.commit!(ctx.seed, %{"mix.lock" => "%{\"jason\" => 2}\n"}, "bump")
      GitFixture.git!(ctx.seed, ["push", "-q", "origin", "main"])
      GitFixture.git!(ctx.checkout, ["fetch", "-q", "origin"])

      assert {:ok, bumped} = DepsCache.key(ctx.checkout, "main", @image_a, ctx.opts)
      assert bumped.dir != before.dir
      assert bumped.lock_hash != before.lock_hash
    end

    test "reads the lockfile from the default branch, not the working tree", ctx do
      assert {:ok, before} = DepsCache.key(ctx.checkout, "main", @image_a, ctx.opts)
      File.write!(Path.join(ctx.checkout, "mix.lock"), "%{\"evil\" => 1}\n")
      assert {:ok, after_edit} = DepsCache.key(ctx.checkout, "main", @image_a, ctx.opts)
      assert after_edit.dir == before.dir
    end

    test "a repo with no lockfile has no cache", ctx do
      other = GitFixture.forge_and_checkout(%{"README.md" => "x\n"}, parent: tmp_parent())

      assert {:error, :no_lockfile} = DepsCache.key(other.checkout, "main", @image_a, ctx.opts)
    end

    test "refuses an image tag that could not be a tag", ctx do
      assert {:error, {:bad_image, "--rm"}} =
               DepsCache.key(ctx.checkout, "main", "--rm", ctx.opts)
    end
  end

  describe "ensure/4" do
    test "a miss runs one seed job inside the image; a hit runs none", ctx do
      assert {:ok, %{seeded?: true, dir: dir}} =
               DepsCache.ensure(ctx.checkout, "main", @image_a, ctx.opts)

      assert File.read!(Path.join(dir, "_build/test/lib/jason/ebin/jason.beam")) == @image_a
      assert File.exists?(Path.join(dir, "deps/jason/mix.exs"))

      assert [argv] = runs()
      assert @image_a in argv
      assert "--network=pasta" in argv
      script = List.last(argv)
      assert script =~ "mix deps.get"
      assert script =~ "deps.compile"

      assert {:ok, %{seeded?: false, dir: ^dir}} =
               DepsCache.ensure(ctx.checkout, "main", @image_a, ctx.opts)

      assert runs() == []
    end

    test "the seed job sees only its scratch export, never the cache or the repo", ctx do
      assert {:ok, %{dir: dir}} = DepsCache.ensure(ctx.checkout, "main", @image_a, ctx.opts)

      [argv] = runs()
      mounts = for ["-v", spec] <- Enum.chunk_every(argv, 2, 1, :discard), do: spec

      refute Enum.any?(mounts, &String.contains?(&1, dir))
      refute Enum.any?(mounts, &String.contains?(&1, ctx.checkout))
      refute Enum.any?(mounts, &String.contains?(&1, ctx.root_dir))
    end

    test "a toolchain change seeds a second, separate cache", ctx do
      assert {:ok, %{dir: a}} = DepsCache.ensure(ctx.checkout, "main", @image_a, ctx.opts)

      assert {:ok, %{seeded?: true, dir: b}} =
               DepsCache.ensure(ctx.checkout, "main", @image_b, ctx.opts)

      assert a != b
      assert File.read!(Path.join(b, "_build/test/lib/jason/ebin/jason.beam")) == @image_b
      # The first image's cache is untouched.
      assert File.read!(Path.join(a, "_build/test/lib/jason/ebin/jason.beam")) == @image_a
      assert length(runs()) == 2
    end

    test "a failed seed leaves no cache and the next call retries", ctx do
      failing = fn _podman, args, _ ->
        if match?(["run" | _], args), do: {"hex: boom", 1}, else: {"", 0}
      end

      assert {:error, {:seed_failed, 1, output}} =
               DepsCache.ensure(
                 ctx.checkout,
                 "main",
                 @image_a,
                 Keyword.put(ctx.opts, :runner, failing)
               )

      assert output =~ "boom"
      assert {:ok, key} = DepsCache.key(ctx.checkout, "main", @image_a, ctx.opts)
      refute File.exists?(key.dir)

      assert {:ok, %{seeded?: true}} = DepsCache.ensure(ctx.checkout, "main", @image_a, ctx.opts)
    end

    test "concurrent callers share one seed job", ctx do
      results =
        1..4
        |> Task.async_stream(
          fn _ -> DepsCache.ensure(ctx.checkout, "main", @image_a, ctx.opts) end,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert length(runs()) == 1
      assert Enum.count(results, &match?({:ok, %{seeded?: true}}, &1)) == 1
    end
  end

  describe "install/3" do
    setup ctx do
      {:ok, %{dir: cache}} = DepsCache.ensure(ctx.checkout, "main", @image_a, ctx.opts)
      worker = Path.join(ctx.root, "worker")
      File.mkdir_p!(Path.join(worker, ".git"))
      Map.merge(ctx, %{cache: cache, worker: worker})
    end

    test "gives the worker its own copy, never the cache itself", ctx do
      assert {:ok, %{method: method}} = DepsCache.install(ctx.cache, ctx.worker, ctx.opts)
      assert method in [:reflink, :copy]

      beam = Path.join(ctx.worker, "_build/test/lib/jason/ebin/jason.beam")
      assert File.read!(beam) == @image_a

      # A worker writing into its copy (a poisoned _build) cannot reach the cache.
      File.write!(beam, "poisoned")
      File.write!(Path.join(ctx.worker, "deps/jason/mix.exs"), "# poisoned\n")

      assert File.read!(Path.join(ctx.cache, "_build/test/lib/jason/ebin/jason.beam")) == @image_a
      assert File.read!(Path.join(ctx.cache, "deps/jason/mix.exs")) == "# jason\n"

      refute File.lstat!(Path.join(ctx.worker, "deps")).type == :symlink
      refute File.lstat!(Path.join(ctx.worker, "_build")).type == :symlink
    end

    test "falls back to a plain copy when the filesystem cannot reflink", ctx do
      # `--reflink=always` fails on a filesystem without clone support; the
      # stand-in forces that, whatever this host's /tmp is.
      cp = fn args ->
        if "--reflink=always" in args,
          do: {"cp: failed to clone: Operation not supported", 1},
          else: nil
      end

      assert {:ok, %{method: :copy}} =
               DepsCache.install(ctx.cache, ctx.worker, Keyword.put(ctx.opts, :cp_hook, cp))

      assert File.read!(Path.join(ctx.worker, "_build/dev/lib/jason/ebin/jason.beam")) == @image_a
    end

    test "replaces what the host seeded before the container backend took over", ctx do
      stale = Path.join(ctx.worker, "_build/test/lib/jason/ebin")
      File.mkdir_p!(stale)
      File.write!(Path.join(stale, "jason.beam"), "host-built")

      assert {:ok, %{method: m}} = DepsCache.install(ctx.cache, ctx.worker, ctx.opts)
      assert m in [:reflink, :copy]

      assert File.read!(Path.join(ctx.worker, "_build/test/lib/jason/ebin/jason.beam")) ==
               @image_a
    end

    test "a second install of the same cache is a no-op that keeps the worker's changes", ctx do
      assert {:ok, %{method: m}} = DepsCache.install(ctx.cache, ctx.worker, ctx.opts)
      assert m in [:reflink, :copy]

      File.write!(Path.join(ctx.worker, "_build/test/lib/jason/ebin/jason.beam"), "worker-built")

      assert {:ok, %{method: :unchanged}} = DepsCache.install(ctx.cache, ctx.worker, ctx.opts)

      assert File.read!(Path.join(ctx.worker, "_build/test/lib/jason/ebin/jason.beam")) ==
               "worker-built"
    end

    test "a different cache (new image) replaces the worker's artifacts", ctx do
      assert {:ok, _} = DepsCache.install(ctx.cache, ctx.worker, ctx.opts)
      {:ok, %{dir: other}} = DepsCache.ensure(ctx.checkout, "main", @image_b, ctx.opts)

      assert {:ok, %{method: m}} = DepsCache.install(other, ctx.worker, ctx.opts)
      assert m in [:reflink, :copy]

      assert File.read!(Path.join(ctx.worker, "_build/test/lib/jason/ebin/jason.beam")) ==
               @image_b
    end

    test "refuses a cache that is not complete", ctx do
      half = Path.join(ctx.root, "half-built")
      File.mkdir_p!(Path.join(half, "deps"))

      assert {:error, {:cache_incomplete, ^half}} = DepsCache.install(half, ctx.worker, ctx.opts)
      refute File.exists?(Path.join(ctx.worker, "deps"))
    end
  end
end
