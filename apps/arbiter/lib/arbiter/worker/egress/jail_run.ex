defmodule Arbiter.Worker.Egress.JailRun do
  @moduledoc """
  Builds and starts the egress side of one jailed run (bd-cfktou, G6;
  `docs/design/guardrail-profiles.md` §4.4) and hands the jail what it needs:
  `start/1` returns the `:network` option for `Arbiter.Worker.Jail.wrap/2`.

  One `Arbiter.Worker.Egress` run per owner (the worker), made of

    * the filtering proxy, whose baseline is the adapter's infra hosts plus the
      host of every git remote the worktree has (the ticket's remote), so a
      push and the model API work and nothing else is granted by default;
    * a bridge to Arbiter's own endpoint, on the same loopback port inside the
      namespace as outside it, so `arb` and the MCP URL work unchanged;
    * a bridge per fixed-destination tunnel, `{local_port, host, port}`.

  The run lives and dies with `:owner`. Its id is derived from the owner, so a
  later spawn for the same worker (a resume, a nudge) finds the run already
  there and reuses it, and the sockets named in an earlier argv stay valid.

  Every failure is returned. The caller must refuse the spawn on `{:error, _}`:
  a jail that cannot get its proxy must not fall back to the shared network.
  """

  alias Arbiter.Worker.Egress

  @loopback_hosts ["127.0.0.1", "localhost", "::1", "[::1]"]

  @type tunnel :: {:inet.port_number(), String.t(), :inet.port_number()}

  @doc """
  Starts (or finds) the run for `:owner` and returns `{:ok, network, run_id}`.

  Options: `:owner` (default `self()`), `:worktree` (its git remotes),
  `:infra` (`host:port` entries), `:tunnels`, `:enforce` (default `false`:
  learn mode, see the note on `Arbiter.Worker.Egress`), `:task_id`,
  `:grants`, `:safe_defaults_exclude`, `:dir`, `:arbiter_url` (default
  `Arbiter.MCP.server_url/0`), `:allow_local_dial`.
  """
  @spec start(keyword()) :: {:ok, keyword(), String.t()} | {:error, term()}
  def start(opts) do
    owner = Keyword.get(opts, :owner) || self()
    dir = Keyword.get(opts, :dir) || Egress.socket_dir()
    run_id = run_id(owner)
    tunnels = Keyword.get(opts, :tunnels, [])
    url = Keyword.get(opts, :arbiter_url) || Arbiter.MCP.server_url()

    with {:ok, arb_port} <- arbiter_endpoint(url) do
      # {bridge name, loopback port inside the jail, host target}
      specs =
        [{:arb, arb_port, {"127.0.0.1", arb_port}}] ++
          (tunnels
           |> Enum.with_index(1)
           |> Enum.map(fn {{local, host, port}, i} -> {:"t#{i}", local, {host, port}} end))

      start_opts =
        [
          dir: dir,
          owner: owner,
          bridges: Enum.map(specs, fn {name, _local, target} -> {name, target} end),
          baseline: baseline(Keyword.get(opts, :worktree), Keyword.get(opts, :infra, [])),
          enforce: Keyword.get(opts, :enforce, false)
        ] ++
          Keyword.take(opts, [:task_id, :grants, :safe_defaults_exclude, :allow_local_dial])

      network = fn ->
        [
          proxy_socket: Egress.socket_path(run_id, dir),
          bridges:
            Enum.map(specs, fn {name, local, _} ->
              {local, Egress.bridge_path(run_id, name, dir)}
            end)
        ]
      end

      case Egress.start_run(run_id, start_opts) do
        {:ok, _proxy} -> {:ok, network.(), run_id}
        {:error, :already_running} -> {:ok, network.(), run_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # One short, filename-safe id per owner pid. Deterministic, so the same
  # worker always maps to the same run and the same socket paths.
  defp run_id(owner) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(owner))
    "r" <> Base.encode32(binary_part(hash, 0, 8), case: :lower, padding: false)
  end

  @doc """
  The proxy baseline: `infra` plus `host:port` for each git remote URL
  configured in `worktree`'s repo (`[]` for none or a non-repo).
  """
  @spec baseline(String.t() | nil, [String.t()]) :: [String.t()]
  def baseline(worktree, infra), do: Enum.uniq(infra ++ remote_authorities(worktree))

  defp remote_authorities(worktree) when is_binary(worktree) and worktree != "" do
    case System.cmd(
           "git",
           ["-C", worktree, "config", "--get-regexp", "^remote\\..*\\.(push)?url$"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.split(" ", parts: 2) |> List.last() end)
        |> Enum.map(&remote_authority/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp remote_authorities(_), do: []

  @doc """
  `host:port` of a git remote URL, or `nil` for a local path / `file://` URL.
  Handles `scheme://[user@]host[:port]/path` and the scp form
  `[user@]host:path` (ssh, port 22).
  """
  @spec remote_authority(String.t()) :: String.t() | nil
  def remote_authority(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when is_binary(scheme) and scheme != "" ->
        scheme_authority(scheme, host, port)

      _ ->
        scp_authority(url)
    end
  end

  defp scheme_authority(_scheme, host, _port) when host in [nil, ""], do: nil

  defp scheme_authority(scheme, host, port) do
    default = %{"ssh" => 22, "https" => 443, "http" => 80, "git" => 9418}

    case port || default[scheme] do
      nil -> nil
      p -> "#{host}:#{p}"
    end
  end

  defp scp_authority(url) do
    case Regex.run(~r{\A(?:[^@/:]+@)?([A-Za-z0-9.-]+):(?!//)}, url) do
      [_, host] -> "#{host}:22"
      _ -> nil
    end
  end

  @doc """
  The port to bridge for an Arbiter endpoint URL, only for a loopback one:
  the jailed `arb` and MCP config name `127.0.0.1:<port>`, so that is where the
  in-namespace listener goes. A remote endpoint is `{:error, :not_loopback}`.
  """
  @spec arbiter_bridge(String.t()) :: {:ok, :inet.port_number()} | {:error, :not_loopback}
  def arbiter_bridge(url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when host in @loopback_hosts and is_integer(port) ->
        {:ok, port}

      _ ->
        {:error, :not_loopback}
    end
  end

  defp arbiter_endpoint(url) do
    case arbiter_bridge(url) do
      {:ok, port} -> {:ok, port}
      {:error, reason} -> {:error, {:arbiter_endpoint, reason}}
    end
  end
end
