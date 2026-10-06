defmodule ArbiterWeb.Spike.Endpoint do
  @moduledoc """
  RW2 spike (bd-6tx1xv): a throwaway Phoenix endpoint + Bandit that stands in
  for the primary's `/node/socket` and `/nodes/*`. **Prototype, not product
  code.** It is configured from `start/1`, never from `config/*.exs`, so it
  cannot leak into a real boot.
  """
  use Phoenix.Endpoint, otp_app: :arbiter_web

  socket "/node/socket", ArbiterWeb.Spike.NodeSocket,
    websocket: [
      connect_info: [:peer_data, :x_headers],
      max_frame_size: 1_048_576,
      timeout: 60_000
    ],
    longpoll: false

  # A second socket path: proves a `--set-path` that exposes only /node/socket
  # does not reach it.
  socket "/other/socket", ArbiterWeb.Spike.NodeSocket,
    websocket: [connect_info: [:peer_data, :x_headers]],
    longpoll: false

  plug ArbiterWeb.Spike.Router

  @doc """
  Puts the endpoint's config (free loopback port unless `extra` says otherwise).
  Start it with `start_supervised!(ArbiterWeb.Spike.Endpoint)`, then read
  `port/0`.
  """
  def configure(extra \\ []) do
    config =
      extra ++
        [
          http: [ip: {127, 0, 0, 1}, port: 0],
          server: true,
          adapter: Bandit.PhoenixAdapter,
          secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
          pubsub_server: ArbiterWeb.Spike.PubSub,
          render_errors: [formats: [json: ArbiterWeb.Spike.Router]],
          check_origin: false
        ]

    Application.put_env(:arbiter_web, __MODULE__, config)
  end

  def port do
    {:ok, {_ip, port}} = server_info(:http)
    port
  end
end
