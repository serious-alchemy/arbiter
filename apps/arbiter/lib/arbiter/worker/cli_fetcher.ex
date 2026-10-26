defmodule Arbiter.Worker.CliFetcher do
  @moduledoc """
  The CLI bytes a published worker image carries come from UPSTREAM at pinned
  versions, not from the primary's installed CLIs (OD13,
  `docs/design/remote-workers.md` §21.2.3; SI1a).

    * **claude** and **codex** are fetched from the npm registry at the version
      pinned in `worker.cli.versions`: claude's platform package
      (`@anthropic-ai/claude-code-linux-<arch>`, the `claude` ELF), and codex's
      vendored platform build (`@openai/codex@<version>-linux-<arch>`: `codex`,
      `codex-code-mode-host`, `rg`, `bwrap`). Codex's voice host
      (`codex-resources/voice/`, tens of MB workers never run) is left out.
    * **arb** is pinned to the running Arbiter release's own `arb` GitHub release
      asset (`Arbiter.Version.app_version/0` at `Arbiter.Version.release_repo/0`).

  Every download is verified before a byte enters the cache: the npm
  `dist.integrity` (SRI sha512) or the release's `arb.sha256`. A mismatch, a
  missing integrity value, a tarball URL on another host and an unsafe archive
  path are all refused (`ensure/3` returns `{:error, reason}` and caches
  nothing). Verified files land in `Arbiter.Worker.CliFetcher.Cache`, a
  content-addressed store under `<image root>/cli-cache`.

  ## No network at run time

  `fetch/3`, `ensure/3`, `latest/2` and `Arbiter.Worker.CliFetcher.Bump` reach
  the network (through `Arbiter.Worker.CliFetcher.Upstream`, the only module that
  can) and are driven only by `Arbiter.Worker.CliFetcher.Scheduler`, the daily
  bump and the publisher's explicit refresh. A dispatch, a spawn or a run reads
  `Arbiter.Worker.CliFetcher.Cache.lookup/3` and nothing else; a pin whose bytes
  are not cached yet is a miss, never a download. `CliFetcherNoRuntimeFetchTest`
  enforces that no module outside this namespace can name `Upstream`.

  ## Options

  `:root` (cache root), `:platform` (`linux-x64` / `linux-arm64`, default the
  host's), `:registry`, `:github_api`, `:release_repo`, `:req_options` (the
  `Req` seam the tests use), `:work_dir` (scratch for downloads, default under
  `Arbiter.Config.Paths.scratch_root/0`).
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.CliFetcher.Cache
  alias Arbiter.Worker.CliFetcher.Integrity
  alias Arbiter.Worker.CliFetcher.Semver
  alias Arbiter.Worker.CliFetcher.Tarball
  alias Arbiter.Worker.CliFetcher.Upstream

  @npm_clis ~w(claude codex)
  @names @npm_clis ++ ["arb"]
  @codex_triples %{
    "linux-x64" => "x86_64-unknown-linux-musl",
    "linux-arm64" => "aarch64-unknown-linux-musl"
  }
  @claude_packages %{
    "claude" => "@anthropic-ai/claude-code",
    "codex" => "@openai/codex"
  }
  # Codex ships its voice host (gstreamer, opus, glib, ...) under this prefix.
  @codex_excluded ["codex-resources/voice/"]

  @type entry :: Cache.entry()

  @doc "Every CLI the fetcher carries."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The CLIs whose version is pinned in `worker.cli.versions` (arb follows the release)."
  @spec pinned_names() :: [String.t()]
  def pinned_names, do: @npm_clis

  @doc """
  The version pinned for `name`: `worker.cli.versions` for claude and codex, the
  running release for arb. `nil` when nothing is pinned.
  """
  @spec pin(String.t(), keyword()) :: String.t() | nil
  def pin(name, opts \\ [])

  def pin("arb", opts) do
    version = Keyword.get_lazy(opts, :arb_version, &Arbiter.Version.app_version/0)
    if Semver.stable?(version), do: version
  end

  def pin(name, opts) when name in @npm_clis do
    pins = Keyword.get_lazy(opts, :pins, fn -> Arbiter.Settings.worker_cli_versions() || %{} end)
    Map.get(pins, name)
  end

  @doc """
  Make sure `name` at `version` is in the cache: a hit returns at once with no
  network; a miss fetches, verifies and stores it. Returns the cache entry.
  """
  @spec ensure(String.t(), String.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def ensure(name, version, opts \\ []) do
    with :ok <- check(name, version) do
      case Cache.lookup(name, version, opts) do
        {:ok, entry} -> {:ok, entry}
        :error -> fetch(name, version, opts)
      end
    end
  end

  @doc "Ensure every pinned CLI (and arb) is cached; `%{name => {:ok, entry} | {:error, reason} | :unpinned}`."
  @spec ensure_pinned(keyword()) :: %{String.t() => {:ok, entry()} | {:error, term()} | :unpinned}
  def ensure_pinned(opts \\ []) do
    Map.new(@names, fn name ->
      case pin(name, opts) do
        nil -> {name, :unpinned}
        version -> {name, ensure(name, version, opts)}
      end
    end)
  end

  @doc "Fetch `name` at `version` from upstream, verify, and store it. Always touches the network."
  @spec fetch(String.t(), String.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def fetch(name, version, opts \\ []) do
    with :ok <- check(name, version) do
      work = work_dir(opts)

      try do
        File.mkdir_p!(work)
        do_fetch(name, version, work, opts)
      after
        File.rm_rf(work)
      end
    end
  rescue
    e in [File.Error, File.CopyError, File.RenameError] ->
      {:error, {:cache_write, Exception.message(e)}}
  end

  @doc """
  The newest stable upstream version of `name` (claude, codex). The `latest`
  dist-tag when it is a plain `x.y.z`, else the highest plain `x.y.z` in the
  registry's version list; a prerelease or platform variant is never returned.
  """
  @spec latest(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def latest(name, opts \\ [])

  def latest(name, opts) when name in @npm_clis do
    pkg = Map.fetch!(@claude_packages, name)

    with {:ok, tags} <-
           Upstream.get_json(Upstream.registry(opts) <> "/-/package/#{pkg}/dist-tags", opts) do
      case tags["latest"] do
        v when is_binary(v) -> if Semver.stable?(v), do: {:ok, v}, else: newest_listed(pkg, opts)
        _ -> newest_listed(pkg, opts)
      end
    end
  end

  def latest(name, _opts), do: {:error, {:no_upstream_latest, name}}

  defp newest_listed(pkg, opts) do
    headers = [{"accept", "application/vnd.npm.install-v1+json"}]

    with {:ok, doc} <- Upstream.get_json(Upstream.registry(opts) <> "/" <> pkg, opts, headers) do
      case doc |> Map.get("versions", %{}) |> Map.keys() |> Semver.newest_stable() do
        nil -> {:error, {:no_stable_version, pkg}}
        v -> {:ok, v}
      end
    end
  end

  # ---- per-CLI recipes ---------------------------------------------------

  defp check(name, _version) when name not in @names, do: {:error, {:unknown_cli, name}}

  defp check(_name, version),
    do: if(Semver.stable?(version), do: :ok, else: {:error, {:bad_version, version}})

  defp do_fetch("claude", version, work, opts) do
    platform = Cache.platform(opts)
    pkg = Map.fetch!(@claude_packages, "claude")
    platform_pkg = "#{pkg}-#{platform}"

    with {:ok, main} <- Upstream.npm_json("#{pkg}/#{version}", opts),
         {:ok, pversion} <- optional_dependency(main, platform_pkg),
         {:ok, doc} <- Upstream.npm_json("#{platform_pkg}/#{pversion}", opts),
         :ok <- same_version(doc, pversion) do
      npm_tarball("claude", version, doc, work, opts, "claude", fn
        "package/claude" -> {:keep, "claude"}
        _ -> :skip
      end)
    end
  end

  defp do_fetch("codex", version, work, opts) do
    platform = Cache.platform(opts)

    with {:ok, triple} <-
           Map.fetch(@codex_triples, platform) |> or_error({:unsupported_platform, platform}),
         pversion = "#{version}-#{platform}",
         {:ok, doc} <- Upstream.npm_json("@openai/codex/#{pversion}", opts),
         :ok <- same_version(doc, pversion) do
      prefix = "package/vendor/#{triple}/"

      npm_tarball("codex", version, doc, work, opts, "bin/codex", fn name ->
        with true <- String.starts_with?(name, prefix),
             rel = String.replace_prefix(name, prefix, ""),
             false <- Enum.any?(@codex_excluded, &String.starts_with?(rel, &1)) do
          {:keep, rel}
        else
          _ -> :skip
        end
      end)
    end
  end

  defp do_fetch("arb", version, work, opts) do
    with {:ok, repo} <- release_repo(opts),
         {:ok, release} <- github_release(repo, version, opts),
         {:ok, arb_url} <- asset(release, "arb"),
         {:ok, sha_url} <- asset(release, "arb.sha256"),
         headers = Upstream.github_headers(),
         bin = Path.join(work, "arb"),
         sidecar = Path.join(work, "arb.sha256"),
         :ok <- Upstream.download(arb_url, bin, opts, headers),
         :ok <- Upstream.download(sha_url, sidecar, opts, headers),
         {:ok, hex} <- Integrity.parse_sidecar(File.read!(sidecar)) |> or_error(:bad_integrity),
         :ok <- Integrity.verify_sha256(bin, hex) do
      staged = Path.join(work, "staged")
      File.mkdir_p!(staged)
      File.rename!(bin, Path.join(staged, "arb"))

      Cache.put(
        "arb",
        version,
        staged,
        [{"arb", 0o755}],
        %{source: arb_url, integrity: "sha256-" <> hex, main: "arb"},
        opts
      )
    end
  end

  defp npm_tarball(name, version, doc, work, opts, main, select) do
    dist = Map.get(doc, "dist", %{})
    url = dist["tarball"]
    integrity = dist["integrity"]
    tgz = Path.join(work, "package.tgz")
    dest = Path.join(work, "extract")

    with :ok <- require_integrity(integrity),
         :ok <- tarball_host(url, opts),
         :ok <- Upstream.download(url, tgz, opts),
         :ok <- Integrity.verify_sri(tgz, integrity),
         {:ok, members} <- Tarball.extract(tgz, dest, select),
         :ok <- require_main(members, main) do
      Cache.put(
        name,
        version,
        Tarball.staged_dir(dest),
        members,
        %{source: url, integrity: integrity, main: main},
        opts
      )
    end
  end

  # A package without an SRI value is refused before anything is downloaded.
  defp require_integrity(sri) when is_binary(sri) and sri != "", do: :ok
  defp require_integrity(_), do: {:error, :no_integrity}

  # The tarball must come from the registry host the document came from; the
  # integrity check makes the URL non-authoritative, this keeps a poisoned
  # document from steering the primary at an arbitrary server.
  defp tarball_host(url, opts) when is_binary(url) do
    registry_host = opts |> Upstream.registry() |> URI.parse() |> Map.get(:host)

    case URI.parse(url) do
      %URI{scheme: "https", host: ^registry_host} -> :ok
      %URI{host: host} -> {:error, {:untrusted_tarball_host, host}}
    end
  end

  defp tarball_host(_, _), do: {:error, :no_tarball}

  defp require_main(members, main) do
    if Enum.any?(members, fn {rel, _mode} -> rel == main end),
      do: :ok,
      else: {:error, {:missing_file, main}}
  end

  defp optional_dependency(doc, platform_pkg) do
    case get_in(doc, ["optionalDependencies", platform_pkg]) do
      v when is_binary(v) ->
        if Semver.stable?(v), do: {:ok, v}, else: {:error, {:bad_version, v}}

      _ ->
        {:error, {:no_platform_package, platform_pkg}}
    end
  end

  defp same_version(%{"version" => version}, version), do: :ok
  defp same_version(doc, version), do: {:error, {:version_mismatch, version, doc["version"]}}

  defp release_repo(opts) do
    case Keyword.get_lazy(opts, :release_repo, &Arbiter.Version.release_repo/0) do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _ -> {:error, :no_release_repo}
    end
  end

  defp github_release(repo, version, opts) do
    base = Upstream.github_api(opts) <> "/repos/" <> repo <> "/releases/tags/"
    headers = Upstream.github_headers()

    case Upstream.get_json(base <> "v" <> version, opts, headers) do
      {:error, {:not_found, _}} -> Upstream.get_json(base <> version, opts, headers)
      other -> other
    end
  end

  defp asset(%{"assets" => assets}, name) when is_list(assets) do
    Enum.find_value(assets, {:error, {:no_asset, name}}, fn
      %{"name" => ^name, "browser_download_url" => url} when is_binary(url) -> {:ok, url}
      _ -> nil
    end)
  end

  defp asset(_, name), do: {:error, {:no_asset, name}}

  defp or_error({:ok, _} = ok, _reason), do: ok
  defp or_error(:error, reason), do: {:error, reason}

  defp work_dir(opts) do
    base = Keyword.get_lazy(opts, :work_dir, fn -> Paths.scratch_root() end)
    Path.join(base, "cli-fetch-#{System.unique_integer([:positive])}")
  end
end
