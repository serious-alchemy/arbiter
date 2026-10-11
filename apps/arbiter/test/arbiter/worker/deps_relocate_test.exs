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
    File.mkdir_p!(Path.join(root, "deps/lazy_html/c_src"))
    lib = Path.join(root, "_build/#{env}/lib/lazy_html")
    File.mkdir_p!(Path.join(lib, "ebin"))
    File.mkdir_p!(Path.join(lib, ".mix"))
    File.ln_s!(Path.join(root, "deps/lazy_html/priv"), Path.join(lib, "priv"))
    File.ln_s!(Path.join(root, "deps/lazy_html/c_src"), Path.join(lib, "include"))

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
end
