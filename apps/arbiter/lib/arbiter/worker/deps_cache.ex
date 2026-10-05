defmodule Arbiter.Worker.DepsCache do
  @moduledoc """
  The image-keyed deps cache for container workers (bd-1wm14e, P6 of
  `docs/design/podman-worker-containers.md` §3.3; generalises
  `Arbiter.Worker.Worktree.seed_compiled_deps/3`, bd-5tncmq).

  A compiled `_build` is bound to the toolchain that produced it: it holds NIFs
  (`exqlite`, `mdex_native`) built against one libc and one OTP. The bwrap path
  seeds a worktree from the operator's own checkout, which is the same host the
  worker runs on. A container runs a different libc and OTP, so seeding it from
  the host's `_build` is not guaranteed to load, and measurably recompiles.
  This module builds the cache **inside the image** instead.

  ## The key: `(lockfile hash, image tag)`

  `key/4` names a directory `<root>/<lock12>-<image12>`. The lock hash is the
  SHA-256 of `mix.lock` as committed on the repo's **default branch** (the same
  supply-chain posture as `Arbiter.Worker.Image`: never a worker's working
  tree or its branch). The image tag is already a content hash of the pinned
  Containerfile, its build args and `.tool-versions`, so a changed Erlang,
  Elixir, Node or base digest changes the tag and therefore the key: a
  toolchain change **misses** the cache and is seeded afresh; it can never
  hand a worker a `_build` another toolchain compiled.

  ## Seeding (`ensure/4`)

  A miss runs one job in the image: the default branch's tree is exported
  (`git archive`, so no `.git` and nothing uncommitted) into a scratch
  directory, and `mix deps.get && mix deps.compile` runs there for the `test`
  and `dev` envs. The container is the P3 hardening (`Arbiter.Worker.Container`:
  read-only root, no capabilities, `no-new-privileges`) with exactly two
  mounts, the scratch export and a scratch `HOME`, and network via `pasta`
  because fetching deps and Hex needs it. It sees neither the repo, nor a
  credential, nor any other cache. On success the `deps/` and `_build/` it
  produced are moved into the cache directory and a `.complete` marker is
  written last; a half-built directory is never served and a failed seed leaves
  nothing behind. Callers asking for the same key share one job
  (`:global.trans/4`); the second finds the marker and returns.

  ## Per-worker copies (`install/3`)

  A cache directory is **never mounted into any container** and never written
  after it is completed. Each worker gets its own copy of `deps/` and `_build/`
  inside its checkout, made with `cp -a --reflink=always` (a near-free
  copy-on-write clone on btrfs/xfs) and, where the filesystem cannot clone, a
  plain `cp -a`. A worker that poisons its `_build` therefore poisons only its
  own checkout. The key is recorded in `<checkout>/.git/arbiter-deps-cache`, so
  a resumed worker with the same key keeps its work and one whose image changed
  is re-seeded, replacing the old (now ABI-stale) artifacts.

  Hex and Mix homes stay per run (`ContainerSpawn`'s per-run `HOME`).

  ## Options

  `:root` (default `<scratch_root>/deps-cache`), `:scratch` (default
  `<scratch_root>/deps-seed`), `:runner` and `:podman` (as `Container.run/2`),
  `:timeout` (seed job, ms), `:cp_hook` (tests: `(cp args -> nil | {out, status})`
  to stand in for a filesystem that cannot clone).
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Mergers
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.ReleaseEnv

  require Logger

  @complete ".complete"
  @marker "arbiter-deps-cache"
  @artifacts ["deps", "_build"]
  # The seed job's `MIX_HOME`: the Hex archive and rebar3 it installed. Both are
  # compiled for the image's OTP, so they are as ABI-bound as `_build`.
  @mix_home "mix_home"
  @seed_timeout_ms 30 * 60_000
  @git_timeout_ms 60_000

  # Hex and rebar are installed per run into the scratch HOME; the image carries
  # only Elixir. Both envs, because workers compile in `test` and some in `dev`.
  @seed_script """
  set -e
  mix local.hex --force
  mix local.rebar --force
  mix deps.get
  MIX_ENV=test mix deps.compile
  MIX_ENV=dev mix deps.compile
  """

  @type key :: %{lock_hash: String.t(), image_tag: String.t(), dir: String.t(), ref: String.t()}

  @doc "The mix invocation the seed job runs (exposed for the docs and tests)."
  @spec seed_script() :: String.t()
  def seed_script, do: @seed_script

  # -- key -----------------------------------------------------------------------

  @doc """
  The cache key for `repo_path`'s `default_branch` under `image_tag`.

  `{:error, :no_lockfile}` for a repo whose default branch has no `mix.lock`
  (not a Mix project, or one with no deps): there is nothing to cache.
  """
  @spec key(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, key()} | {:error, term()}
  def key(repo_path, default_branch, image_tag, opts \\ []) do
    with :ok <- check_image(image_tag),
         {:ok, ref} <- Image.default_ref(repo_path, default_branch),
         {:ok, lock} <- read_lock(repo_path, ref) do
      lock_hash = digest(lock)
      name = binary_part(lock_hash, 0, 12) <> "-" <> binary_part(digest(image_tag), 0, 12)

      {:ok,
       %{lock_hash: lock_hash, image_tag: image_tag, dir: Path.join(root(opts), name), ref: ref}}
    end
  end

  defp check_image(tag) when is_binary(tag) and tag != "" do
    if String.starts_with?(tag, "-"), do: {:error, {:bad_image, tag}}, else: :ok
  end

  defp check_image(tag), do: {:error, {:bad_image, tag}}

  defp read_lock(repo_path, ref) do
    case git(repo_path, ["cat-file", "blob", ref <> ":mix.lock"]) do
      {body, 0} -> {:ok, body}
      _ -> {:error, :no_lockfile}
    end
  end

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp root(opts),
    do: Keyword.get_lazy(opts, :root, fn -> Path.join(Paths.scratch_root(), "deps-cache") end)

  # -- ensure --------------------------------------------------------------------

  @doc """
  The completed cache for the key, seeding it in the image on a miss.

  `{:ok, %{dir: dir, seeded?: boolean}}`; `seeded?` is `false` on a hit.
  """
  @spec ensure(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{dir: String.t(), seeded?: boolean(), lock_hash: String.t()}} | {:error, term()}
  def ensure(repo_path, default_branch, image_tag, opts \\ []) do
    with {:ok, key} <- key(repo_path, default_branch, image_tag, opts) do
      if complete?(key.dir) do
        {:ok, %{dir: key.dir, seeded?: false, lock_hash: key.lock_hash}}
      else
        locked(key, fn -> seed_once(repo_path, key, opts) end)
      end
    end
  end

  defp complete?(dir), do: File.regular?(Path.join(dir, @complete))

  # One seed job per key; later callers wait, then find the marker.
  defp locked(key, fun) do
    :global.trans({{__MODULE__, key.dir}, self()}, fun, [node()], :infinity)
  end

  defp seed_once(repo_path, key, opts) do
    if complete?(key.dir) do
      {:ok, %{dir: key.dir, seeded?: false, lock_hash: key.lock_hash}}
    else
      with :ok <- seed(repo_path, key, opts) do
        {:ok, %{dir: key.dir, seeded?: true, lock_hash: key.lock_hash}}
      end
    end
  end

  defp seed(repo_path, key, opts) do
    work =
      Path.join(
        scratch(opts),
        "seed-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    src = Path.join(work, "src")
    home = Path.join(work, "home")

    try do
      File.mkdir_p!(src)
      File.mkdir_p!(home)

      with :ok <- export_tree(repo_path, key.ref, work, src),
           :ok <- run_seed_job(key, src, home, opts) do
        publish(src, Path.join(home, ".mix"), key)
      end
    after
      force_rm_rf(work)
    end
  end

  defp scratch(opts),
    do: Keyword.get_lazy(opts, :scratch, fn -> Path.join(Paths.scratch_root(), "deps-seed") end)

  # The default branch's committed tree: no `.git`, nothing a worker edited.
  defp export_tree(repo_path, ref, work, src) do
    tarball = Path.join(work, "tree.tar")

    with {_, 0} <- git(repo_path, ["archive", "--format=tar", "-o", tarball, ref]),
         {_, 0} <- tar(["-xf", tarball, "-C", src]) do
      :ok
    else
      {output, status} -> {:error, {:export_failed, status, tail(output)}}
    end
  end

  defp run_seed_job(key, src, home, opts) do
    name =
      Container.name_for(
        "deps-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    run_opts =
      Keyword.merge(
        Keyword.take(opts, [:runner, :podman]),
        worktree: src,
        home: home,
        image: key.image_tag,
        name: name,
        network: :pasta,
        env: [
          {"LANG", "C.UTF-8"},
          {"MIX_ENV", "test"},
          {"HEX_HOME", Path.join(home, ".hex")},
          {"MIX_HOME", Path.join(home, ".mix")}
        ],
        timeout: Keyword.get(opts, :timeout, @seed_timeout_ms)
      )

    case Container.run(["sh", "-c", @seed_script], run_opts) do
      {:ok, {_out, 0}} -> :ok
      {:ok, {out, status}} -> {:error, {:seed_failed, status, tail(out)}}
      {:error, reason} -> {:error, {:seed_failed, reason}}
    end
  end

  # Move the artifacts into a sibling temp dir, mark it complete, then rename it
  # into place: the final name only ever appears complete.
  defp publish(src, mix_home, key) do
    staging =
      key.dir <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)

    try do
      File.mkdir_p!(staging)
      present = Enum.filter(@artifacts, &File.dir?(Path.join(src, &1)))

      if "deps" in present do
        Enum.each(present, &File.rename!(Path.join(src, &1), Path.join(staging, &1)))
        prune_own_apps(staging)
        if File.dir?(mix_home), do: File.rename!(mix_home, Path.join(staging, @mix_home))

        File.write!(
          Path.join(staging, @complete),
          "lock=#{key.lock_hash}\nimage=#{key.image_tag}\nsrc=#{src}\n"
        )

        File.rename!(staging, key.dir)
        :ok
      else
        {:error, {:seed_failed, :no_deps_produced}}
      end
    rescue
      e in File.Error -> {:error, {:publish_failed, Exception.message(e)}}
    after
      force_rm_rf(staging)
    end
  end

  # `deps.compile` leaves the project's own app dirs in `_build/<env>/lib`. Like
  # `Worktree.seed_compiled_deps/3`, cache dependencies only: an app compiles
  # fresh per branch, so one branch's output can never reach another.
  defp prune_own_apps(dir) do
    deps = dir |> Path.join("deps") |> File.ls!() |> MapSet.new()

    for lib <- Path.wildcard(Path.join(dir, "_build/*/lib")),
        entry <- File.ls!(lib),
        not MapSet.member?(deps, entry) do
      force_rm_rf(Path.join(lib, entry))
    end

    :ok
  end

  # -- install -------------------------------------------------------------------

  @doc """
  Give `worktree` its own copy of `cache_dir`'s `deps/` and `_build/`.

  `{:ok, %{method: :reflink | :copy | :unchanged, ms: ms}}`. `:unchanged` means
  the checkout already holds this cache's copy, so the worker's own compiled
  work is left alone.
  """
  @spec install(String.t(), String.t(), keyword()) ::
          {:ok, %{method: :reflink | :copy | :unchanged, ms: non_neg_integer()}}
          | {:error, term()}
  def install(cache_dir, worktree, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with true <- complete?(cache_dir) or {:error, {:cache_incomplete, cache_dir}},
         {:ok, stamp} <- File.read(Path.join(cache_dir, @complete)) do
      installed = installed_stamp(worktree)

      if installed == stamp do
        {:ok, %{method: :unchanged, ms: elapsed(started)}}
      else
        with {:ok, method} <- copy_artifacts(cache_dir, worktree, opts) do
          retarget_manifests(worktree, stamp)
          record(worktree, stamp)
          {:ok, %{method: method, ms: elapsed(started)}}
        end
      end
    else
      {:error, _} = error -> error
      other -> {:error, {:install_failed, other}}
    end
  end

  # Mix recompiles a dependency whose project directory is not the one its
  # manifest (`_build/<env>/lib/<dep>/.mix/compile.elixir`) was written in, so a
  # `_build` seeded at one path is stale at every other (found measuring this:
  # the bwrap path's host seed has the same first-use rebuild). The seed ran at
  # the `src=` path in the stamp; point each manifest's directory at the
  # worktree instead. Only a manifest we can read and whose directory is under
  # that path is touched (`:safe` decoding: the file came out of a container);
  # anything else is left alone and costs a recompile, never a wrong build.
  defp retarget_manifests(worktree, stamp) do
    with [_, from] <- Regex.run(~r/^src=(.+)$/m, stamp) do
      pattern = Path.join(worktree, "_build/*/lib/*/.mix/compile.elixir")

      for file <- Path.wildcard(pattern, match_dot: true) do
        retarget_manifest(file, from, worktree)
      end
    end

    :ok
  end

  defp retarget_manifest(file, from, to) do
    with {:ok, bin} <- File.read(file),
         term when is_tuple(term) <- safe_decode(bin),
         true <- Enum.any?(Tuple.to_list(term), &under?(&1, from)) do
      moved =
        term
        |> Tuple.to_list()
        |> Enum.map(fn
          dir when is_binary(dir) ->
            if under?(dir, from),
              do: to <> binary_part(dir, byte_size(from), byte_size(dir) - byte_size(from)),
              else: dir

          other ->
            other
        end)
        |> List.to_tuple()

      File.write(file, :erlang.term_to_binary(moved, [:compressed]))
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  defp under?(dir, from) when is_binary(dir),
    do: dir == from or String.starts_with?(dir, from <> "/")

  defp under?(_, _), do: false

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp copy_artifacts(cache_dir, worktree, opts) do
    # The old artifacts are the previous seed's (host-built, or another image's):
    # exactly what must not survive. Staged then swapped per directory.
    Enum.reduce_while(@artifacts, {:ok, :copy}, fn name, {:ok, method} ->
      source = Path.join(cache_dir, name)

      cond do
        not File.dir?(source) ->
          {:cont, {:ok, method}}

        true ->
          case replace(source, Path.join(worktree, name), opts) do
            {:ok, used} -> {:cont, {:ok, merge_method(method, used)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  # Any plain copy makes the install a `:copy`; all-clone is a `:reflink`.
  defp merge_method(:copy, used), do: used
  defp merge_method(:reflink, :reflink), do: :reflink
  defp merge_method(_, :copy), do: :copy

  defp replace(source, dest, opts) do
    force_rm_rf(dest)
    File.mkdir_p!(Path.dirname(dest))

    case cp(["-a", "--reflink=always", source, dest], opts) do
      {_, 0} ->
        {:ok, :reflink}

      {_, _} ->
        # No clone support here: `cp` may have created part of `dest` first.
        force_rm_rf(dest)

        case cp(["-a", "--reflink=never", source, dest], opts) do
          {_, 0} -> {:ok, :copy}
          {out, status} -> {:error, {:copy_failed, dest, status, tail(out)}}
        end
    end
  end

  defp cp(args, opts) do
    hook = Keyword.get(opts, :cp_hook)
    (hook && hook.(args)) || run_cp(args)
  end

  # sobelow_skip ["CI.System"]
  defp run_cp(args) do
    case System.find_executable("cp") do
      nil -> {"cp: not found", 127}
      cp -> ReleaseEnv.cmd(cp, args, stderr_to_stdout: true)
    end
  end

  defp installed_stamp(worktree) do
    case File.read(marker_path(worktree)) do
      {:ok, stamp} -> stamp
      {:error, _} -> nil
    end
  end

  defp record(worktree, stamp) do
    File.write(marker_path(worktree), stamp)
  end

  defp marker_path(worktree), do: Path.join([worktree, ".git", @marker])

  @doc """
  Give a run's `HOME` the cache's Hex archive and rebar3 (`<home>/.mix`).

  A container has no operator `~/.mix` to borrow (the bwrap jail links one in),
  and without Hex `mix` stops to ask whether to install it, offline. The copy
  is per run and made only when `<home>/.mix` is absent, so a resumed run keeps
  its own. `{:ok, :reflink | :copy | :unchanged | :none}`; `:none` is a cache
  built without one.
  """
  @spec install_mix_home(String.t(), String.t(), keyword()) ::
          {:ok, :reflink | :copy | :unchanged | :none} | {:error, term()}
  def install_mix_home(cache_dir, home, opts \\ []) do
    source = Path.join(cache_dir, @mix_home)
    dest = Path.join(home, ".mix")

    cond do
      not File.dir?(source) -> {:ok, :none}
      File.exists?(dest) -> {:ok, :unchanged}
      true -> replace(source, dest, opts)
    end
  end

  # -- seed a private clone ---------------------------------------------------------

  @doc """
  The whole step for a container worker: find the repo's cache for `image_tag`
  (seeding it on a miss) and install it into `worktree`, a private clone.

  Options are `ensure/4`'s plus `:workspace` and `:repo` (to find the default
  branch) and `:home` (the run's `HOME`, which gets the Hex archive).
  `{:ok, summary}` carries `:dir`, `:seeded?`, `:method` and the install time in
  `:ms`.
  """
  @spec seed_worktree(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def seed_worktree(worktree, image_tag, opts \\ []) do
    base =
      Mergers.base_branch(Keyword.get(opts, :workspace), Keyword.get(opts, :repo)) || "main"

    with repo when is_binary(repo) <- PrivateClone.main_repo(worktree),
         {:ok, cache} <- ensure(repo, base, image_tag, opts),
         {:ok, installed} <- install(cache.dir, worktree, opts),
         {:ok, mix_home} <- install_home(cache.dir, Keyword.get(opts, :home), opts) do
      Logger.info(
        "DepsCache: #{worktree} #{describe(installed.method)} from #{cache.dir} " <>
          "(#{if cache.seeded?, do: "seeded", else: "hit"}, #{installed.ms} ms)"
      )

      {:ok, cache |> Map.merge(installed) |> Map.put(:mix_home, mix_home)}
    else
      nil -> {:error, {:not_a_private_clone, worktree}}
      {:error, _} = error -> error
    end
  end

  defp install_home(_cache_dir, nil, _opts), do: {:ok, :none}
  defp install_home(cache_dir, home, opts), do: install_mix_home(cache_dir, home, opts)

  defp describe(:unchanged), do: "already current"
  defp describe(method), do: "installed by #{method}"

  # -- helpers ---------------------------------------------------------------------

  # sobelow_skip ["CI.System"]
  defp git(repo_path, args) do
    case System.find_executable("git") do
      nil ->
        {"git: not found", 127}

      git ->
        bounded(fn -> ReleaseEnv.cmd(git, ["-C", repo_path | args], stderr_to_stdout: true) end)
    end
  end

  # sobelow_skip ["CI.System"]
  defp tar(args) do
    case System.find_executable("tar") do
      nil -> {"tar: not found", 127}
      tar -> bounded(fn -> ReleaseEnv.cmd(tar, args, stderr_to_stdout: true) end)
    end
  end

  defp bounded(fun) do
    task = Task.async(fun)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"timed out after #{@git_timeout_ms} ms", 124}
    end
  end

  defp tail(output), do: output |> String.trim() |> String.slice(-2000, 2000)

  # A `_build` can hold read-only directories; make the tree writable first.
  defp force_rm_rf(path) do
    if File.exists?(path) or match?({:ok, _}, File.lstat(path)) do
      _ = ReleaseEnv.cmd("chmod", ["-R", "u+rwX", path], stderr_to_stdout: true)
      File.rm_rf(path)
    end

    :ok
  end
end
