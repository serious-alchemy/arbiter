defmodule Arbiter.Worker.Egress.Forward do
  @moduledoc """
  A fixed-target byte bridge for one jailed run (bd-cfktou, G6;
  `docs/design/guardrail-profiles.md` §4.4): every connection accepted on the
  run's `<run>.<name>.sock` is spliced to one `host:port` the operator chose,
  with no policy decision and no request parsing.

  Two things use it: the run's Arbiter endpoint (so `arb` and the MCP URL work
  unchanged inside the namespace) and the fixed-destination tunnels (a
  host-loopback test database, a read replica). The target is fixed when the
  run starts, so the jailed process can reach that one destination and nothing
  it can send changes where the bytes go.
  """

  require Logger

  alias Arbiter.Worker.Egress.Connection

  @dial_timeout_ms 10_000

  @doc "Handles one accepted client: dial `host:port`, then relay both ways."
  @spec run(port(), String.t(), :inet.port_number()) :: :ok
  def run(client, host, port) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, packet: :raw, active: false, exit_on_close: false],
           @dial_timeout_ms
         ) do
      {:ok, upstream} ->
        Connection.relay(client, upstream)

      {:error, reason} ->
        Logger.info("egress: bridge to #{host}:#{port} failed: #{inspect(reason)}")
        :gen_tcp.close(client)
        :ok
    end
  end
end
