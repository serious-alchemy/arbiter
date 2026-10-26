defmodule Arbiter.Worker.CliFetcher.Cache do
  @moduledoc """
  The content-addressed cache of verified upstream CLI bytes, under
  `<image root>/cli-cache` (`Arbiter.Config.Paths.image_root/0`).

      objects/<sha256[0..1]>/<sha256>          one file's bytes, named by its content
      entries/<cli>/<version>-<platform>.json  the manifest: the files, their hashes
                                               and modes, and where they came from

  A file shared by two versions (codex's `rg`, `bwrap`) is stored once. An entry
  is written only after every file has been verified and stored, atomically, so
  a half-fetched version has no manifest and is fetched again.

  This module only reads and writes the local disk. It never touches the
  network: it is the one part of `Arbiter.Worker.CliFetcher` that publish and
  run paths may read (see `Arbiter.Worker.CliFetcher`'s moduledoc).
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.CliFetcher.Integrity

  @type file :: %{
          path: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          mode: non_neg_integer()
        }
  @type entry :: %{
          name: String.t(),
          version: String.t(),
          platform: String.t(),
          root: Path.t(),
          source: String.t(),
          integrity: String.t(),
          main: String.t(),
          files: [file()],
          digest: String.t()
        }

  @doc "The cache root: `opts[:root]`, else `<image root>/cli-cache`."
  @spec root(keyword()) :: Path.t()
  def root(opts \\ []),
    do: Keyword.get_lazy(opts, :root, fn -> Path.join(Paths.image_root(), "cli-cache") end)

  @doc "The stored bytes of `rel_path` in `entry`."
  @spec object_path(entry(), String.t()) :: Path.t()
  def object_path(%{root: root, files: files}, rel_path) do
    %{sha256: sha} =
      Enum.find(files, &(&1.path == rel_path)) || raise KeyError, key: rel_path, term: files

    object(root, sha)
  end

  @doc """
  The cached entry for `name` at `version`, or `:error`. Read-only; an entry
  whose manifest is damaged or whose object is missing or the wrong size is a
  miss (`verify/1` re-hashes).
  """
  @spec lookup(String.t(), String.t(), keyword()) :: {:ok, entry()} | :error
  def lookup(name, version, opts \\ []) do
    root = root(opts)
    platform = platform(opts)

    with {:ok, text} <- File.read(manifest_path(root, name, version, platform)),
         {:ok, raw} <- decode(text),
         {:ok, entry} <- build(raw, root),
         true <- entry.name == name and entry.version == version and entry.platform == platform,
         true <- Enum.all?(entry.files, &present?(root, &1)) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  @doc "The newest cached version of `name` for the platform, or `nil`."
  @spec newest(String.t(), keyword()) :: String.t() | nil
  def newest(name, opts \\ []) do
    platform = platform(opts)
    dir = Path.join([root(opts), "entries", name])

    versions =
      case File.ls(dir) do
        {:ok, names} ->
          for n <- names,
              String.ends_with?(n, "-#{platform}.json"),
              do: String.replace_suffix(n, "-#{platform}.json", "")

        _ ->
          []
      end

    Arbiter.Worker.CliFetcher.Semver.newest_stable(versions)
  end

  @doc """
  Store the files staged in `staged` (`[{relative_path, mode}]` under that
  directory) as one entry. `meta` carries `:source`, `:integrity` and `:main`.
  """
  @spec put(String.t(), String.t(), Path.t(), [{String.t(), non_neg_integer()}], map(), keyword()) ::
          {:ok, entry()} | {:error, term()}
  def put(name, version, staged, members, meta, opts \\ []) do
    root = root(opts)
    platform = platform(opts)

    files =
      for {rel, mode} <- members do
        src = Path.join(staged, rel)
        sha = Integrity.sha256_file(src)
        store(src, object(root, sha), sha)
        %{path: rel, sha256: sha, size: File.stat!(src).size, mode: mode}
      end

    entry = %{
      name: name,
      version: version,
      platform: platform,
      root: root,
      source: meta.source,
      integrity: meta.integrity,
      main: meta.main,
      files: files,
      digest: digest(files)
    }

    path = manifest_path(root, name, version, platform)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, Jason.encode!(manifest(entry)))
    File.rename!(tmp, path)
    {:ok, entry}
  rescue
    e in [File.Error, File.CopyError, File.RenameError] ->
      {:error, {:cache_write, Exception.message(e)}}
  end

  @doc "Re-hash every stored file of `entry`."
  @spec verify(entry()) :: :ok | {:error, {:corrupt, String.t()}}
  def verify(%{root: root, files: files}) do
    case Enum.find(files, fn f -> not hash_ok?(object(root, f.sha256), f.sha256) end) do
      nil -> :ok
      f -> {:error, {:corrupt, f.path}}
    end
  end

  @doc """
  Copy the entry's files, with their modes, into `dest` (created). What the
  image publisher's snapshot step calls; a plain copy, never a link into the
  cache, so the cache cannot be altered through a built layer's source.
  """
  @spec materialize(entry(), Path.t()) :: :ok | {:error, term()}
  def materialize(%{files: files} = entry, dest) do
    Enum.each(files, fn f ->
      target = Path.join(dest, f.path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(object_path(entry, f.path), target)
      File.chmod!(target, f.mode)
    end)
  rescue
    e in [File.Error, File.CopyError] -> {:error, {:materialize, Exception.message(e)}}
  end

  @doc "The sha256 over the sorted `(path, sha256, mode)` of the files: one hash per version's bytes."
  @spec digest([file()]) :: String.t()
  def digest(files) do
    files
    |> Enum.sort_by(& &1.path)
    |> Enum.map_join("\n", &"#{&1.path} #{&1.sha256} #{Integer.to_string(&1.mode, 8)}")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The platform key, `opts[:platform]` else derived from the host (`linux-x64`, `linux-arm64`)."
  @spec platform(keyword()) :: String.t()
  def platform(opts \\ []), do: Keyword.get_lazy(opts, :platform, &host_platform/0)

  defp host_platform do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.starts_with?(arch, "aarch64") or String.starts_with?(arch, "arm64") -> "linux-arm64"
      true -> "linux-x64"
    end
  end

  # ---- internals --------------------------------------------------------

  defp object(root, sha), do: Path.join([root, "objects", binary_part(sha, 0, 2), sha])

  defp manifest_path(root, name, version, platform),
    do: Path.join([root, "entries", name, "#{version}-#{platform}.json"])

  # An object already stored under its hash is kept only if it still hashes to it;
  # a damaged one is replaced, so a refetch repairs the cache.
  defp store(src, target, sha) do
    unless hash_ok?(target, sha) do
      File.mkdir_p!(Path.dirname(target))
      tmp = target <> ".tmp#{System.unique_integer([:positive])}"
      File.cp!(src, tmp)
      File.chmod!(tmp, 0o444)
      File.rename!(tmp, target)
    end
  end

  defp present?(root, %{sha256: sha, size: size}) do
    case File.stat(object(root, sha)) do
      {:ok, %{type: :regular, size: ^size}} -> true
      _ -> false
    end
  end

  defp hash_ok?(path, sha), do: File.regular?(path) and Integrity.sha256_file(path) == sha

  defp manifest(entry) do
    %{
      "name" => entry.name,
      "version" => entry.version,
      "platform" => entry.platform,
      "source" => entry.source,
      "integrity" => entry.integrity,
      "main" => entry.main,
      "files" =>
        Enum.map(
          entry.files,
          &%{"path" => &1.path, "sha256" => &1.sha256, "size" => &1.size, "mode" => &1.mode}
        )
    }
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :error
    end
  end

  defp build(%{"files" => files} = m, root) when is_list(files) do
    parsed = Enum.map(files, &file/1)

    if Enum.all?(parsed, &is_map/1) do
      {:ok,
       %{
         name: m["name"],
         version: m["version"],
         platform: m["platform"],
         root: root,
         source: m["source"],
         integrity: m["integrity"],
         main: m["main"],
         files: parsed,
         digest: digest(parsed)
       }}
    else
      :error
    end
  end

  defp build(_, _), do: :error

  defp file(%{"path" => p, "sha256" => sha, "size" => s, "mode" => mode})
       when is_binary(p) and is_binary(sha) and byte_size(sha) == 64 and is_integer(s) and
              is_integer(mode) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) and safe_rel?(p),
      do: %{path: p, sha256: sha, size: s, mode: mode},
      else: :error
  end

  defp file(_), do: :error

  defp safe_rel?(p), do: Path.type(p) == :relative and ".." not in Path.split(p)
end
