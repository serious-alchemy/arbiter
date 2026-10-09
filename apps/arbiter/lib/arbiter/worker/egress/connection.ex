defmodule Arbiter.Worker.Egress.Connection do
  @moduledoc """
  One client connection on a run's proxy socket: read the `CONNECT`, decide,
  record, dial, splice.

  The proxy is a CONNECT-only tunnel; there is no TLS interception. Anything
  but `CONNECT` is answered `405`. Plain-`http://` forwarding is out of scope,
  clients send `CONNECT host:80` through `HTTP_PROXY` too.

  ## DNS and the dial

  The client names a host and never resolves it. The proxy resolves on the
  host and dials the address it got, so the address checked is the address
  used (no resolve-then-connect gap). Unless the run sets `:allow_local_dial`,
  addresses that reach the host itself are refused after resolution: loopback,
  unspecified, and link-local (`169.254.0.0/16` covers cloud metadata). A
  granted name that resolves to `127.0.0.1` would otherwise be a way to the
  host's loopback services, which is the anonymous-loopback reach design §2.5
  closes. RFC 1918 space is not blocked: legitimate infra lives there.

  ## Learn and enforce

  The run's policy verdict is always recorded. In enforce mode a deny is
  answered `403`. In learn mode (`enforce: false`) a deny is logged and the
  tunnel is allowed, **except `:public_upload`**, which holds in both modes:
  learn mode exists to discover missing toolchain hosts, and an anonymous
  upload host is never one.
  """

  require Logger

  alias Arbiter.Worker.Egress.{Audit, GrantCache, Policy}

  @max_head 8_192
  @head_timeout_ms 10_000

  @spec run(port(), map()) :: :ok
  def run(client, ctx) do
    case read_head(client, "") do
      {:ok, head, rest} -> handle(client, head, rest, ctx)
      {:error, _} -> :gen_tcp.close(client)
    end
  end

  defp handle(client, head, rest, ctx) do
    [request_line | _] = String.split(head, "\r\n", parts: 2)

    case String.split(request_line, " ") do
      ["CONNECT", authority, "HTTP/1." <> _] -> connect(client, authority, rest, ctx)
      _ -> reply_and_close(client, 405, "Method Not Allowed", ["Allow: CONNECT"])
    end
  end

  defp connect(client, authority, rest, ctx) do
    case Policy.parse_authority(authority) do
      {:ok, {host, port}} ->
        decide_and_dial(client, host, port, rest, ctx)

      {:error, _} ->
        Audit.record(ctx, raw_target(authority), :deny, :deny, :invalid_target)
        reply_and_close(client, 400, "Bad Request")
    end
  end

  defp decide_and_dial(client, host, port, rest, ctx) do
    grants = GrantCache.fetch(ctx.task_id, ctx.run_id, ctx.grants_loader)

    policy_ctx = %{
      baseline: ctx.baseline,
      grants: grants,
      safe_defaults_exclude: ctx.safe_defaults_exclude
    }

    verdict = Policy.decide(host, port, policy_ctx)

    case {verdict, ctx.enforce} do
      {{:allow, reason}, _} ->
        Audit.record(ctx, {host, port}, :allow, :allow, reason)
        dial(client, host, port, rest, ctx)

      {{:deny, :public_upload = reason}, _} ->
        deny(client, ctx, host, port, reason)

      {{:deny, reason}, false} ->
        Audit.record(ctx, {host, port}, :allow, :deny, reason)
        dial(client, host, port, rest, ctx)

      {{:deny, reason}, true} ->
        deny(client, ctx, host, port, reason)
    end
  end

  defp deny(client, ctx, host, port, reason) do
    Audit.record(ctx, {host, port}, :deny, :deny, reason)
    reply_and_close(client, 403, "Forbidden", ["X-Arbiter-Egress: #{reason}"])
  end

  defp dial(client, host, port, rest, ctx) do
    case resolve(host, ctx) do
      {:ok, addrs} ->
        case connect_any(addrs, port, ctx.dial_timeout) do
          {:ok, upstream} -> splice(client, upstream, rest)
          {:error, reason} -> bad_gateway(client, host, port, reason)
        end

      {:error, :blocked} ->
        Audit.record(ctx, {host, port}, :deny, :allow, :dial_blocked)
        reply_and_close(client, 403, "Forbidden", ["X-Arbiter-Egress: dial_blocked"])

      {:error, reason} ->
        bad_gateway(client, host, port, reason)
    end
  end

  defp bad_gateway(client, host, port, reason) do
    Logger.info("egress: dial #{Policy.format(host, port)} failed: #{inspect(reason)}")
    reply_and_close(client, 502, "Bad Gateway")
  end

  # Resolved on the host. `host` is already a validated hostname or a
  # canonical IP literal.
  defp resolve(host, ctx) do
    addrs =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} -> {:ok, [ip]}
        {:error, _} -> lookup(host)
      end

    with {:ok, addrs} <- addrs do
      permitted = if ctx.allow_local_dial, do: addrs, else: Enum.reject(addrs, &local?/1)
      if permitted == [], do: {:error, :blocked}, else: {:ok, permitted}
    end
  end

  defp lookup(host) do
    charlist = String.to_charlist(host)

    case {:inet.getaddrs(charlist, :inet), :inet.getaddrs(charlist, :inet6)} do
      {{:error, reason}, {:error, _}} -> {:error, reason}
      {v4, v6} -> {:ok, ok_list(v4) ++ ok_list(v6)}
    end
  end

  defp ok_list({:ok, addrs}), do: addrs
  defp ok_list(_), do: []

  @doc false
  @spec local?(:inet.ip_address()) :: boolean()
  def local?({127, _, _, _}), do: true
  def local?({0, 0, 0, 0}), do: true
  def local?({169, 254, _, _}), do: true
  def local?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def local?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true

  def local?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do:
      local?(
        {Bitwise.bsr(hi, 8), Bitwise.band(hi, 255), Bitwise.bsr(lo, 8), Bitwise.band(lo, 255)}
      )

  def local?(_), do: false

  defp connect_any(addrs, port, timeout) do
    Enum.reduce_while(addrs, {:error, :no_address}, fn addr, _acc ->
      case :gen_tcp.connect(
             addr,
             port,
             [:binary, packet: :raw, active: false, exit_on_close: false],
             timeout
           ) do
        {:ok, sock} -> {:halt, {:ok, sock}}
        {:error, _} = err -> {:cont, err}
      end
    end)
  end

  defp splice(client, upstream, rest) do
    case :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n") do
      :ok ->
        relay(client, upstream, rest)

      {:error, _} ->
        :gen_tcp.close(client)
        :gen_tcp.close(upstream)
    end
  end

  @doc false
  # Splices `client` and `upstream` until both directions have ended, then
  # closes both. `rest` is any bytes already read from `client` that belong
  # upstream. Shared with `Arbiter.Worker.Egress.Forward`.
  #
  # An end-of-stream from one side is passed on as a half-close
  # (`shutdown(:write)`) and the other direction keeps flowing, so a client
  # that sends its request and then closes its write side (`socat`, `nc`) still
  # gets its reply. Both sockets must have been opened with
  # `exit_on_close: false` for that. A failed write means the peer is gone and
  # ends both directions.
  @spec relay(port(), port(), binary()) :: :ok
  def relay(client, upstream, rest \\ "") do
    if send_initial(upstream, rest) == :ok do
      parent = self()
      back = spawn_link(fn -> send(parent, {:relay_done, self(), pipe(upstream, client)}) end)
      pipe(client, upstream)

      receive do
        {:relay_done, ^back, _} -> :ok
      end
    end

    :gen_tcp.close(client)
    :gen_tcp.close(upstream)
    :ok
  end

  defp send_initial(_upstream, ""), do: :ok
  defp send_initial(upstream, data), do: :gen_tcp.send(upstream, data)

  defp pipe(from, to) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        case :gen_tcp.send(to, data) do
          :ok ->
            pipe(from, to)

          {:error, _} ->
            :gen_tcp.close(from)
            :gen_tcp.close(to)
            :aborted
        end

      {:error, _} ->
        _ = :gen_tcp.shutdown(to, :write)
        :eof
    end
  end

  defp read_head(_client, acc) when byte_size(acc) > @max_head, do: {:error, :too_large}

  defp read_head(client, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        case :gen_tcp.recv(client, 0, @head_timeout_ms) do
          {:ok, data} -> read_head(client, acc <> data)
          {:error, _} = err -> err
        end
    end
  end

  defp reply_and_close(client, code, text, headers \\ []) do
    head =
      Enum.join(
        ["HTTP/1.1 #{code} #{text}" | headers] ++
          ["Content-Length: 0", "Connection: close", "", ""],
        "\r\n"
      )

    _ = :gen_tcp.send(client, head)
    :gen_tcp.close(client)
  end

  defp raw_target(authority) do
    {authority |> String.slice(0, 253), 0}
  end
end
