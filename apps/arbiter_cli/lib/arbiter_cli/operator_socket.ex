defmodule ArbiterCli.OperatorSocket do
  @moduledoc """
  Client for the server's operator socket (`Arbiter.MCP.OperatorSocket`,
  bd-8381tk), the way `arb mcp token mint` and `arb init` get a coordinator
  token without already holding one.

  The server refuses to mint for an anonymous HTTP caller. On this socket it
  identifies the caller by the kernel's peer credentials instead, and
  refuses any process the server itself started (workers, reviewers,
  sessions, and whatever they run). Nothing secret is sent: running from the
  operator's own shell is the proof.

  Path, which must match `Arbiter.MCP.OperatorProof.socket_path/1`:
  `ARB_OPERATOR_SOCKET` if set, else
  `/run/user/<uid>/arbiter/operator-<port>.sock` when the host has a
  per-user runtime dir, else `~/.arbiter/run/operator-<port>.sock`. `<port>`
  is `ARB_HOST`'s port (default 4848). Tests use the `:bd2_operator_socket`
  process-dict hook.
  """

  alias ArbiterCli.Client
  alias ArbiterCli.Client.Error

  @timeout 10_000

  @spec path() :: String.t()
  def path do
    Process.get(:bd2_operator_socket) || env_path() || default_path()
  end

  @doc "Ask the server to mint a coordinator token. `params` may narrow it."
  @spec mint(map()) :: {:ok, map()} | {:error, Error.t()}
  def mint(params) do
    request(Map.merge(%{"tier" => "coordinator"}, params) |> Map.put("op", "mint"))
  end

  defp request(body) do
    path = path()

    with {:ok, sock} <- connect(path) do
      try do
        with :ok <- :gen_tcp.send(sock, [Jason.encode!(body), "\n"]),
             {:ok, line} <- :gen_tcp.recv(sock, 0, @timeout) do
          decode(line)
        else
          {:error, :timeout} ->
            {:error, %Error{kind: :timeout, message: "operator socket #{path} did not answer"}}

          {:error, reason} ->
            {:error,
             %Error{kind: :transport, message: "operator socket #{path}: #{inspect(reason)}"}}
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  defp connect(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], @timeout) do
      {:ok, sock} ->
        {:ok, sock}

      {:error, reason} ->
        {:error,
         %Error{
           kind: :connection_refused,
           message: "could not reach the operator socket at #{path} (#{reason})",
           hint:
             "run this on the server host, in your own shell, while the server is running " <>
               "(it opens the socket beside its HTTP listener). From another machine use " <>
               "`ssh <host> arb mcp token mint`, or set ARB_TOKEN to a coordinator token you already hold."
         }}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{"token" => token} = resp} when is_binary(token) ->
        {:ok, resp}

      {:ok, %{"error" => %{"message" => message} = err}} ->
        {:error, %Error{kind: :operator_proof, body: err, message: message, hint: hint(err)}}

      _ ->
        {:error, %Error{kind: :decode, message: "operator socket sent an unreadable reply"}}
    end
  end

  defp hint(%{"reason" => reason})
       when reason in ["spawned_by_arbiter", "in_arbiter_cgroup", "in_session_scope"] do
    "only the operator mints coordinator tokens, from their own shell. Workers and " <>
      "sessions get their token from the server at dispatch (see docs/worker-security.md)."
  end

  defp hint(_), do: "see docs/worker-security.md, \"Operator proof for token minting\""

  defp env_path do
    case System.get_env("ARB_OPERATOR_SOCKET") do
      p when is_binary(p) and p != "" -> Path.expand(p)
      _ -> nil
    end
  end

  defp default_path do
    port = URI.parse(Client.base_url()).port || 4848
    Path.join(default_dir(), "operator-#{port}.sock")
  end

  defp default_dir do
    runtime =
      case File.stat("/proc/self") do
        {:ok, %{uid: uid}} -> "/run/user/#{uid}"
        _ -> nil
      end

    if runtime && File.dir?(runtime),
      do: Path.join(runtime, "arbiter"),
      else: Path.expand("~/.arbiter/run")
  end
end
