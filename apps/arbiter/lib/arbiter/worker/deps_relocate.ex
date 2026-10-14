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
  """

  @doc """
  `retarget_manifests/2` and `relink/1`: `worktree` now holds a copy of what was
  built under `from`.
  """
  @spec relocate(String.t(), String.t()) :: :ok
  def relocate(worktree, from) when is_binary(worktree) and is_binary(from) do
    retarget_manifests(worktree, from)
    relink(worktree)
    scrub_cmake_caches(worktree)
  end

  @doc """
  Remove `deps/*/c_build/CMakeCache.txt` and `CMakeFiles` from `worktree` when the
  cache's `CMAKE_CACHEFILE_DIR` is not under `worktree`. CMake refuses to reuse a
  cache configured in another directory, so a NIF dependency (`crc32cer`) could
  not be recompiled in the copy; with the cache gone it reconfigures cleanly. A
  cache already bound to `worktree`, or one that cannot be read, is left alone.
  Only the given tree is touched.
  """
  @spec scrub_cmake_caches(String.t()) :: :ok
  def scrub_cmake_caches(worktree) when is_binary(worktree) do
    for cache <- Path.wildcard(Path.join(worktree, "deps/*/c_build/CMakeCache.txt")),
        {:ok, body} <- [File.read(cache)],
        dir = cache_dir(body),
        not is_nil(dir),
        not under?(dir, worktree) do
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
  manifest records from `from` (or anything under it) to `worktree`. Only a
  manifest that decodes (`:safe`: the file may have come out of a container) and
  mentions `from` is touched.
  """
  @spec retarget_manifests(String.t(), String.t()) :: :ok
  def retarget_manifests(worktree, from) when is_binary(worktree) and is_binary(from) do
    pattern = Path.join(worktree, "_build/*/lib/*/.mix/compile.elixir")

    for file <- Path.wildcard(pattern, match_dot: true) do
      retarget_manifest(file, from, worktree)
    end

    :ok
  end

  defp retarget_manifest(file, from, to) do
    with {:ok, bin} <- File.read(file),
         term when not is_nil(term) <- safe_decode(bin),
         true <- mentions?(term, from) do
      File.write(file, :erlang.term_to_binary(retarget(term, from, to), [:compressed]))
    end
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  # The directory shows up twice over: as the dep's project dir, and inside the
  # recorded app config (`tailwind: [cd: "<src>/apps/web"]`), which Mix compares
  # too. Both are rewritten, to any depth.
  defp mentions?(term, from) when is_binary(term), do: under?(term, from)
  defp mentions?(term, from) when is_tuple(term), do: term |> Tuple.to_list() |> mentions?(from)
  defp mentions?(term, from) when is_map(term), do: term |> Map.to_list() |> mentions?(from)
  defp mentions?([head | tail], from), do: mentions?(head, from) or mentions?(tail, from)
  defp mentions?(_, _), do: false

  defp retarget(term, from, to) when is_binary(term) do
    if under?(term, from),
      do: to <> binary_part(term, byte_size(from), byte_size(term) - byte_size(from)),
      else: term
  end

  defp retarget(term, from, to) when is_tuple(term),
    do: term |> Tuple.to_list() |> retarget(from, to) |> List.to_tuple()

  defp retarget(%{__struct__: _} = term, _from, _to), do: term

  defp retarget(term, from, to) when is_map(term),
    do: Map.new(term, fn {k, v} -> {retarget(k, from, to), retarget(v, from, to)} end)

  defp retarget([head | tail], from, to),
    do: [retarget(head, from, to) | retarget(tail, from, to)]

  defp retarget(term, _from, _to), do: term

  defp under?(dir, from), do: dir == from or String.starts_with?(dir, from <> "/")
end
