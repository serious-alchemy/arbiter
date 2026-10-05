defmodule Arbiter.Test.StubMcpServer do
  @moduledoc """
  A minimal MCP server (Streamable HTTP, JSON responses) on a loopback port, for
  the live podman Codex test (bd-50d5j6): it stands in for Arbiter's `/mcp` so a
  real `codex exec` in a container can be seen reaching it through the Arbiter
  bridge with its bearer token.

  Serves one tool, `ping`. Every JSON-RPC request is reported to `owner` as
  `{:mcp_request, %{rpc: method, authorization: header | nil}}`.
  """

  @doc "Starts listening; `{:ok, %{port: port, listener: socket}}`."
  @spec start(pid()) :: {:ok, %{port: :inet.port_number(), listener: port()}}
  def start(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> accept(listener, owner) end)
    {:ok, %{port: port, listener: listener}}
  end

  @spec stop(%{listener: port()}) :: :ok
  def stop(%{listener: listener}), do: :gen_tcp.close(listener)

  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, sock} ->
        pid = spawn(fn -> serve(sock, owner) end)
        :gen_tcp.controlling_process(sock, pid)
        accept(listener, owner)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, owner) do
    case read_request(sock, <<>>) do
      {:ok, method, headers, body} ->
        respond(sock, method, headers, body, owner)
        serve(sock, owner)

      :closed ->
        :gen_tcp.close(sock)
    end
  end

  defp read_request(sock, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method | _] = String.split(request_line, " ")

        headers =
          Map.new(header_lines, fn line ->
            [k, v] = String.split(line, ":", parts: 2)
            {String.downcase(k), String.trim(v)}
          end)

        length = headers |> Map.get("content-length", "0") |> String.to_integer()
        read_body(sock, method, headers, rest, length)

      _ ->
        case :gen_tcp.recv(sock, 0, 60_000) do
          {:ok, data} -> read_request(sock, buffer <> data)
          {:error, _} -> :closed
        end
    end
  end

  defp read_body(sock, method, headers, body, length) when byte_size(body) < length do
    case :gen_tcp.recv(sock, length - byte_size(body), 60_000) do
      {:ok, data} -> read_body(sock, method, headers, body <> data, length)
      {:error, _} -> :closed
    end
  end

  defp read_body(_sock, method, headers, body, _length), do: {:ok, method, headers, body}

  defp respond(sock, "POST", headers, body, owner) do
    case Jason.decode(body) do
      {:ok, %{"method" => rpc} = msg} ->
        send(owner, {:mcp_request, %{rpc: rpc, authorization: headers["authorization"]}})
        reply(sock, rpc, msg)

      _ ->
        send_response(sock, 400, "")
    end
  end

  defp respond(sock, _method, _headers, _body, _owner), do: send_response(sock, 405, "")

  defp reply(sock, "initialize", %{"id" => id, "params" => params}) do
    json(sock, id, %{
      "protocolVersion" => params["protocolVersion"],
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "stub-arbiter", "version" => "1"}
    })
  end

  defp reply(sock, "tools/list", %{"id" => id}) do
    json(sock, id, %{
      "tools" => [
        %{
          "name" => "ping",
          "description" => "Returns pong. Call it with no arguments.",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    })
  end

  defp reply(sock, "tools/call", %{"id" => id}) do
    json(sock, id, %{"content" => [%{"type" => "text", "text" => "pong-from-stub"}]})
  end

  defp reply(sock, _rpc, %{"id" => id}), do: json(sock, id, %{})
  defp reply(sock, _rpc, _notification), do: send_response(sock, 202, "")

  defp json(sock, id, result) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    send_response(sock, 200, body, [{"content-type", "application/json"}])
  end

  defp send_response(sock, status, body, headers \\ []) do
    lines =
      ["HTTP/1.1 #{status} X", "content-length: #{byte_size(body)}"] ++
        Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)

    :gen_tcp.send(sock, Enum.join(lines, "\r\n") <> "\r\n\r\n" <> body)
  end
end
