defmodule Arbiter.MCP.OperatorSocket do
  @moduledoc """
  The operator's way to mint a coordinator token (bd-8381tk): a Unix domain
  socket whose peers are identified by the kernel, not by anything they send.

  `POST /api/mcp/tokens` no longer mints for an anonymous caller, because
  every worker shares the operator's host and Unix user and loopback proves
  nothing. Instead `arb mcp token mint` and `arb init` connect here. For each
  connection the listener reads `SO_PEERCRED` (the connecting process's pid
  and uid, recorded by the kernel at `connect()`) and lets
  `Arbiter.MCP.OperatorProof.authorize/2` decide. A process the server
  started, or anything inside its service cgroup, is refused before its
  request is even read.

  Protocol: one JSON object per line in each direction, one request per
  connection.

      → {"op": "mint", "tier": "coordinator", "ttl": 2592000,
         "workspace_id": null, "can_dispatch": true}
      ← {"token": "…", "tier": "coordinator", "workspace_id": null,
         "expires_in": 2592000, "server_url": "http://127.0.0.1:4848/mcp"}
      ← {"error": {"message": "…", "reason": "spawned_by_arbiter"}}

  The request may narrow (`workspace_id`, `can_dispatch: false`, a shorter
  `ttl`). Only the coordinator tier is minted: worker tokens are minted by
  the server at dispatch and never self-served.

  The socket path comes from `Arbiter.MCP.OperatorProof.socket_path/1`. The
  file is mode 0600, and its directory is created 0700. A stale socket left
  by a previous run is replaced. Anything else found at the path is left
  alone, and the listener does not start (`:ignore`): the server still boots,
  existing tokens still work, and the error log names the path.

  `ArbiterWeb.Application` starts it next to the HTTP endpoint, and only when
  that endpoint actually serves.

  Options: `:path` (required), `:authorize` (a keyword list passed to
  `OperatorProof.authorize/2`, for tests) and `:name` (default `__MODULE__`,
  `nil` for none).
  """

  use GenServer

  require Logger

  alias Arbiter.MCP
  alias Arbiter.MCP.{OperatorProof, Scope}

  @default_ttl 30 * 24 * 60 * 60
  @recv_timeout 5_000
  # SOL_SOCKET / SO_PEERCRED on Linux; the payload is a 12-byte struct ucred.
  @sol_socket 1
  @so_peercred 17

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    authorize = Keyword.get(opts, :authorize, [])

    with :ok <- prepare(path),
         {:ok, lsock} <- listen(path) do
      Process.flag(:trap_exit, true)
      acceptor = spawn_link(fn -> accept_loop(lsock, authorize) end)
      Logger.info("operator socket listening at #{path}")
      {:ok, %{path: path, lsock: lsock, acceptor: acceptor}}
    else
      {:error, reason} ->
        Logger.error(
          "operator socket not started at #{path}: #{inspect(reason)}; " <>
            "`arb mcp token mint` will not work on this host until it is fixed"
        )

        :ignore
    end
  end

  @impl true
  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state),
    do: {:stop, reason, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{path: path, lsock: lsock}) do
    :gen_tcp.close(lsock)

    case File.lstat(path) do
      {:ok, %{type: :other}} -> File.rm(path)
      _ -> :ok
    end
  end

  @doc false
  # Shared with `ArbiterWeb.Api.McpController`: a positive integer (or its
  # string form) in seconds, else the 30-day default.
  @spec parse_ttl(term()) :: pos_integer()
  def parse_ttl(n) when is_integer(n) and n > 0, do: n

  def parse_ttl(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> @default_ttl
    end
  end

  def parse_ttl(_), do: @default_ttl

  # ---- listener ------------------------------------------------------------

  defp prepare(path) do
    dir = Path.dirname(path)

    with :ok <- ensure_private_dir(dir) do
      case File.lstat(path) do
        {:error, :enoent} -> :ok
        {:ok, %{type: :other}} -> File.rm(path)
        {:ok, %{type: type}} -> {:error, {:path_occupied, type}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Only a directory this listener creates is chmod'ed; an existing one (an
  # `ARB_OPERATOR_SOCKET` override into a shared dir, say) is left as found.
  defp ensure_private_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  defp listen(path) do
    with {:ok, lsock} <-
           :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: :line, active: false]) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, lsock}

        {:error, reason} ->
          :gen_tcp.close(lsock)
          {:error, {:chmod, reason}}
      end
    end
  end

  defp accept_loop(lsock, authorize) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, handler} =
          Task.start(fn ->
            receive do
              {:serve, ^sock} -> serve(sock, authorize)
            after
              @recv_timeout -> :gen_tcp.close(sock)
            end
          end)

        with :ok <- :gen_tcp.controlling_process(sock, handler), do: send(handler, {:serve, sock})
        accept_loop(lsock, authorize)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("operator socket accept failed: #{inspect(reason)}")
        accept_loop(lsock, authorize)
    end
  end

  # ---- one connection -------------------------------------------------------

  # The peer is judged before its request is parsed, but the request line is
  # read on every path before replying. If the server replied and closed first,
  # a client whose send landed after the close would get `:closed` and never
  # see the reason.
  defp serve(sock, authorize) do
    {peer, verdict} =
      case peercred(sock) do
        {:ok, peer} -> {peer, OperatorProof.authorize(peer, authorize)}
        {:error, reason} -> {nil, {:error, reason}}
      end

    line = :gen_tcp.recv(sock, 0, @recv_timeout)

    response =
      case verdict do
        :ok -> request_response(line, peer)
        {:error, reason} -> refusal(reason, peer)
      end

    _ = :gen_tcp.send(sock, [Jason.encode!(response), "\n"])
    :gen_tcp.close(sock)
  end

  defp request_response({:ok, line}, peer) do
    case Jason.decode(line) do
      {:ok, %{} = request} -> handle_request(request, peer)
      _ -> error("malformed request: send one JSON object per line", "bad_request")
    end
  end

  defp request_response({:error, _}, _peer),
    do: error("malformed request: send one JSON object per line", "bad_request")

  defp peercred(sock) do
    case :inet.getopts(sock, [{:raw, @sol_socket, @so_peercred, 12}]) do
      {:ok, [{:raw, @sol_socket, @so_peercred, bin}]} ->
        case OperatorProof.parse_peercred(bin) do
          {:ok, peer} -> {:ok, peer}
          :error -> {:error, :no_peercred}
        end

      _ ->
        {:error, :no_peercred}
    end
  end

  defp handle_request(%{"op" => "mint"} = req, peer) do
    case Map.get(req, "tier", "coordinator") do
      "coordinator" ->
        ttl = parse_ttl(Map.get(req, "ttl"))
        workspace_id = nilable(Map.get(req, "workspace_id"))
        can_dispatch = Map.get(req, "can_dispatch") not in [false, "false"]

        token =
          Scope.mint_coordinator(workspace_id,
            can_dispatch: can_dispatch,
            max_age: ttl,
            operator: true
          )

        Logger.info(
          "operator socket: minted a coordinator token for pid #{peer.pid} " <>
            "(workspace #{workspace_id || "any"}, can_dispatch #{can_dispatch}, ttl #{ttl}s)"
        )

        %{
          "token" => token,
          "tier" => "coordinator",
          "workspace_id" => workspace_id,
          "expires_in" => ttl,
          "server_url" => MCP.server_url()
        }

      other ->
        error(
          "only the coordinator tier can be minted here, not #{inspect(other)}; " <>
            "worker tokens are minted by the server at dispatch",
          "bad_tier"
        )
    end
  end

  defp handle_request(%{"op" => op}, _peer), do: error("unknown op #{inspect(op)}", "bad_request")
  defp handle_request(_req, _peer), do: error("unknown op (missing \"op\")", "bad_request")

  defp refusal(reason, peer) do
    Logger.warning(
      "operator socket: refused a token mint from pid #{peer && peer.pid}: #{reason}"
    )

    error("operator proof refused: " <> OperatorProof.describe(reason), Atom.to_string(reason))
  end

  defp error(message, reason), do: %{"error" => %{"message" => message, "reason" => reason}}

  defp nilable(s) when is_binary(s) and s != "", do: s
  defp nilable(_), do: nil
end
