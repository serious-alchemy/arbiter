defmodule Arbiter.Nodes.Agent do
  @moduledoc """
  The agent artifact the primary serves to joining nodes
  (`docs/design/remote-workers.md` §6): the release the primary itself runs.

  The running release is whatever `<data-home>/current` points at
  (`<data-home>/releases/<tag>`, laid out by `arb server deploy`). Its bytes
  come from, in order:

    1. the **retained published tarball** `<data-home>/releases/<tag>.tar.gz`
       the deploy keeps next to the unpacked tree: served pristine, so its
       sha256 equals the published `.sha256`;
    2. a **pack of the unpacked tree** (a `--local <dir>` deploy has no
       tarball), built on first request from an **allowlist** — `bin/`,
       `erts-*/`, `lib/`, `releases/<vsn>/` and the two `releases/` index
       files, never `COOKIE` or `tmp` — and cached under
       `<data-home>/nodes/agent-cache/` (outside `releases/`, which deploy
       prunes) so the sha256 stays stable across requests.

  The sha256 reported here is always computed from the bytes that would be
  served; a `.sha256` sidecar is never trusted over them.
  """

  @tag_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @sha_re ~r/\A[0-9a-f]{64}\z/
  @archive_root "arbiter"
  @excluded_names ["COOKIE", "tmp"]
  @cache_key {__MODULE__, :sha_cache}

  @type artifact :: %{
          version: String.t(),
          path: String.t(),
          sha256: String.t(),
          size: non_neg_integer()
        }

  @doc "The deploy data home: `:data_dir` app env, `ARB_DATA_HOME`, else `~/.arbiter`."
  @spec data_home() :: String.t()
  def data_home do
    case {Application.fetch_env(:arbiter, :data_dir), System.get_env("ARB_DATA_HOME")} do
      {{:ok, dir}, _} when is_binary(dir) -> Path.expand(dir)
      {_, dir} when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.join(System.user_home!(), ".arbiter")
    end
  end

  @doc "The running release's tag (`current` symlink target's basename), or `nil`."
  @spec release_tag(String.t()) :: String.t() | nil
  def release_tag(home \\ data_home()) do
    with {:ok, target} <- File.read_link(Path.join(home, "current")),
         tag = Path.basename(target),
         true <- Regex.match?(@tag_re, tag) do
      tag
    else
      _ -> nil
    end
  end

  @doc """
  The artifact for the running release, or `{:error, :unavailable}` when there
  is no `current` release, it is not an OTP release, or it cannot be read/packed.
  """
  @spec artifact(String.t()) :: {:ok, artifact()} | {:error, :unavailable}
  def artifact(home \\ data_home()) do
    with tag when is_binary(tag) <- release_tag(home),
         dir = Path.join([home, "releases", tag]),
         true <- File.regular?(Path.join(dir, "bin/arbiter")),
         {:ok, path} <- source_path(home, tag, dir),
         {:ok, sha, size} <- digest(path) do
      {:ok, %{version: tag, path: path, sha256: sha, size: size}}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "The artifact whose sha256 is `sha` (lowercase hex), if it is the one being served."
  @spec find_by_sha(term(), String.t()) :: {:ok, artifact()} | :error
  def find_by_sha(sha, home \\ data_home())

  def find_by_sha(sha, home) when is_binary(sha) do
    with true <- Regex.match?(@sha_re, sha),
         {:ok, %{sha256: ^sha} = art} <- artifact(home) do
      {:ok, art}
    else
      _ -> :error
    end
  end

  def find_by_sha(_sha, _home), do: :error

  # ---- source of the bytes -------------------------------------------------

  defp source_path(home, tag, dir) do
    retained = Path.join([home, "releases", tag <> ".tar.gz"])

    if File.regular?(retained), do: {:ok, retained}, else: packed(home, tag, dir)
  end

  defp packed(home, tag, dir) do
    cache = Path.join([home, "nodes", "agent-cache"])
    out = Path.join(cache, tag <> ".tar.gz")

    # One packer at a time per tag, and an existing cache entry is never
    # replaced: the sha256 the enroll response quoted must stay the one served.
    :global.trans({{__MODULE__, out}, self()}, fn ->
      if File.regular?(out), do: {:ok, out}, else: pack(dir, cache, out)
    end)
  end

  defp pack(dir, cache, out) do
    File.mkdir_p!(cache)
    tmp = out <> ".#{System.unique_integer([:positive])}.tmp"

    entries =
      for abs <- allowlisted_files(dir),
          do:
            {String.to_charlist(Path.join(@archive_root, Path.relative_to(abs, dir))),
             String.to_charlist(abs)}

    with :ok <- :erl_tar.create(String.to_charlist(tmp), entries, [:compressed]),
         :ok <- File.rename(tmp, out) do
      {:ok, out}
    else
      _ ->
        _ = File.rm(tmp)
        :error
    end
  end

  defp allowlisted_files(dir) do
    roots =
      [Path.join(dir, "bin"), Path.join(dir, "lib")] ++
        Path.wildcard(Path.join(dir, "erts-*")) ++
        release_version_dirs(dir) ++
        for f <- ["start_erl.data", "RELEASES"], do: Path.join([dir, "releases", f])

    roots |> Enum.flat_map(&walk/1) |> Enum.sort()
  end

  defp release_version_dirs(dir) do
    releases = Path.join(dir, "releases")

    case File.ls(releases) do
      {:ok, entries} ->
        for e <- entries, File.dir?(Path.join(releases, e)), do: Path.join(releases, e)

      _ ->
        []
    end
  end

  defp walk(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        children = File.ls!(path) -- @excluded_names
        Enum.flat_map(children, &walk(Path.join(path, &1)))

      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
        if Path.basename(path) in @excluded_names, do: [], else: [path]

      _ ->
        []
    end
  end

  # ---- digest ----------------------------------------------------------------

  defp digest(path) do
    with {:ok, %File.Stat{size: size, mtime: mtime}} <- File.stat(path, time: :posix) do
      key = {path, size, mtime}

      case Map.fetch(:persistent_term.get(@cache_key, %{}), key) do
        {:ok, sha} ->
          {:ok, sha, size}

        :error ->
          sha =
            path
            |> File.stream!(65_536)
            |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
            |> :crypto.hash_final()
            |> Base.encode16(case: :lower)

          :persistent_term.put(@cache_key, %{key => sha})
          {:ok, sha, size}
      end
    else
      _ -> :error
    end
  end
end
