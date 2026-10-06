defmodule ArbiterWeb.Spike.Load do
  @moduledoc """
  RW2 spike (bd-6tx1xv): the in-container client side of U3/U4 — what the Claude
  CLI or `git push` would be doing against the node's per-run unix listener —
  plus percentile helpers. **Prototype, not product code.**
  """

  @doc "Replays an SSE trace; returns `{latencies_us, bytes}` (event write -> client parse, one BEAM clock)."
  def sse(path, trace_file) do
    sock = connect!(path)
    :ok = :gen_tcp.send(sock, "SSE #{trace_file}\n")
    sse_loop(sock, <<>>, [], 0)
  end

  defp sse_loop(sock, buf, lat, bytes) do
    case :gen_tcp.recv(sock, 0, 60_000) do
      {:ok, data} ->
        {events, rest} = split_events(buf <> data)
        now = System.monotonic_time(:microsecond)
        lat = Enum.reduce(events, lat, fn ev, acc -> [now - stamp(ev) | acc] end)
        sse_loop(sock, rest, lat, bytes + byte_size(data))

      {:error, :closed} ->
        {Enum.reverse(lat), bytes}
    end
  end

  defp split_events(buf) do
    parts = :binary.split(buf, "\n\n", [:global])
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp stamp(event) do
    [_, rest] = :binary.split(event, "\"t\":")
    [n | _] = :binary.split(rest, ",")
    String.to_integer(n)
  end

  @doc "`n` sequential connections, each `SMALL`; returns `[%{ttfb_us, total_us}]` per connection."
  def small(path, n) do
    for _ <- 1..n do
      t0 = System.monotonic_time(:microsecond)
      sock = connect!(path)
      :ok = :gen_tcp.send(sock, "SMALL\n")
      {:ok, first} = :gen_tcp.recv(sock, 0, 30_000)
      ttfb = System.monotonic_time(:microsecond) - t0
      total = drain(sock, byte_size(first))
      t1 = System.monotonic_time(:microsecond) - t0
      :gen_tcp.close(sock)
      %{ttfb_us: ttfb, total_us: t1, bytes: total}
    end
  end

  defp drain(_sock, got) when got >= 1024, do: got

  defp drain(sock, got) do
    {:ok, d} = :gen_tcp.recv(sock, 0, 30_000)
    drain(sock, got + byte_size(d))
  end

  @doc "Pushes `bytes` bytes upstream (a `git push`-shaped upload); returns the elapsed microseconds."
  def push(path, bytes) do
    t0 = System.monotonic_time(:microsecond)
    sock = connect!(path)
    :ok = :gen_tcp.send(sock, "SINK #{bytes}\n")
    send_chunks(sock, bytes)
    {:ok, reply} = :gen_tcp.recv(sock, 0, 120_000)
    true = String.starts_with?(reply, "OK #{bytes}")
    :gen_tcp.close(sock)
    System.monotonic_time(:microsecond) - t0
  end

  defp send_chunks(_sock, n) when n <= 0, do: :ok

  defp send_chunks(sock, n) do
    size = min(n, 65_536)
    :ok = :gen_tcp.send(sock, :binary.copy("p", size))
    send_chunks(sock, n - size)
  end

  @doc "Pulls `bytes` bytes downstream (primary -> node direction); returns elapsed microseconds."
  def pull(path, bytes) do
    t0 = System.monotonic_time(:microsecond)
    sock = connect!(path)
    :ok = :gen_tcp.send(sock, "SOURCE #{bytes}\n")
    pull_loop(sock, bytes)
    :gen_tcp.close(sock)
    System.monotonic_time(:microsecond) - t0
  end

  defp pull_loop(_sock, n) when n <= 0, do: :ok

  defp pull_loop(sock, n) do
    {:ok, d} = :gen_tcp.recv(sock, 0, 120_000)
    pull_loop(sock, n - byte_size(d))
  end

  def connect!(path) do
    {:ok, sock} =
      :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, active: false, packet: :raw])

    sock
  end

  @doc "Nearest-rank percentile (0-100) of a non-empty list."
  def pct(list, p) do
    sorted = Enum.sort(list)
    idx = max(ceil(p / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, idx)
  end

  def summary(list_us) do
    ms = Enum.map(list_us, &(&1 / 1000))

    %{
      n: length(ms),
      p50_ms: r(pct(ms, 50)),
      p90_ms: r(pct(ms, 90)),
      p99_ms: r(pct(ms, 99)),
      max_ms: r(Enum.max(ms))
    }
  end

  defp r(x), do: Float.round(x * 1.0, 2)

  @doc "utime+stime of this OS process in seconds (Linux `/proc/self/stat`)."
  def cpu_seconds do
    [_ | rest] = "/proc/self/stat" |> File.read!() |> String.split(") ", parts: 2)
    fields = rest |> hd() |> String.split(" ")
    (String.to_integer(Enum.at(fields, 11)) + String.to_integer(Enum.at(fields, 12))) / 100
  end
end
