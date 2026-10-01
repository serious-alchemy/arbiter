defmodule ArbiterCli.Cmd.Doctor.Distribution do
  @moduledoc """
  bd-51m9ba: `arb doctor`'s "erlang distribution is loopback-only" check.

  The release keeps Erlang distribution on so the operator's
  `bin/arbiter rpc`/`remote` work, and anyone holding the cookie who can reach
  epmd and the node's listener runs arbitrary code in the server. So this
  check fails when:

    * epmd (`ERL_EPMD_PORT`, default 4369) listens on anything but loopback;
    * the release node's distribution port (looked up in epmd under the node
      name `arbiter`) listens on anything but loopback; or
    * a release cookie file — the per-install `<data-home>/release.cookie`
      the release's `env.sh` creates, or the current release's
      `releases/COOKIE` — is group- or world-readable.

  Listeners come from `/proc/net/tcp` and `/proc/net/tcp6` on the host the
  CLI runs on, not from the server: it is the host's sockets that matter.
  Where those tables cannot be read (not Linux), the bind half is reported as
  unknown and only the cookie is judged.
  """

  import Bitwise

  alias ArbiterCli.Cmd.Doctor.Checks.Result
  alias ArbiterCli.Cmd.ReleaseDeploy.ReleaseFiles

  @name "erlang distribution is loopback-only"
  @node_name "arbiter"
  @default_epmd_port 4369
  @epmd_timeout_ms 1_000

  @typedoc """
  Probe inputs; every key defaults to the live host. Tests (and `CliCase`,
  through `Process.get(:bd2_distribution_probe)`) override them.

    * `:proc_net` — socket tables to read listeners from.
    * `:epmd_port` — port to ask epmd for its registered names on 127.0.0.1;
      `nil` skips the query.
    * `:epmd_listen_port` — the port whose listeners count as epmd.
    * `:cookie_paths` — cookie files whose mode is checked (absent ones are
      skipped).
  """
  @type opts :: [
          proc_net: [Path.t()],
          epmd_port: :inet.port_number() | nil,
          epmd_listen_port: :inet.port_number(),
          cookie_paths: [Path.t()]
        ]

  @doc "Run the check against the live host, or the `:bd2_distribution_probe` overrides."
  @spec check() :: Result.t()
  def check, do: check(Process.get(:bd2_distribution_probe, []))

  @spec check(opts()) :: Result.t()
  def check(opts) do
    epmd_port = Keyword.get_lazy(opts, :epmd_listen_port, &env_epmd_port/0)
    query_port = Keyword.get(opts, :epmd_port, epmd_port)
    listeners = read_listeners(Keyword.get(opts, :proc_net, ["/proc/net/tcp", "/proc/net/tcp6"]))
    node_port = node_port(query_port)
    cookies = cookie_modes(Keyword.get_lazy(opts, :cookie_paths, &default_cookie_paths/0))

    endpoints =
      [{"epmd", epmd_port}] ++ if(node_port, do: [{@node_name, node_port}], else: [])

    binds = Enum.map(endpoints, fn {label, port} -> {label, port, on_port(listeners, port)} end)

    result(listeners, binds, cookies)
  end

  @doc "The cookie files checked by default for a deploy data home."
  @spec cookie_paths(Path.t()) :: [Path.t()]
  def cookie_paths(data_home) do
    [
      Path.join(data_home, "release.cookie"),
      Path.join([data_home, "current", "releases", "COOKIE"])
    ]
  end

  defp default_cookie_paths, do: cookie_paths(ReleaseFiles.data_home())

  defp env_epmd_port do
    case Integer.parse(System.get_env("ERL_EPMD_PORT") || "") do
      {port, ""} when port in 1..65_535 -> port
      _ -> @default_epmd_port
    end
  end

  # -- verdict ---------------------------------------------------------------

  defp result(listeners, binds, cookies) do
    exposed =
      for {label, _port, addrs} <- binds,
          {ip, port} <- addrs,
          not loopback?(ip),
          do: "#{label} listens on #{endpoint(ip, port)}"

    readable =
      for {path, mode} <- cookies, (mode &&& 0o077) != 0, do: "#{path} is #{octal(mode)}"

    case exposed ++ readable do
      [] ->
        %Result{name: @name, status: :ok, detail: ok_detail(listeners, binds, cookies)} |> flags()

      problems ->
        %Result{
          name: @name,
          status: :fail,
          detail: Enum.join(problems, "; ") <> bind_suffix(listeners),
          hint: hint(exposed, readable)
        }
        |> flags()
    end
  end

  # Fatal so `arb doctor` exits non-zero — this is a remote-code-execution
  # path into the server — but it says nothing about whether a freshly
  # deployed release is healthy, so it never gates deploy readiness.
  defp flags(result), do: %{result | fatal: true, blocks_readiness: false}

  defp ok_detail(listeners, binds, cookies) do
    bound = for {label, _port, [_ | _] = addrs} <- binds, do: "#{label} #{endpoints(addrs)}"

    bind_part =
      cond do
        listeners == :unknown -> ["listeners unknown"]
        bound == [] -> ["distribution not running"]
        true -> bound
      end

    cookie_part = for {path, mode} <- cookies, do: "cookie #{path} #{octal(mode)}"
    Enum.join(bind_part ++ cookie_part, "; ")
  end

  defp bind_suffix(:unknown), do: " (listeners unknown)"
  defp bind_suffix(_), do: ""

  defp hint(exposed, readable) do
    bind_hint =
      if exposed != [],
        do: [
          "Distribution must stay on loopback: the release's env.sh sets " <>
            "ERL_EPMD_ADDRESS=127.0.0.1 and RELEASE_NODE=arbiter@127.0.0.1, and " <>
            "vm.args pins -kernel inet_dist_use_interface {127,0,0,1}. Restart the " <>
            "server on a release that has them; an epmd started before that keeps " <>
            "its old binding until it exits (`epmd -names` lists who still uses it)."
        ],
        else: []

    cookie_hint =
      if readable != [],
        do: ["`chmod 600` the cookie file(s); the release's env.sh does this on every start."],
        else: []

    Enum.join(bind_hint ++ cookie_hint, " ")
  end

  # -- listeners -------------------------------------------------------------

  # `:unknown` when no table could be read at all; otherwise every LISTEN
  # socket as `{ip_tuple, port}`.
  defp read_listeners(paths) do
    tables = for path <- paths, {:ok, body} <- [File.read(path)], do: body

    case tables do
      [] -> :unknown
      bodies -> Enum.flat_map(bodies, &parse_table/1)
    end
  end

  defp parse_table(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_sl, local, _remote, "0A" | _] -> parse_local(local)
        _ -> []
      end
    end)
  end

  defp parse_local(local) do
    with [addr, port_hex] <- String.split(local, ":"),
         {port, ""} <- Integer.parse(port_hex, 16),
         {:ok, ip} <- decode_addr(addr) do
      [{ip, port}]
    else
      _ -> []
    end
  end

  # The kernel prints each 32-bit word of the address in host byte order.
  defp decode_addr(hex) when byte_size(hex) in [8, 32] do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} ->
        bytes = for <<word::32-native <- raw>>, into: <<>>, do: <<word::32-big>>
        {:ok, to_ip(bytes)}

      :error ->
        :error
    end
  end

  defp decode_addr(_), do: :error

  defp to_ip(<<a, b, c, d>>), do: {a, b, c, d}
  defp to_ip(<<_::128>> = v6), do: List.to_tuple(for <<group::16 <- v6>>, do: group)

  defp on_port(:unknown, _port), do: []
  defp on_port(listeners, port), do: for({_ip, ^port} = l <- listeners, do: l)

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, hi, _lo}), do: hi >>> 8 == 127
  defp loopback?(_), do: false

  defp endpoints(addrs), do: Enum.map_join(addrs, ", ", fn {ip, port} -> endpoint(ip, port) end)

  defp endpoint({_, _, _, _} = ip, port), do: "#{:inet.ntoa(ip)}:#{port}"
  defp endpoint(ip, port), do: "[#{:inet.ntoa(ip)}]:#{port}"

  # -- epmd ------------------------------------------------------------------

  # Ask epmd on loopback for its registered names (NAMES_REQ) and return the
  # release node's distribution port, or nil when epmd or the node is absent.
  defp node_port(nil), do: nil

  defp node_port(port) do
    opts = [:binary, active: false, packet: :raw]

    with {:ok, sock} <- :gen_tcp.connect({127, 0, 0, 1}, port, opts, @epmd_timeout_ms) do
      try do
        with :ok <- :gen_tcp.send(sock, <<1::16, 110>>),
             {:ok, <<_epmd_port::32, names::binary>>} <- recv_all(sock, <<>>) do
          find_node(names)
        else
          _ -> nil
        end
      after
        :gen_tcp.close(sock)
      end
    else
      _ -> nil
    end
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, @epmd_timeout_ms) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, _} = error -> error
    end
  end

  defp find_node(names) do
    Enum.find_value(String.split(names, "\n", trim: true), fn line ->
      case Regex.run(~r/^name (\S+) at port (\d+)$/, line) do
        [_, @node_name, port] -> String.to_integer(port)
        _ -> nil
      end
    end)
  end

  # -- cookies ---------------------------------------------------------------

  defp cookie_modes(paths) do
    for path <- paths, {:ok, %File.Stat{mode: mode}} <- [File.stat(path)], do: {path, mode &&& 0o777}
  end

  defp octal(mode), do: mode |> Integer.to_string(8) |> String.pad_leading(4, "0")
end
