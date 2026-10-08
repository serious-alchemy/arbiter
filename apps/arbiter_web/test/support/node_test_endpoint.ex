defmodule ArbiterWeb.NodeTestEndpoint do
  @moduledoc """
  A second, test-only endpoint that serves the **real** `ArbiterWeb.NodeSocket`
  over a real Bandit listener on a free loopback port, so a test can watch a
  real WebSocket transport close (`Endpoint.broadcast(socket_id, "disconnect")`)
  instead of inferring it from `Phoenix.ChannelTest`, which has no transport.

  It also serves `ArbiterWeb.Router`, so the agent's HTTP client (RW11) can reach the
  node routes. It shares `Arbiter.PubSub` with `ArbiterWeb.Endpoint`, so the broadcast the
  channel makes on the real endpoint reaches this one's transports. It is
  configured from `configure/1`, never from `config/*.exs`.
  """
  use Phoenix.Endpoint, otp_app: :arbiter_web

  socket "/node/socket", ArbiterWeb.NodeSocket,
    websocket: [connect_info: [:peer_data, :x_headers], max_frame_size: 1_048_576],
    longpoll: false

  # The node HTTP routes (`/nodes/*`: files, RW11's seed and checkout bundles) over the
  # same real listener, for the end-to-end tests that need the agent's real client.
  # JSON is parsed as the real endpoint does (`/nodes/enroll` takes its token in the body);
  # a bundle upload is `application/octet-stream` and passes through untouched.
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Phoenix.json_library()

  plug ArbiterWeb.Router

  @doc """
  Puts the endpoint's config (a free loopback port, or `port:` to rebind the one a
  previous run used: the primary-restart tests). Then
  `start_supervised!(#{inspect(__MODULE__)})`.
  """
  def configure(opts \\ []) do
    Application.put_env(:arbiter_web, __MODULE__,
      http: [ip: {127, 0, 0, 1}, port: Keyword.get(opts, :port, 0)],
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
