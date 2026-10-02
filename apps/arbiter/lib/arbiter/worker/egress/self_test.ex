defmodule Arbiter.Worker.Egress.SelfTest do
  @moduledoc """
  The "egress jail" self-test behind `arb server doctor`
  (bd-5yydxh, G10; `docs/design/guardrail-profiles.md` §7.3).

  It passes when

    1. `bwrap --unshare-net` and `socat` are present and a jail built in
       network mode comes up with only `lo` (`Arbiter.Worker.Jail.network_probe/0`);
    2. a proxy listener starts (`Arbiter.Worker.Egress.start_run/2`); and
    3. against a **local** stand-in server (a loopback listener this module
       opens, so no internet is needed), one `CONNECT` to the allowlisted
       `host:port` is answered `200` and reaches the stand-in, and one
       `CONNECT` to a port that is not allowlisted is answered `403`.

  `run/1` returns `{:ok, %{allowed: 1, denied: 1}}` or `{:error, reason}`;
  `diagnose/1` turns an error into the `cause` + `message` + `fix` the other
  jail diagnoses have, with the missing package or the sysctl named, as
  `Arbiter.Worker.Jail.explain_network/1` does.

  The proxy runs with `audit: false`, so the self-test leaves no
  `egress_events` rows, and it tears its run, socket and stand-in down before
  returning.

  Options: `:probe` (a 0-arity fun returning `:ok | {:error, reason}`, default
  `Jail.network_probe/0`, uncached so a fresh `dnf install socat` shows up
  without a restart; the `:worker_jail_network_available` override still
  wins), `:run_id` (default a fresh `selftest…` id) and
  `:enforce` (default `true`; `false` runs the proxy in learn mode, which lets
  the deny through, so the self-test fails with `:deny_failed`).
  """

  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Egress.Policy
  alias Arbiter.Worker.Jail

  @timeout 2_000

  @type result :: {:ok, %{allowed: 1, denied: 1}} | {:error, term()}
  @type diagnosis :: %{cause: atom(), message: String.t(), fix: String.t() | nil}

  @doc "Runs the self-test. Never raises."
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    probe = Keyword.get(opts, :probe, &default_probe/0)

    case probe.() do
      :ok ->
        proxy_test(Keyword.get(opts, :run_id) || new_run_id(), Keyword.get(opts, :enforce, true))

      {:error, reason} ->
        {:error, {:jail, reason}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp default_probe do
    case Application.get_env(:arbiter, :worker_jail_network_available) do
      override when is_boolean(override) -> Jail.network_status()
      _ -> Jail.network_probe()
    end
  end

  @doc "`nil` when `run/1` passes, else a cause + fix for `arb server doctor`."
  @spec diagnose(keyword()) :: diagnosis() | nil
  def diagnose(opts \\ []) do
    case run(opts) do
      {:ok, _} -> nil
      {:error, reason} -> explain(reason)
    end
  end

  @doc "Categorizes a `run/1` error into a cause + message + fix."
  @spec explain(term()) :: diagnosis()
  def explain({:jail, reason}), do: Jail.explain_network(reason)

  def explain({:proxy_start, reason}) do
    %{
      cause: :egress_proxy,
      message: "the egress proxy listener did not start: #{inspect(reason)}",
      fix:
        "Check that Arbiter's egress supervisor is running and that the scratch " <>
          "directory for its Unix sockets is writable (`Arbiter.Worker.Egress.socket_dir/0`)."
    }
  end

  def explain({:allow_failed, got}) do
    %{
      cause: :egress_proxy,
      message: "the proxy did not allow the allowlisted stand-in (got #{inspect(got)}, want 200)",
      fix: "Check the proxy's policy and that loopback dialing works on this host."
    }
  end

  def explain({:deny_failed, got}) do
    %{
      cause: :egress_proxy,
      message:
        "the proxy did not deny a host that is not allowlisted (got #{inspect(got)}, want 403)",
      fix:
        "An egress level that filters would let everything through on this host; do not rely on it."
    }
  end

  def explain({:standin, reason}) do
    %{
      cause: :egress_proxy,
      message: "the local stand-in server for the self-test could not run: #{inspect(reason)}",
      fix: "Check that loopback TCP listeners can be opened on this host."
    }
  end

  def explain({:raised, message}) do
    %{cause: :other, message: "the egress self-test raised: #{message}", fix: nil}
  end

  # --- the proxy half ------------------------------------------------------

  defp proxy_test(run_id, enforce) do
    with {:ok, listen, port} <- listen_standin() do
      try do
        start_and_probe(run_id, port, enforce)
      after
        :gen_tcp.close(listen)
      end
    end
  end

  defp start_and_probe(run_id, port, enforce) do
    opts = [
      enforce: enforce,
      baseline: [Policy.format("127.0.0.1", port)],
      allow_local_dial: true,
      audit: false,
      dial_timeout: @timeout
    ]

    case Egress.start_run(run_id, opts) do
      {:ok, socket} ->
        try do
          check(socket, port)
        after
          Egress.stop_run(run_id)
        end

      {:error, reason} ->
        {:error, {:proxy_start, reason}}
    end
  end

  defp check(socket, port) do
    with :ok <- check_allow(socket, port),
         :ok <- check_deny(socket, port) do
      {:ok, %{allowed: 1, denied: 1}}
    end
  end

  defp check_allow(socket, port) do
    case connect(socket, Policy.format("127.0.0.1", port)) do
      {200, sock, rest} ->
        result = echo(sock, rest)
        :gen_tcp.close(sock)
        result

      {got, sock, _rest} ->
        :gen_tcp.close(sock)
        {:error, {:allow_failed, got}}

      {:error, reason} ->
        {:error, {:allow_failed, reason}}
    end
  end

  # The tunnel is real only if bytes reach the stand-in and come back.
  defp echo(sock, rest) do
    with :ok <- :gen_tcp.send(sock, "ping"),
         {:ok, "ping"} <- recv_exact(sock, rest, 4) do
      :ok
    else
      other -> {:error, {:allow_failed, {:no_echo, other}}}
    end
  end

  defp check_deny(socket, port) do
    # Same host, a different port: not in the baseline, and a deny answers
    # before anything is resolved or dialed.
    denied_port = if port < 65_535, do: port + 1, else: port - 1

    case connect(socket, Policy.format("127.0.0.1", denied_port)) do
      {403, sock, _rest} ->
        :gen_tcp.close(sock)
        :ok

      {got, sock, _rest} ->
        :gen_tcp.close(sock)
        {:error, {:deny_failed, got}}

      {:error, reason} ->
        {:error, {:deny_failed, reason}}
    end
  end

  # CONNECT through the proxy's Unix socket: {status, socket, bytes after the head}.
  defp connect(socket_path, authority) do
    with {:ok, sock} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(socket_path)},
             0,
             [:binary, active: false],
             @timeout
           ),
         :ok <- :gen_tcp.send(sock, "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n\r\n") do
      case read_head(sock, "") do
        {:ok, head, rest} -> {status(head), sock, rest}
        {:error, reason} -> :gen_tcp.close(sock) && {:error, reason}
      end
    end
  end

  defp read_head(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        case :gen_tcp.recv(sock, 0, @timeout) do
          {:ok, data} -> read_head(sock, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp status("HTTP/1." <> <<_minor, " ", code::binary-size(3), _::binary>>) do
    case Integer.parse(code) do
      {n, ""} -> n
      _ -> :malformed
    end
  end

  defp status(_), do: :malformed

  defp recv_exact(_sock, buffered, n) when byte_size(buffered) >= n,
    do: {:ok, binary_part(buffered, 0, n)}

  defp recv_exact(sock, buffered, n) do
    case :gen_tcp.recv(sock, 0, @timeout) do
      {:ok, data} -> recv_exact(sock, buffered <> data, n)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- the local stand-in --------------------------------------------------

  # A loopback echo server on an ephemeral port. Never reachable off the host.
  defp listen_standin do
    case :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, listen} ->
        {:ok, port} = :inet.port(listen)
        spawn(fn -> accept(listen) end)
        {:ok, listen, port}

      {:error, reason} ->
        {:error, {:standin, reason}}
    end
  end

  defp accept(listen) do
    case :gen_tcp.accept(listen, :infinity) do
      {:ok, sock} ->
        pid = spawn(fn -> serve(sock) end)
        :gen_tcp.controlling_process(sock, pid)
        accept(listen)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock) do
    case :gen_tcp.recv(sock, 0, @timeout) do
      {:ok, data} ->
        :gen_tcp.send(sock, data)
        serve(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  defp new_run_id, do: "selftest#{System.unique_integer([:positive])}"
end
