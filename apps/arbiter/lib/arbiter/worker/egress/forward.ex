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

  ## Identity (bd-c1qq7l, G9)

  Before relaying, the connection to the target is registered with
  `Arbiter.Worker.Egress.BridgeIdentity` under its own local `{address, port}`
  as this run's. A target that is Arbiter's endpoint then sees a connection it
  can attribute to the run (`ArbiterWeb.WorkerBridge`) instead of an anonymous
  loopback peer. If the registration cannot be made the client is closed, and
  nothing is relayed: an unattributable connection to Arbiter must not exist.
  """

  require Logger

  alias Arbiter.Worker.Egress.{BridgeIdentity, Connection}

  @dial_timeout_ms 10_000

  @doc """
  Handles one accepted client: dial `host:port`, register the connection as
  `run_id`'s, then relay both ways.
  """
  @spec run(port(), String.t(), String.t(), :inet.port_number()) :: :ok
  def run(client, run_id, host, port) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, packet: :raw, active: false, exit_on_close: false],
           @dial_timeout_ms
         ) do
      {:ok, upstream} ->
        with {:ok, peer} <- :inet.sockname(upstream),
             :ok <- BridgeIdentity.register(run_id, peer) do
          Connection.relay(client, upstream)
        else
          _ ->
            Logger.warning("egress: bridge to #{host}:#{port} could not record its identity")
            :gen_tcp.close(upstream)
            :gen_tcp.close(client)
            :ok
        end

      {:error, reason} ->
        Logger.info("egress: bridge to #{host}:#{port} failed: #{inspect(reason)}")
        :gen_tcp.close(client)
        :ok
    end
  end
end
