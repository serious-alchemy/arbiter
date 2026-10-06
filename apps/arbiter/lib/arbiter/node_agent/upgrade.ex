defmodule Arbiter.NodeAgent.Upgrade do
  @moduledoc """
  Self-upgrade on version skew (`docs/design/remote-workers.md` §6). The agent is
  the release tarball the primary runs, so a primary redeploy leaves every node
  `outdated`; the primary's `hello_ok` then carries `upgrade{version, sha256}`.

  Three steps, each its own function so each is testable and none touches the
  running release:

    1. `prepare/2` — `GET /nodes/agent/<version>.tar.gz` with the node
       credential into `<node_home>/releases/<version>.tar.gz.part`, verify the
       sha256 (a mismatch deletes the file and refuses), unpack into a staging
       dir, check it is a release (`bin/arbiter`), and rename it to
       `releases/<version>/`. An already-unpacked release is not fetched again.
    2. `commit/2` — wait until the node has no live runs, write
       `upgrade.pending`, atomically repoint `<node_home>/current` (a temp
       symlink renamed over it, so a reader sees the old target or the new one,
       never neither) and stop the VM; systemd (`Restart=always`) starts the new
       release through the same `current` path.
    3. `confirm/1` — the **new** agent, after its first `hello_ok`, writes
       `confirmed` and clears `upgrade.pending`, and prunes all but the running
       release and its predecessor. If it never gets that far, the unit's
       `ExecStartPre` (`arbiter-node pre-start`) points `current` back at `from`
       once `upgrade.pending` is older than three minutes.

  `upgrade.pending` is plain `key=value` lines (`from=`, `to=`, `at=<epoch s>`)
  so that shell can read it.
  """

  alias Arbiter.NodeAgent.Config

  require Logger

  # A version becomes a directory name; nothing that can climb or hide.
  @version_re ~r/\A[0-9A-Za-z][0-9A-Za-z._+-]{0,63}\z/
  @sha_re ~r/\A[0-9a-f]{64}\z/

  @type spec :: %{required(String.t()) => String.t()}

  @doc """
  Download, verify and unpack `spec`: the `upgrade` map of a `hello_ok`, with
  string keys `version` and `sha256` (hex).
  """
  @spec prepare(Config.t(), spec()) :: {:ok, Path.t()} | {:error, term()}
  def prepare(%Config{} = config, %{"version" => version, "sha256" => sha}) do
    with :ok <- check_version(version),
         :ok <- check_sha(sha) do
      target = release_dir(config, version)

      if release?(target) do
        {:ok, target}
      else
        download_and_unpack(config, version, String.downcase(sha), target)
      end
    end
  end

  def prepare(_config, spec), do: {:error, {:bad_spec, spec}}

  @doc """
  Flip `current` to the prepared `version` and stop the VM, once the node is
  idle. Blocks while runs are live (polling every `idle_poll_ms`).
  """
  @spec commit(Config.t(), String.t()) :: :ok | {:error, term()}
  def commit(%Config{} = config, version) do
    with :ok <- check_version(version),
         true <- release?(release_dir(config, version)) || {:error, :not_prepared} do
      wait_idle(config)
      from = read_current(config)

      with :ok <- File.write(pending_path(config), pending_body(from, version)),
           :ok <- swap_current(config, "releases/#{version}") do
        Logger.info("node agent upgrading #{config.version} -> #{version}; restarting")
        halt(config)
        :ok
      end
    end
  end

  @doc """
  Called after the first `hello_ok`: `:confirmed` when an upgrade to the running
  version was pending (and now is not), `:none` otherwise.
  """
  @spec confirm(Config.t()) :: :confirmed | :none
  def confirm(%Config{} = config) do
    with {:ok, body} <- File.read(pending_path(config)),
         %{"to" => to} = pending <- parse_pending(body),
         true <- to == config.version do
      File.write!(Path.join(config.node_home, "confirmed"), "#{to} #{System.os_time(:second)}\n")
      File.rm(pending_path(config))
      prune(config, [to, Path.basename(Map.get(pending, "from", ""))])
      :confirmed
    else
      _ -> :none
    end
  end

  # -- download + unpack ----------------------------------------------------------

  defp download_and_unpack(config, version, sha, target) do
    releases = Path.join(config.node_home, "releases")
    part = Path.join(releases, "#{version}.tar.gz.part")
    staging = Path.join(releases, ".#{version}.staging")

    File.mkdir_p!(releases)

    result =
      with :ok <- download(config, version, part),
           :ok <- verify_sha(part, sha),
           :ok <- unpack(part, staging),
           {:ok, root} <- release_root(staging),
           :ok <- File.rename(root, target) do
        {:ok, target}
      end

    File.rm(part)
    File.rm_rf(staging)
    result
  end

  defp download(config, version, part) do
    url = Config.http_url(config, "/nodes/agent/#{version}.tar.gz")

    request =
      Req.new(
        [
          url: url,
          headers: [{"authorization", "Bearer " <> config.credential}],
          decode_body: false,
          into: File.stream!(part),
          receive_timeout: 120_000
        ] ++ (config.req_options || [])
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, {:download_failed, reason}}
    end
  end

  defp verify_sha(path, expected) do
    actual =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(actual, expected), do: :ok, else: {:error, :sha256_mismatch}
  end

  # Names are checked from the table first: an absolute path or a `..` segment
  # never reaches the extractor.
  defp unpack(archive, staging) do
    File.rm_rf!(staging)
    File.mkdir_p!(staging)
    archive = String.to_charlist(archive)

    with {:ok, names} <- :erl_tar.table(archive, [:compressed]),
         :ok <- safe_names(names),
         :ok <- :erl_tar.extract(archive, [:compressed, {:cwd, String.to_charlist(staging)}]) do
      :ok
    else
      {:error, reason} -> {:error, {:unpack_failed, reason}}
    end
  end

  defp safe_names(names) do
    unsafe =
      Enum.find(names, fn name ->
        name = to_string(name)
        Path.type(name) != :relative or ".." in Path.split(name)
      end)

    if unsafe, do: {:error, {:unsafe_path, to_string(unsafe)}}, else: :ok
  end

  # The published tarball has one top-level `arbiter/` dir; a flat one is fine too.
  defp release_root(staging) do
    root =
      case File.ls!(staging) do
        [single] -> if File.dir?(Path.join(staging, single)), do: Path.join(staging, single)
        _ -> nil
      end

    cond do
      File.regular?(Path.join(staging, "bin/arbiter")) -> {:ok, staging}
      root && File.regular?(Path.join(root, "bin/arbiter")) -> {:ok, root}
      true -> {:error, :not_a_release}
    end
  end

  # -- commit ---------------------------------------------------------------------

  defp wait_idle(config) do
    if live_runs(config) == [] do
      :ok
    else
      Process.sleep(config.idle_poll_ms)
      wait_idle(config)
    end
  end

  defp live_runs(%Config{live_runs_fun: nil}), do: []
  defp live_runs(%Config{live_runs_fun: fun}), do: fun.()

  defp halt(%Config{halt_fun: nil}), do: System.stop(0)
  defp halt(%Config{halt_fun: fun}), do: fun.()

  # Temp symlink, then rename(2) over `current`: atomic on POSIX.
  defp swap_current(config, relative_target) do
    link = current_path(config)
    tmp = link <> ".new." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.ln_s(relative_target, tmp),
         :ok <- File.rename(tmp, link) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:symlink_swap_failed, reason}}
    end
  end

  defp read_current(config) do
    case File.read_link(current_path(config)) do
      {:ok, target} -> target
      {:error, _} -> ""
    end
  end

  defp pending_body(from, to), do: "from=#{from}\nto=#{to}\nat=#{System.os_time(:second)}\n"

  defp parse_pending(body) do
    for line <- String.split(body, "\n", trim: true),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {key, value}
  end

  # Keep the running release and its predecessor (§6 step 4: two retained).
  defp prune(config, keep) do
    releases = Path.join(config.node_home, "releases")

    for entry <- File.ls(releases) |> elem(1),
        entry not in keep,
        not String.starts_with?(entry, ".") do
      File.rm_rf(Path.join(releases, entry))
    end

    :ok
  end

  # -- paths + checks ---------------------------------------------------------------

  defp release_dir(config, version), do: Path.join([config.node_home, "releases", version])
  defp current_path(config), do: Path.join(config.node_home, "current")
  defp pending_path(config), do: Path.join(config.node_home, "upgrade.pending")
  defp release?(dir), do: File.regular?(Path.join(dir, "bin/arbiter"))

  defp check_version(version) when is_binary(version) do
    if Regex.match?(@version_re, version) and ".." not in String.split(version, "/"),
      do: :ok,
      else: {:error, {:bad_version, version}}
  end

  defp check_version(version), do: {:error, {:bad_version, version}}

  defp check_sha(sha) when is_binary(sha) do
    if Regex.match?(@sha_re, String.downcase(sha)), do: :ok, else: {:error, :bad_sha256}
  end

  defp check_sha(_), do: {:error, :bad_sha256}
end
