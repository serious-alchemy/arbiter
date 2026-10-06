defmodule ArbiterWeb.Spike.Upstream do
  @moduledoc """
  RW2 spike (bd-6tx1xv): the fake far end of a bridge — what the primary's own
  `Egress` listener fronts — and the traffic generators for U3/U4. **Prototype,
  not product code.**

  A connection sends one request line and gets one behaviour:

    * `SSE <trace-file>` — replay a recorded SSE trace: each event carries the
      monotonic microsecond it was written at, so the client can compute
      end-to-end latency in the same BEAM clock.
    * `SINK <n>` — read `n` bytes after the line, answer `OK <n>`.
    * `SOURCE <bytes>` — write that many bytes then close.
    * `SMALL` — one ~1 KiB response then close (CONNECT-handshake-sized).
  """

  @doc "Starts a unix listener at `path`; returns the listen socket (closed by the caller)."
  def listen(path) do
    File.rm(path)

    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, to_charlist(path)},
        active: false,
        backlog: 128,
        packet: :raw
      ])

    spawn_link(fn -> accept(lsock) end)
    lsock
  end

  defp accept(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        pid = spawn(fn -> serve(sock) end)
        :gen_tcp.controlling_process(sock, pid)
        accept(lsock)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock) do
    case read_line(sock, <<>>) do
      {:ok, "SSE " <> trace, _rest} -> sse(sock, String.trim(trace))
      {:ok, "SINK " <> n, rest} -> sink(sock, String.to_integer(String.trim(n)), byte_size(rest))
      {:ok, "SOURCE " <> n, _} -> source(sock, n |> String.trim() |> String.to_integer())
      {:ok, "SMALL" <> _, _} -> small(sock)
      _ -> :gen_tcp.close(sock)
    end
  end

  defp read_line(sock, acc) do
    case :binary.split(acc, "\n") do
      [line, rest] ->
        {:ok, line, rest}

      [_] ->
        case :gen_tcp.recv(sock, 0, 10_000) do
          {:ok, data} -> read_line(sock, acc <> data)
          error -> error
        end
    end
  end

  defp sse(sock, trace_file) do
    trace = trace_file |> File.read!() |> :erlang.binary_to_term()
    start = System.monotonic_time(:microsecond)

    Enum.each(trace, fn {offset_us, pad} ->
      wait = offset_us - (System.monotonic_time(:microsecond) - start)
      if wait > 1000, do: Process.sleep(div(wait, 1000))
      stamp = System.monotonic_time(:microsecond)

      :gen_tcp.send(sock, [
        "event: content_block_delta\ndata: {\"t\":",
        Integer.to_string(stamp),
        ",\"pad\":\"",
        pad,
        "\"}\n\n"
      ])
    end)

    :gen_tcp.close(sock)
  end

  defp sink(sock, total, got) when got >= total do
    :gen_tcp.send(sock, "OK #{got}\n")
    :gen_tcp.close(sock)
  end

  defp sink(sock, total, got) do
    case :gen_tcp.recv(sock, 0, 60_000) do
      {:ok, data} -> sink(sock, total, got + byte_size(data))
      {:error, _} -> :gen_tcp.close(sock)
    end
  end

  defp source(sock, n) do
    chunk = :binary.copy("x", 16_384)
    send_n(sock, n, chunk)
    :gen_tcp.close(sock)
  end

  defp send_n(_sock, n, _chunk) when n <= 0, do: :ok

  defp send_n(sock, n, chunk) do
    piece = if n >= byte_size(chunk), do: chunk, else: binary_part(chunk, 0, n)
    :ok = :gen_tcp.send(sock, piece)
    send_n(sock, n - byte_size(piece), chunk)
  end

  defp small(sock) do
    :gen_tcp.send(sock, :binary.copy("s", 1024))
    :gen_tcp.close(sock)
  end

  @doc """
  A deterministic SSE trace shaped like a model stream: Anthropic
  `content_block_delta` events of 120-420 bytes at ~40 events/s (exponential
  gaps), for `seconds` seconds. It is synthesised from a seed, not recorded
  from the live API (no credentials are used in this spike).
  """
  def trace(seconds, seed \\ 7) do
    :rand.seed(:exsss, {seed, seed, seed})
    build_trace(0, seconds * 1_000_000, [])
  end

  defp build_trace(t, limit, acc) when t >= limit, do: Enum.reverse(acc)

  defp build_trace(t, limit, acc) do
    gap = round(-:math.log(:rand.uniform()) * 25_000)
    size = 120 + :rand.uniform(300)
    build_trace(t + gap, limit, [{t, :binary.copy("a", size)} | acc])
  end
end
