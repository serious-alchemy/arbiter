defmodule ArbiterWeb.FakeNode do
  @moduledoc """
  A stand-in for the primary's `/node/socket` and `/nodes/*` for the RW5 agent
  client tests (`Arbiter.NodeAgent`): a real Phoenix endpoint under Bandit on a
  real loopback port, so the agent's WebSocket client and HTTP download run over
  real TCP. Not product code (the real `NodeSocket`/`NodeChannel` are RW6).

  Behaviour is steered from the test through `:arbiter_web` app env, and the
  server reports what it saw to `fake_node_test_pid` as `{:fake_node, kind, data}`.

    * `:fake_node_token` — the credential the socket accepts.
    * `:fake_node_hello_ok` — the payload answered to `hello` (map).
    * `:fake_node_ack?` — `false` makes it swallow heartbeats unanswered.
    * `:fake_node_tarball` — `{path, expected_version}` served at
      `GET /nodes/agent/<version>.tar.gz` (Bearer credential required).
  """

  defmodule Socket do
    @moduledoc false
    use Phoenix.Socket

    channel "node:*", ArbiterWeb.FakeNode.Channel

    @impl true
    def connect(%{"token" => token} = params, socket, _connect_info) do
      expected = Application.get_env(:arbiter_web, :fake_node_token)
      notify({:connect, Map.take(params, ["proto", "agent_version", "vsn"])})

      if token == expected, do: {:ok, socket}, else: :error
    end

    def connect(_params, _socket, _connect_info), do: :error

    @impl true
    def id(_socket), do: "node_socket:fake"

    defp notify(data) do
      if pid = Application.get_env(:arbiter_web, :fake_node_test_pid),
        do: send(pid, {:fake_node, :socket, data})
    end
  end

  defmodule Channel do
    @moduledoc false
    use Phoenix.Channel

    @impl true
    def join("node:" <> _ = topic, _params, socket) do
      notify(:joined, topic)
      {:ok, socket}
    end

    @impl true
    def handle_in("hello", payload, socket) do
      notify(:hello, payload)
      hello_ok = Application.get_env(:arbiter_web, :fake_node_hello_ok, %{})

      case Application.get_env(:arbiter_web, :fake_node_style, :reply) do
        :reply ->
          {:reply, {:ok, hello_ok}, socket}

        :push ->
          push(socket, "hello_ok", hello_ok)
          {:noreply, socket}
      end
    end

    def handle_in("hb", payload, socket) do
      notify(:hb, payload)

      cond do
        Application.get_env(:arbiter_web, :fake_node_ack?, true) == false ->
          {:noreply, socket}

        Application.get_env(:arbiter_web, :fake_node_style, :reply) == :reply ->
          {:reply, {:ok, %{"ack" => payload["seq"]}}, socket}

        true ->
          push(socket, "hb_ack", %{"ack" => payload["seq"]})
          {:noreply, socket}
      end
    end

    def handle_in(event, payload, socket) do
      notify(:unexpected, {event, payload})
      {:noreply, socket}
    end

    defp notify(kind, data) do
      if pid = Application.get_env(:arbiter_web, :fake_node_test_pid),
        do: send(pid, {:fake_node, kind, data})
    end
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{path_info: ["nodes", "agent", file]} = conn, _) do
      token = Application.get_env(:arbiter_web, :fake_node_token)

      with ["Bearer " <> ^token] <- get_req_header(conn, "authorization"),
           {path, version} <- Application.get_env(:arbiter_web, :fake_node_tarball),
           true <- file == "#{version}.tar.gz" do
        if pid = Application.get_env(:arbiter_web, :fake_node_test_pid),
          do: send(pid, {:fake_node, :download, file})

        conn |> put_resp_content_type("application/gzip") |> send_file(200, path)
      else
        _ -> send_resp(conn, 401, "nope")
      end
    end

    def call(conn, _), do: send_resp(conn, 404, "not found")
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :arbiter_web

    socket "/node/socket", ArbiterWeb.FakeNode.Socket,
      websocket: [connect_info: [:peer_data], max_frame_size: 1_048_576, timeout: 60_000],
      longpoll: false

    plug ArbiterWeb.FakeNode.Router
  end

  @doc """
  Configure and return the endpoint child. Pass `port:` to rebind a port a
  previous run used (the reconnect tests restart the server on the same one).
  """
  def endpoint_spec(opts \\ []) do
    Application.put_env(:arbiter_web, Endpoint,
      http: [ip: {127, 0, 0, 1}, port: Keyword.get(opts, :port, 0)],
      server: true,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
      pubsub_server: ArbiterWeb.FakeNode.PubSub,
      check_origin: false
    )

    Endpoint
  end

  def port do
    {:ok, {_ip, port}} = Endpoint.server_info(:http)
    port
  end
end
