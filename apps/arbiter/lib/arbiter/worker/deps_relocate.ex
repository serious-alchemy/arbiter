defmodule Arbiter.Worker.DepsRelocate do
  @moduledoc """
  Make a `deps/` + `_build/` copied from one directory usable from another
  (bd-9xcogk).

  A compiled `_build` is not position independent. Two things in it name the
  directory it was built in, and a copy to a worktree keeps both pointing at the
  original:

    * `_build/<env>/lib/<dep>/priv` and `include` are **absolute symlinks** into
      `<root>/deps/<dep>/`. A NIF an `elixir_make` dependency built (`lazy_html`'s
      `priv/`) is reached through that link; after `cp -a` it points into the
      source checkout, or into a scratch seed directory that was deleted, so the
      NIF is "missing" in the worktree. `relink/1` re-points each at the worktree's
      own `deps/<dep>/…`, as a **relative** link, so it also holds in a container
      or on a node where the worktree is mounted elsewhere.
    * `_build/<env>/lib/<dep>/.mix/compile.elixir` records the project directory.
      Mix treats a dependency whose manifest names another directory as stale and
      rebuilds it on first use, and a rebuild of an `elixir_make` dependency
      downloads a precompiled binary or clones and compiles its C sources. The
      pre-push gate has no network, so that rebuild is what failed every step.
      `retarget_manifests/2` rewrites the recorded directory to the worktree.

  Both are best-effort: anything not readable or not recognised is left alone,
  which costs a rebuild, never a wrong build.

  The pod's `seed-layer` script runs this file (with `DepsRelocate.Etf`) under the
  image's own `elixir`, so it depends on nothing else in Arbiter.
  """

  alias Arbiter.Worker.DepsRelocate.Etf

  require Logger

  @doc """
  `retarget_manifests/2` and `relink/1`:`worktree` now holds a copy of what was
  built under `from`.
  """
  @spec relocate(String.t(), String.t()) :: :ok
  def relocate(worktree, from), do: relocate(worktree, from, worktree)

  @doc """
  `relocate/2` for a tree that sits at `root` but runs at `to` (SI5): a node's
  container sees the shadow clone at the spec's mount path and a pod's worker sees
  it at `ARB_WORKTREE`, neither the path the files are copied to. Mix compares the
  path it runs at, so the manifests and CMake caches are retargeted to `to`; the
  links are relative, so they hold at both.
  """
  @spec relocate(String.t(), String.t(), String.t()) :: :ok
  def relocate(root, from, to) when is_binary(root) and is_binary(from) and is_binary(to) do
    retarget_manifests(root, from, to)
    relink(root)
    scrub_cmake_caches(root, to)
  end

  @doc """
  Remove `deps/*/c_build/CMakeCache.txt` and `CMakeFiles` from `worktree` when the
  cache's `CMAKE_CACHEFILE_DIR` is not under `worktree`. CMake refuses to reuse a
  cache configured in another directory, so a NIF dependency (`crc32cer`) could
  not be recompiled in the copy; with the cache gone it reconfigures cleanly. A
  cache already bound to `worktree`, or one that cannot be read, is left alone.
  Only the given tree is touched.
  """
  @spec scrub_cmake_caches(String.t(), String.t() | nil) :: :ok
  def scrub_cmake_caches(worktree, running_at \\ nil) when is_binary(worktree) do
    running_at = running_at || worktree

    for cache <- Path.wildcard(Path.join(worktree, "deps/*/c_build/CMakeCache.txt")),
        {:ok, body} <- [File.read(cache)],
        dir = cache_dir(body),
        not is_nil(dir),
        not under?(dir, running_at) do
      File.rm(cache)
      File.rm_rf(Path.join(Path.dirname(cache), "CMakeFiles"))
    end

    :ok
  end

  defp cache_dir(body) do
    case Regex.run(~r/^CMAKE_CACHEFILE_DIR:[A-Z]+=(.+)$/m, body) do
      [_, dir] -> String.trim(dir)
      _ -> nil
    end
  end

  @doc """
  Re-point each `_build/*/lib/<dep>/{priv,include}` absolute symlink at
  `worktree/deps/<dep>/…` with a relative link, when that directory exists.
  Idempotent; a link already relative is left alone. Returns `:ok`.
  """
  @spec relink(String.t()) :: :ok
  def relink(worktree) when is_binary(worktree) do
    for name <- ["priv", "include"],
        link <- Path.wildcard(Path.join(worktree, "_build/*/lib/*/" <> name)),
        {:ok, target} <- [File.read_link(link)],
        Path.type(target) == :absolute do
      dep = link |> Path.dirname() |> Path.basename()

      if File.exists?(Path.join([worktree, "deps", dep, name])) do
        File.rm(link)
        File.ln_s(Path.join(["..", "..", "..", "..", "deps", dep, name]), link)
      end
    end

    :ok
  end

  @doc """
  Rewrite the project directory every `_build/*/lib/*/.mix/compile.elixir`
  manifest records from `from` (or anything under it) to `to` (default
  `worktree`). The directory shows up twice over: as the dep's project dir, and inside
  the recorded app config (`tailwind: [cd: "<src>/apps/web"]`), which Mix compares
  too; every binary equal to or under `from` is rewritten, to any depth.

  The manifest is rewritten in its bytes (`Arbiter.Worker.DepsRelocate.Etf`), not
  decoded: a `:safe` decode refuses a manifest that names a module atom this VM has not
  seen, which is nearly every real one, and the relocation then did nothing at all
  (SI5). A manifest it cannot walk is left alone and logged.
  """
  @spec retarget_manifests(String.t(), String.t(), String.t() | nil) :: :ok
  def retarget_manifests(worktree, from, to \\ nil)
      when is_binary(worktree) and is_binary(from) do
    pattern = Path.join(worktree, "_build/*/lib/*/.mix/compile.elixir")
    to = to || worktree

    for file <- Path.wildcard(pattern, match_dot: true) do
      retarget_manifest(file, from, to)
    end

    :ok
  end

  defp retarget_manifest(file, from, to) do
    with {:ok, bin} <- File.read(file) do
      case Etf.rewrite(bin, from, to) do
        {:ok, rewritten} ->
          File.write(file, rewritten)

        :unchanged ->
          :ok

        :error ->
          Logger.warning("DepsRelocate: cannot rewrite #{file}; Mix will rebuild that dependency")
      end
    end
  end

  defp under?(dir, from), do: dir == from or String.starts_with?(dir, from <> "/")
end
