defmodule ArbiterWeb.NodeTestEndpoint do
  @moduledoc """
  A second, test-only endpoint that serves the **real** `ArbiterWeb.NodeSocket`
  over a real Bandit listener on a free loopback port, so a test can watch a
  real WebSocket transport close (`Endpoint.broadcast(socket_id, "disconnect")`)
  instead of inferring it from `Phoenix.ChannelTest`, which has no transport.

  It shares `Arbiter.PubSub` with `ArbiterWeb.Endpoint`, so the broadcast the
  channel makes on the real endpoint reaches this one's transports. It is
  configured from `configure/1`, never from `config/*.exs`.
  """
  use Phoenix.Endpoint, otp_app: :arbiter_web

  socket "/node/socket", ArbiterWeb.NodeSocket,
    websocket: [connect_info: [:peer_data, :x_headers], max_frame_size: 1_048_576],
    longpoll: false

  @doc "Puts the endpoint's config (free loopback port). Then `start_supervised!(#{inspect(__MODULE__)})`."
  def configure do
    Application.put_env(:arbiter_web, __MODULE__,
      http: [ip: {127, 0, 0, 1}, port: 0],
      server: true,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
      pubsub_server: Arbiter.PubSub,
      check_origin: false
    )
  end

  @doc "The port the listener bound."
  def port do
    {:ok, {_ip, port}} = server_info(:http)
    port
  end
end
