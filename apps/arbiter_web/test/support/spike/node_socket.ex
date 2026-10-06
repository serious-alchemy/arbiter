defmodule ArbiterWeb.Spike.NodeSocket do
  @moduledoc "RW2 spike: the `/node/socket` stand-in (`id/1` shaped like the design's `node_socket:<id>`). Not product code."
  use Phoenix.Socket

  channel "node:*", ArbiterWeb.Spike.NodeChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    if token == Application.get_env(:arbiter_web, :spike_node_token, "spike-token") do
      forwarded = for {k, v} <- connect_info[:x_headers] || [], do: {k, v}
      {:ok, assign(socket, :x_headers, forwarded)}
    else
      :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: "node_socket:spike"
end
