defmodule ArbiterCli.Cmd.SelfUpdate do
  @moduledoc """
  `arb self-update [--version vX.Y.Z] [--json] [--force]`
  — refresh the local `arb` CLI escript from a **GitHub Release**.

  Downloads the `arb` escript asset published by `.github/workflows/release.yml`,
  verifies its SHA-256 checksum, backs up the existing binary, and atomically
  swaps in the new one.

  This is the production CLI-update path: the machine no longer needs a source
  checkout or a Mix/Elixir toolchain to stay current. It mirrors
  `arb server deploy` — download a released artifact, verify, swap — so CLI
  and server self-maintain the same way.

  ## What it does

    1. **Resolve the target release.** Query the GitHub Releases API for
       `latest` (or the tag named by `--version`). The `owner/repo` comes from
       `ARB_RELEASE_REPO`; a `GITHUB_TOKEN`, if set, authenticates the request.
    2. **No-op if already current.** Compare the running escript's version
       against the release tag. Skips the download unless `--force` is passed.
    3. **Download the asset + checksum.** Fetch the `arb` escript asset and its
       `arb.sha256` sidecar from the release.
    4. **Verify sha256.** Recompute the download's SHA-256 and compare to the
       published checksum. A mismatch aborts before anything touches disk state.
    5. **Atomic swap.** Back up the existing binary to `<install_path>.bak`,
       write the new binary to a temp file, `chmod +x`, then rename it over the
       existing path (rename(2) is atomic on POSIX).

  ## Configuration

    * `ARB_RELEASE_REPO` — `owner/repo` to pull releases from (required).
    * `GITHUB_TOKEN` — optional; authenticates the Releases API request.
    * `ARB_INSTALL_BIN` — install path (default `~/.local/bin/arb`).
    * `ARB_GITHUB_API` — Releases API base (default `https://api.github.com`).

  ## Exit codes

    * `0` — the CLI was updated (or was already on the target version).
    * `1` — a precondition failed (missing config, API/download error, checksum
      mismatch, write failure).
  """

  alias ArbiterCli.{ArgParser, Output, ReleaseRepo}

  @default_github_api "https://api.github.com"
  @switches [version: :string, json: :boolean, force: :boolean]

  @doc "Entry point for `arb self-update` (and its `arb upgrade` alias)."
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_self_update(argv)
    end
  end

  defp do_self_update(argv) do
    {opts, _rest, mode} = ArgParser.parse(argv, command: "arb self-update", strict: @switches)
    force = opts[:force] || false

    try do
      repo = release_repo()
      release = fetch_release(repo, opts[:version])
      tag = release_tag(release)

      case install(release, repo, tag, force) do
        {:already_current, _} -> emit_already_current(mode, tag)
        {:updated, prior} -> emit_updated(mode, tag, prior)
      end
    catch
      {:self_update_failed, msg, nil} -> Output.die(msg)
      {:self_update_failed, msg, hint} -> Output.die(msg, hint)
    end
  end

  @doc """
  Install the `arb` escript from an already-fetched release (`repo`/`tag`) —
  the half of `arb self-update` that `arb server deploy` runs after a green
  deploy so the CLI matches the server it just put live.

  Never halts the VM: a failure comes back as `{:error, message}` because the
  caller's own work (a healthy server deploy) is already done. Quiet on stdout
  so a `--json` deploy stays one object.
  """
  @spec install_from_release(String.t(), map(), String.t()) ::
          {:ok, %{updated: boolean(), version: String.t(), previous_version: String.t() | nil}}
          | {:error, String.t()}
  def install_from_release(repo, release, tag) do
    Process.put(:arb_self_update_quiet, true)

    try do
      case install(release, repo, tag, true) do
        {:updated, prior} ->
          {:ok,
           %{updated: true, version: tag, previous_version: prior, install_path: install_path()}}

        {:already_current, _} ->
          {:ok, %{updated: false, version: tag, previous_version: nil}}
      end
    catch
      {:self_update_failed, msg, _hint} -> {:error, msg}
    after
      Process.delete(:arb_self_update_quiet)
    end
  end

  defp install(release, repo, tag, force) do
    # Strip the leading `v` from the tag before comparing with the app version
    # (the app version is stored without the prefix, e.g. "0.1.10").
    tag_version = String.trim_leading(tag, "v")
    current_version = ArbiterCli.Version.app_version()

    if not force and tag_version == current_version do
      {:already_current, current_version}
    else
      {arb_url, sha_url} = cli_assets(release, tag)

      log("Downloading arb escript from #{repo}@#{tag}…")
      arb_bytes = download_binary(arb_url)
      expected_sha = parse_sha256(download_binary(sha_url))

      verify_sha256!(arb_bytes, expected_sha)
      log("Checksum verified (sha256 #{String.slice(expected_sha, 0, 12)}…).")

      atomic_swap!(install_path(), arb_bytes)
      {:updated, current_version}
    end
  end

  # Every failure inside the install path throws, so `arb self-update` can turn
  # it into a halt and `install_from_release/3` into an `{:error, _}`.
  defp fail(msg, hint \\ nil), do: throw({:self_update_failed, msg, hint})

  # ---- release resolution --------------------------------------------------

  defp release_repo do
    case ReleaseRepo.resolve() do
      {:ok, repo, source} ->
        IO.puts(:stderr, "Release source: #{repo} (#{ReleaseRepo.describe(source)}).")
        repo

      :error ->
        fail(
          "could not determine which GitHub repo publishes Arbiter releases",
          "Set ARB_RELEASE_REPO=owner/repo, or use a release-built arb (it carries its own repo)."
        )
    end
  end

  defp fetch_release(repo, nil), do: github_get!(repo, "releases/latest", "latest")
  defp fetch_release(repo, tag), do: github_get!(repo, "releases/tags/#{tag}", tag)

  defp github_get!(repo, path, what) do
    url = github_api() <> "/repos/" <> repo <> "/" <> path

    req_opts =
      [
        method: :get,
        url: url,
        headers: github_headers(),
        receive_timeout: 30_000,
        retry: false
      ] ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: 404}} ->
        fail(
          "no #{what} release found in #{repo}",
          "Check `--version` matches a published tag, or publish a release first."
        )

      {:ok, %Req.Response{status: status}} ->
        fail("GitHub Releases API returned HTTP #{status} for #{url}")

      {:error, reason} ->
        fail(
          "could not reach the GitHub Releases API",
          "Requesting #{url} failed: #{inspect(reason)}"
        )
    end
  end

  defp release_tag(%{"tag_name" => tag}) when is_binary(tag) and tag != "", do: tag

  defp release_tag(_),
    do: fail("release metadata has no tag_name", "The Releases API response was malformed.")

  # Locate the `arb` escript asset and its `arb.sha256` sidecar.
  defp cli_assets(%{"assets" => assets}, tag) when is_list(assets) do
    arb_url = asset_url(assets, "arb")
    sha_url = asset_url(assets, "arb.sha256")

    cond do
      is_nil(arb_url) ->
        fail(
          "release #{tag} has no asset named `arb`",
          "The release workflow should publish it; re-run the build if it's missing."
        )

      is_nil(sha_url) ->
        fail(
          "release #{tag} has no checksum asset named `arb.sha256`",
          "Refusing to update without a checksum to verify the download against."
        )

      true ->
        {arb_url, sha_url}
    end
  end

  defp cli_assets(_, tag), do: fail("release #{tag} has no assets")

  defp asset_url(assets, name) do
    Enum.find_value(assets, fn
      %{"name" => ^name, "browser_download_url" => url} when is_binary(url) -> url
      _ -> nil
    end)
  end

  # ---- download + verify ---------------------------------------------------

  defp download_binary(url) do
    req_opts =
      [
        method: :get,
        url: url,
        headers: github_headers(),
        decode_body: false,
        raw: true,
        receive_timeout: 120_000,
        retry: false
      ] ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: status}} ->
        fail("download failed: HTTP #{status} for #{url}")

      {:error, reason} ->
        fail("download failed for #{url}", inspect(reason))
    end
  end

  defp parse_sha256(contents) do
    contents
    |> to_string()
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      hex when is_binary(hex) and hex != "" -> String.downcase(hex)
      _ -> fail("could not parse the published sha256 checksum")
    end
  end

  defp verify_sha256!(bytes, expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    unless actual == expected do
      fail(
        "sha256 checksum mismatch — refusing to update",
        "expected #{expected}\n             got #{actual}\n" <>
          "The download is corrupt or tampered with. Aborting before touching the binary."
      )
    end
  end

  # ---- atomic swap ---------------------------------------------------------

  defp atomic_swap!(install_path, bytes) do
    install_dir = Path.dirname(install_path)

    case File.mkdir_p(install_dir) do
      :ok -> :ok
      {:error, reason} -> fail("could not create #{install_dir}: #{inspect(reason)}")
    end

    # Back up the existing binary so the user can roll back manually.
    if File.exists?(install_path) do
      bak = install_path <> ".bak"

      case File.copy(install_path, bak) do
        {:ok, _} -> log("Backed up existing binary to #{bak}")
        {:error, reason} -> fail("could not back up #{install_path}: #{inspect(reason)}")
      end
    end

    # Write to a temp file alongside the target, then rename(2) over it.
    tmp = install_path <> ".new"
    _ = File.rm(tmp)

    with :ok <- File.write(tmp, bytes),
         :ok <- File.chmod(tmp, 0o755),
         :ok <- File.rename(tmp, install_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        fail("failed to install arb to #{install_path}", inspect(reason))
    end
  end

  # ---- paths / config ------------------------------------------------------

  defp install_path do
    case System.get_env("ARB_INSTALL_BIN") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(System.user_home!(), ".local/bin/arb")
    end
  end

  defp github_api do
    case System.get_env("ARB_GITHUB_API") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @default_github_api
    end
  end

  defp github_headers do
    base = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"} | base]

      _ ->
        base
    end
  end

  defp test_opts, do: Process.get(:bd2_req_options, [])

  defp log(msg) do
    cond do
      Process.get(:bd2_req_options) -> :ok
      Process.get(:arb_self_update_quiet) -> IO.puts(:stderr, msg)
      true -> IO.puts(msg)
    end
  end

  # ---- output --------------------------------------------------------------

  defp emit_already_current(:json, tag) do
    IO.puts(
      Jason.encode!(%{
        version: tag,
        updated: false,
        already_current: true,
        ok: true
      })
    )
  end

  defp emit_already_current(:text, tag) do
    IO.puts("Already on #{tag} — nothing to update.")
    IO.puts("(Pass --force to reinstall the same version, or --version to pick another.)")
  end

  defp emit_updated(:json, tag, prior_version) do
    install = install_path()

    IO.puts(
      Jason.encode!(%{
        version: tag,
        previous_version: prior_version,
        updated: true,
        already_current: false,
        install_path: install,
        ok: true
      })
    )
  end

  defp emit_updated(:text, tag, prior_version) do
    install = install_path()
    IO.puts("")
    IO.puts("Updated arb to #{tag}" <> if(prior_version, do: " (was #{prior_version})", else: ""))
    IO.puts("Installed at #{install}")
    IO.puts("")
    IO.puts("Run `arb version` to confirm the new version is active.")
  end
end
