defmodule Arbiter.Worker.CliSet do
  @moduledoc """
  The one resolver for the CLIs a worker runs: the local bind mounts
  (`Arbiter.Worker.ContainerSpawn.cli_mounts/2`), the remote file shelf
  (`ContainerSpawn`'s `remote_cli/2`) and the published image's CLI layers
  (`Arbiter.Worker.Image.Publisher.Pipeline`) all read it (SI1,
  `docs/design/remote-workers.md` §21.2.3, OD13/OD14).

  ## Where the bytes come from

  Only `Arbiter.Worker.CliFetcher.Cache`, SI1a's verified, content-addressed
  store of pinned upstream releases. Never a CLI installed on the primary:
  nothing here looks at `PATH`, `~/.local/bin` or an npm prefix, and it never
  touches the network (`CliFetcher.Cache.lookup/3` is a read). A CLI whose
  pinned version is not cached yet is left out of the set, and asking for it
  is `{:error, {:cli_not_cached, name}}`.

  ## The set

  `resolve/1` returns the cached CLIs in **churn order**, the order the image
  layers stack in above the seed layer (`codex`, `claude`, `arb`), each as the
  files it puts in `/opt/arbiter/cli`:

    * `codex`: every file of the vendored build (`codex`, its sibling
      executables, `rg`, `bwrap`) flat in the directory;
    * `claude`: `claude`;
    * `arb`: `arb`, the launcher (`Arbiter.Worker.ArbCli.launcher/0`), and
      `arb.escript`, the release's escript beside it.

  The **set hash** is the sha256 over the sorted `(cli, file, sha256, mode)` of
  those files: identical bytes give an identical hash and, built with a fixed
  timestamp, byte-identical layers. A version string is a label, not part of
  the hash. `set8` is its first eight hex digits, the `cli<set8>` of a run
  image's tag and the `arbiter.cli-set` label.

  ## Materializing

  A bind mount or a `COPY` needs files with modes, and the cache's objects are
  named by hash and read-only. `materialize/2` copies each CLI to
  `<image root>/cli-sets/<set8>/<cli>/<file>` (never a link into the cache) and
  writes `manifest.json` beside them; the mounts, the shelf and the layer's
  build context all use that directory.

  ## Options

  `:cli_set` (a resolved `t:t/0`, returned as is; a test seam),
  `:cli_cache_root` (the `CliFetcher.Cache` root), `:cli_sets_root` (where sets
  are materialized, default `<image root>/cli-sets`), and `CliFetcher.pin/2`'s
  `:pins` and `:arb_version` and the cache's `:platform` as `:cli_pins`,
  `:cli_arb_version` and `:cli_platform`.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.ArbCli
  alias Arbiter.Worker.CliFetcher
  alias Arbiter.Worker.CliFetcher.Cache
  alias Arbiter.Worker.CliFetcher.Integrity

  # Churn order: the layer that changes least is the lowest.
  @order ["codex", "claude", "arb"]
  @providers ["claude", "codex"]
  @cli_dir "/opt/arbiter/cli"
  @label "arbiter"

  @type file :: %{
          name: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          mode: non_neg_integer(),
          source: {:cache, Cache.entry(), String.t()} | {:launcher, String.t()},
          path: Path.t() | nil
        }
  @type cli :: %{
          name: String.t(),
          version: String.t(),
          integrity: String.t(),
          source: String.t(),
          digest: String.t(),
          files: [file()]
        }
  @type t :: %__MODULE__{
          hash: String.t(),
          set8: String.t(),
          platform: String.t(),
          root: Path.t(),
          dir: Path.t() | nil,
          clis: [cli()]
        }

  defstruct [:hash, :set8, :platform, :root, :dir, clis: []]

  @doc """
  The options that select where the set is read from (a test seam; unset on a
  real spawn): threaded by `ClaudeSession` and `Dispatch` to every resolver call.
  """
  @spec option_keys() :: [atom()]
  def option_keys,
    do: [:cli_set, :cli_cache_root, :cli_sets_root, :cli_pins, :cli_arb_version, :cli_platform]

  @doc "The CLI names in churn order (the image's layer order, lowest first)."
  @spec names() :: [String.t()]
  def names, do: @order

  @doc "Where the CLIs live in a worker container."
  @spec cli_dir() :: String.t()
  def cli_dir, do: @cli_dir

  @doc """
  Resolve the set from the pinned upstream cache. A CLI that is not pinned or
  not cached is absent from the set; the set may therefore be empty.
  """
  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts \\ [])

  def resolve(opts) do
    case Keyword.get(opts, :cli_set) do
      %__MODULE__{} = set -> {:ok, set}
      _ -> from_cache(opts)
    end
  end

  defp from_cache(opts) do
    fetcher_opts = fetcher_opts(opts)

    @order
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case cached(name, fetcher_opts) do
        {:ok, entry} ->
          case build_cli(name, entry) do
            {:ok, cli} -> {:cont, {:ok, [cli | acc]}}
            {:error, _} = error -> {:halt, error}
          end

        :error ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, clis} ->
        clis = Enum.reverse(clis)
        hash = hash(clis)

        {:ok,
         %__MODULE__{
           hash: hash,
           set8: binary_part(hash, 0, 8),
           platform: Cache.platform(fetcher_opts),
           root: sets_root(opts),
           clis: clis
         }}

      {:error, _} = error ->
        error
    end
  end

  defp fetcher_opts(opts) do
    base =
      for {from, to} <- [cli_platform: :platform, cli_pins: :pins, cli_arb_version: :arb_version],
          Keyword.has_key?(opts, from),
          do: {to, Keyword.fetch!(opts, from)}

    case Keyword.fetch(opts, :cli_cache_root) do
      {:ok, root} -> Keyword.put(base, :root, root)
      :error -> base
    end
  end

  defp cached(name, fetcher_opts) do
    with version when is_binary(version) <- CliFetcher.pin(name, fetcher_opts),
         {:ok, _entry} = hit <- Cache.lookup(name, version, fetcher_opts) do
      hit
    else
      _ -> :error
    end
  end

  defp sets_root(opts),
    do:
      Keyword.get_lazy(opts, :cli_sets_root, fn -> Path.join(Paths.image_root(), "cli-sets") end)

  # -- one CLI's files, as the container sees them ---------------------------

  defp build_cli(name, entry) do
    with {:ok, files} <- container_files(name, entry) do
      {:ok,
       %{
         name: name,
         version: entry.version,
         integrity: entry.integrity,
         source: entry.source,
         digest: entry.digest,
         files: files
       }}
    end
  end

  # `arb` is the launcher plus the release's escript beside it.
  defp container_files("arb", entry) do
    launcher = ArbCli.launcher()

    escripts =
      Enum.map(entry.files, fn f -> cache_file("arb.escript", f, entry) end)

    {:ok,
     Enum.sort_by(
       [
         %{
           name: "arb",
           sha256: sha256(launcher),
           size: byte_size(launcher),
           mode: 0o755,
           source: {:launcher, launcher},
           path: nil
         }
         | escripts
       ],
       & &1.name
     )}
  end

  # Every other CLI is flat in `/opt/arbiter/cli`; two files may not share a name.
  defp container_files(name, entry) do
    files = Enum.map(entry.files, fn f -> cache_file(Path.basename(f.path), f, entry) end)

    case files |> Enum.frequencies_by(& &1.name) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> {:ok, Enum.sort_by(files, & &1.name)}
      {dup, _} -> {:error, {:cli_file_collision, name, dup}}
    end
  end

  defp cache_file(dest, f, entry) do
    %{
      name: dest,
      sha256: f.sha256,
      size: f.size,
      mode: f.mode,
      source: {:cache, entry, f.path},
      path: nil
    }
  end

  defp hash(clis) do
    clis
    |> Enum.flat_map(fn cli ->
      for f <- cli.files, do: "#{cli.name} #{f.name} #{f.sha256} #{Integer.to_string(f.mode, 8)}"
    end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> sha256()
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  # -- the set, read ---------------------------------------------------------

  @doc "The CLI entry named `name`, or `nil`."
  @spec cli(t(), String.t()) :: cli() | nil
  def cli(%__MODULE__{clis: clis}, name), do: Enum.find(clis, &(&1.name == name))

  @doc "The providers whose CLI is in the set (`arbiter.cli-providers`)."
  @spec providers(t()) :: [String.t()]
  def providers(%__MODULE__{clis: clis}) do
    for(cli <- clis, cli.name in @providers, do: cli.name) |> Enum.sort()
  end

  @doc "The `{host path, container path}` pairs of one CLI. Needs a materialized set."
  @spec cli_mounts(t(), String.t()) :: [{Path.t(), String.t()}]
  def cli_mounts(%__MODULE__{} = set, name) do
    case cli(set, name) do
      nil -> []
      %{files: files} -> for f <- files, do: {f.path, @cli_dir <> "/" <> f.name}
    end
  end

  @doc """
  What a `provider` run mounts: its CLI, then `arb` when the set has it. A
  provider whose CLI is not in the set is `{:error, {:cli_not_cached, provider}}`.
  `arb` is optional (a worker without it still runs, minus the CLI).
  """
  @spec mounts(t(), String.t()) :: {:ok, [{Path.t(), String.t()}]} | {:error, term()}
  def mounts(%__MODULE__{} = set, provider) do
    case cli(set, provider) do
      nil -> {:error, {:cli_not_cached, provider}}
      _ -> {:ok, cli_mounts(set, provider) ++ cli_mounts(set, "arb")}
    end
  end

  @doc "`{:error, {:cli_not_cached, name}}` unless the set has `name`."
  @spec require_cli(t(), String.t()) :: :ok | {:error, {:cli_not_cached, String.t()}}
  def require_cli(%__MODULE__{} = set, name),
    do: if(cli(set, name), do: :ok, else: {:error, {:cli_not_cached, name}})

  @doc """
  Every `arbiter.*` image label of the set: `arbiter.cli-set`,
  `arbiter.cli-providers` and, per CLI, `arbiter.cli.<name>.version`,
  `.integrity` (the upstream checksum it was verified against), `.sha256` (the
  content digest of its files) and `.source`.
  """
  @spec labels(t()) :: [{String.t(), String.t()}]
  def labels(%__MODULE__{} = set) do
    [
      {"#{@label}.cli-set", set.set8},
      {"#{@label}.cli-providers", Enum.join(providers(set), ",")}
    ] ++
      Enum.flat_map(set.clis, fn cli ->
        prefix = "#{@label}.cli.#{cli.name}"

        [
          {prefix <> ".version", cli.version},
          {prefix <> ".integrity", cli.integrity},
          {prefix <> ".sha256", cli.digest},
          {prefix <> ".source", cli.source}
        ]
      end)
  end

  @doc "The manifest written beside a materialized set."
  @spec manifest(t()) :: map()
  def manifest(%__MODULE__{} = set) do
    %{
      "set" => set.hash,
      "set8" => set.set8,
      "platform" => set.platform,
      "providers" => providers(set),
      "clis" =>
        for cli <- set.clis do
          %{
            "name" => cli.name,
            "version" => cli.version,
            "integrity" => cli.integrity,
            "source" => cli.source,
            "digest" => cli.digest,
            "files" =>
              for f <- cli.files do
                %{"path" => f.name, "sha256" => f.sha256, "size" => f.size, "mode" => f.mode}
              end
          }
        end
    }
  end

  # -- materializing -----------------------------------------------------------

  @doc """
  Copy the set to `<sets root>/<set8>/<cli>/<file>` with the right modes, write
  `manifest.json`, and return the set with each file's `:path` and the set's
  `:dir`. Idempotent: a file already there with the right size and mode is kept.
  `verify: true` re-hashes the cache's objects and the copies (the publisher
  does; a spawn does not hash 300 MB).
  """
  @spec materialize(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def materialize(set, opts \\ [])

  def materialize(%__MODULE__{dir: dir} = set, opts) when is_binary(dir) do
    if Keyword.get(opts, :verify, false), do: do_materialize(set, opts), else: {:ok, set}
  end

  def materialize(%__MODULE__{} = set, opts), do: do_materialize(set, opts)

  defp do_materialize(set, opts) do
    verify? = Keyword.get(opts, :verify, false)
    dir = Path.join(set.root, set.set8)

    with :ok <- verify_sources(set, verify?),
         {:ok, clis} <- place(set.clis, dir, verify?),
         set = %{set | dir: dir, clis: clis},
         :ok <- write_manifest(set, dir) do
      {:ok, set}
    end
  end

  defp verify_sources(_set, false), do: :ok

  defp verify_sources(set, true) do
    set.clis
    |> Enum.flat_map(fn cli -> for %{source: {:cache, entry, _}} <- cli.files, do: entry end)
    |> Enum.uniq_by(&{&1.name, &1.version})
    |> Enum.find_value(:ok, fn entry ->
      case Cache.verify(entry) do
        :ok -> nil
        {:error, reason} -> {:error, {:cli_cache_corrupt, entry.name, reason}}
      end
    end)
  end

  defp place(clis, dir, verify?) do
    Enum.reduce_while(clis, {:ok, []}, fn cli, {:ok, acc} ->
      case place_files(cli.files, Path.join(dir, cli.name), verify?) do
        {:ok, files} -> {:cont, {:ok, [%{cli | files: files} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, clis} -> {:ok, Enum.reverse(clis)}
      error -> error
    end
  end

  defp place_files(files, dir, verify?) do
    File.mkdir_p!(dir)

    {:ok,
     Enum.map(files, fn f ->
       target = Path.join(dir, f.name)
       :ok = put_file(f, target, verify?)
       %{f | path: target}
     end)}
  rescue
    e in [File.Error, File.CopyError, File.RenameError] ->
      {:error, {:cli_set_unwritable, dir, Exception.message(e)}}
  end

  defp put_file(f, target, verify?) do
    if current?(target, f, verify?) do
      :ok
    else
      tmp = target <> ".tmp#{System.unique_integer([:positive])}"

      case f.source do
        {:cache, entry, rel} -> File.cp!(Cache.object_path(entry, rel), tmp)
        {:launcher, text} -> File.write!(tmp, text)
      end

      File.chmod!(tmp, f.mode)
      File.rename!(tmp, target)
      :ok
    end
  end

  defp current?(target, f, verify?) do
    case File.stat(target) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} ->
        size == f.size and Bitwise.band(mode, 0o777) == f.mode and
          (not verify? or Integrity.sha256_file(target) == f.sha256)

      _ ->
        false
    end
  end

  defp write_manifest(set, dir) do
    path = Path.join(dir, "manifest.json")
    tmp = path <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, Jason.encode!(manifest(set)))
    File.rename!(tmp, path)
    :ok
  rescue
    e in [File.Error, File.RenameError] ->
      {:error, {:cli_set_unwritable, dir, Exception.message(e)}}
  end
end
