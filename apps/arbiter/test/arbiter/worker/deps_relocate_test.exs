defmodule Arbiter.Worker.DepsRelocateTest do
  @moduledoc """
  bd-9xcogk: a `deps/` + `_build` copied to a worktree must not point back at the
  directory it was built in. Its `priv` links name the NIF `lazy_html` built; its
  manifests name the project directory Mix compares.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.DepsRelocate
  alias Arbiter.Worker.Worktree

  @moduletag :tmp_dir

  @nif "lazy_html.so"

  # A source checkout the way `mix deps.compile` leaves it: the NIF in
  # `deps/lazy_html/priv`, reached from `_build` by an absolute symlink.
  defp compiled_source(root, env \\ "test") do
    File.mkdir_p!(Path.join(root, "deps/lazy_html/priv"))
    File.write!(Path.join(root, "deps/lazy_html/priv/#{@nif}"), "nif\n")
    File.mkdir_p!(Path.join(root, "deps/lazy_html/include"))
    lib = Path.join(root, "_build/#{env}/lib/lazy_html")
    File.mkdir_p!(Path.join(lib, "ebin"))
    File.mkdir_p!(Path.join(lib, ".mix"))
    File.ln_s!(Path.join(root, "deps/lazy_html/priv"), Path.join(lib, "priv"))
    File.ln_s!(Path.join(root, "deps/lazy_html/include"), Path.join(lib, "include"))

    File.write!(
      Path.join(lib, ".mix/compile.elixir"),
      :erlang.term_to_binary({:manifest, Path.join(root, "deps/lazy_html"), [:other]})
    )

    root
  end

  defp nif(worktree, env \\ "test"),
    do: Path.join(worktree, "_build/#{env}/lib/lazy_html/priv/#{@nif}")

  defp manifest(worktree, env \\ "test") do
    worktree
    |> Path.join("_build/#{env}/lib/lazy_html/.mix/compile.elixir")
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  describe "relink/1" do
    test "a priv link into a directory that is gone is re-pointed at the worktree's deps",
         %{tmp_dir: tmp} do
      source = compiled_source(Path.join(tmp, "source"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)
      File.cp_r!(Path.join(source, "deps"), Path.join(worktree, "deps"))

      {_, 0} =
        System.cmd("cp", ["-a", Path.join(source, "_build"), Path.join(worktree, "_build")])

      File.rm_rf!(source)

      refute File.exists?(nif(worktree))
      assert :ok = DepsRelocate.relink(worktree)

      assert File.exists?(nif(worktree))
      link = Path.join(worktree, "_build/test/lib/lazy_html/priv")
      assert {:ok, "../../../../deps/lazy_html/priv"} = File.read_link(link)

      assert {:ok, "../../../../deps/lazy_html/include"} =
               File.read_link(Path.join(worktree, "_build/test/lib/lazy_html/include"))
    end

    test "a link that points into a live source is moved off it too (no write-through)",
         %{tmp_dir: tmp} do
      source = compiled_source(Path.join(tmp, "source"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)
      File.cp_r!(Path.join(source, "deps"), Path.join(worktree, "deps"))

      {_, 0} =
        System.cmd("cp", ["-a", Path.join(source, "_build"), Path.join(worktree, "_build")])

      DepsRelocate.relink(worktree)

      assert {:ok, "../../../../deps/lazy_html/priv"} =
               File.read_link(Path.join(worktree, "_build/test/lib/lazy_html/priv"))
    end

    test "is idempotent, and leaves a link alone when the worktree has no such deps dir",
         %{tmp_dir: tmp} do
      worktree = Path.join(tmp, "wt")
      compiled_source(worktree)
      DepsRelocate.relink(worktree)
      DepsRelocate.relink(worktree)
      assert File.exists?(nif(worktree))

      bare = Path.join(tmp, "bare")
      File.mkdir_p!(Path.join(bare, "_build/test/lib/x"))
      File.ln_s!("/nowhere/deps/x/priv", Path.join(bare, "_build/test/lib/x/priv"))
      assert :ok = DepsRelocate.relink(bare)

      assert {:ok, "/nowhere/deps/x/priv"} =
               File.read_link(Path.join(bare, "_build/test/lib/x/priv"))
    end

    test "a worktree with no _build is fine", %{tmp_dir: tmp} do
      assert :ok = DepsRelocate.relink(tmp)
    end
  end

  describe "retarget_manifests/2" do
    test "rewrites the recorded project directory and leaves other terms", %{tmp_dir: tmp} do
      source = compiled_source(Path.join(tmp, "source"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)

      {_, 0} =
        System.cmd("cp", ["-a", Path.join(source, "_build"), Path.join(worktree, "_build")])

      assert :ok = DepsRelocate.retarget_manifests(worktree, source)

      assert {:manifest, dir, [:other]} = manifest(worktree)
      assert dir == Path.join(worktree, "deps/lazy_html")
    end
  end

  describe "Worktree.seed_compiled_deps/3 (a fresh worktree)" do
    test "the NIF is usable from the worktree after the source is gone", %{tmp_dir: tmp} do
      source = compiled_source(Path.join(tmp, "source"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)

      assert :ok = Worktree.seed_compiled_deps(source, worktree)
      File.rm_rf!(source)

      assert File.exists?(Path.join(worktree, "deps/lazy_html/priv/#{@nif}"))
      assert File.exists?(nif(worktree))
      assert {:manifest, dir, _} = manifest(worktree)
      assert dir == Path.join(worktree, "deps/lazy_html")
    end

    test "the same through configured seed_paths", %{tmp_dir: tmp} do
      source = compiled_source(Path.join(tmp, "source"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)

      assert :ok = Worktree.seed_compiled_deps(source, worktree, ["deps", "_build/test/lib"])
      File.rm_rf!(source)

      assert File.exists?(nif(worktree))
      assert {:manifest, dir, _} = manifest(worktree)
      assert dir == Path.join(worktree, "deps/lazy_html")
    end
  end

  # A CMake-built NIF dependency (`crc32cer`): `c_build/CMakeCache.txt` records the
  # directory it was configured in, and CMake refuses to reuse it from another.
  defp cmake_dep(root, dep, cache_dir) do
    build = Path.join(root, "deps/#{dep}/c_build")
    File.mkdir_p!(Path.join(build, "CMakeFiles"))
    File.write!(Path.join(build, "CMakeFiles/marker"), "x\n")
    File.write!(Path.join(build, "libnif.so"), "so\n")

    File.write!(
      Path.join(build, "CMakeCache.txt"),
      "CMAKE_CACHEFILE_DIR:INTERNAL=#{cache_dir}\nOTHER:STRING=1\n"
    )

    build
  end

  describe "CMake cache scrubbing on seed (bug #406)" do
    test "a cache bound to the source is scrubbed from the copy only", %{tmp_dir: tmp} do
      source = compiled_source(Path.join(tmp, "source"))
      src_build = cmake_dep(source, "crc32cer", Path.join(source, "deps/crc32cer/c_build"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)

      assert :ok = Worktree.seed_compiled_deps(source, worktree)

      wt_build = Path.join(worktree, "deps/crc32cer/c_build")
      refute File.exists?(Path.join(wt_build, "CMakeCache.txt"))
      refute File.exists?(Path.join(wt_build, "CMakeFiles"))
      assert File.exists?(Path.join(wt_build, "libnif.so"))

      assert File.exists?(Path.join(src_build, "CMakeCache.txt"))
      assert File.exists?(Path.join(src_build, "CMakeFiles/marker"))
    end

    test "the same through configured seed_paths", %{tmp_dir: tmp} do
      source = compiled_source(Path.join(tmp, "source"))
      src_build = cmake_dep(source, "crc32cer", Path.join(source, "deps/crc32cer/c_build"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)

      assert :ok = Worktree.seed_compiled_deps(source, worktree, ["deps"])

      refute File.exists?(Path.join(worktree, "deps/crc32cer/c_build/CMakeCache.txt"))
      assert File.exists?(Path.join(src_build, "CMakeCache.txt"))
    end

    test "deps without c_build and caches already bound to the worktree are untouched",
         %{tmp_dir: tmp} do
      worktree = Path.join(tmp, "wt")
      bound = cmake_dep(worktree, "bound", Path.join(worktree, "deps/bound/c_build"))
      File.mkdir_p!(Path.join(worktree, "deps/plain/lib"))
      File.write!(Path.join(worktree, "deps/plain/lib/a.ex"), "a\n")

      assert :ok = DepsRelocate.scrub_cmake_caches(worktree)

      assert File.exists?(Path.join(bound, "CMakeCache.txt"))
      assert File.exists?(Path.join(bound, "CMakeFiles/marker"))
      assert File.exists?(Path.join(worktree, "deps/plain/lib/a.ex"))
    end
  end

  # bd-4uom27: nothing names a library. A `rustler_precompiled` NIF (`mdex_native`)
  # keeps its binary in a real `priv/native` inside `_build`, not behind a link, and a
  # dependency of any other shape rides along with it.
  describe "every compiled NIF dependency is seeded, whatever builds it" do
    defp precompiled_nif_source(root) do
      compiled_source(root)
      File.mkdir_p!(Path.join(root, "deps/mdex_native/lib"))
      native = Path.join(root, "_build/test/lib/mdex_native/priv/native")
      File.mkdir_p!(native)
      File.write!(Path.join(native, "libmdex_native.so"), "nif\n")
      File.mkdir_p!(Path.join(root, "_build/test/lib/mdex_native/ebin"))
      # A dependency with no deps/ entry is the project's own app: never seeded.
      File.mkdir_p!(Path.join(root, "_build/test/lib/myapp/ebin"))
      root
    end

    test "a precompiled NIF and an elixir_make NIF both survive the default seed", %{tmp_dir: tmp} do
      source = precompiled_nif_source(Path.join(tmp, "source"))
      worktree = Path.join(tmp, "wt")
      File.mkdir_p!(worktree)

      assert :ok = Worktree.seed_compiled_deps(source, worktree)
      File.rm_rf!(source)

      assert File.exists?(nif(worktree))

      assert File.exists?(
               Path.join(worktree, "_build/test/lib/mdex_native/priv/native/libmdex_native.so")
             )

      refute File.exists?(Path.join(worktree, "_build/test/lib/myapp"))
    end
  end
end
