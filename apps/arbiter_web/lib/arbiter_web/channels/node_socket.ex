defmodule ArbiterWeb.NodeSocket do
  @moduledoc """
  The node agent's socket, `/node/socket` (`docs/design/remote-workers.md` §4.1,
  §4.2): one outbound WebSocket per node, carrying the `node:<node_id>` channel.

  ## Auth

  The node credential (`arbn_<id>.<secret>`) is checked by
  `Arbiter.Nodes.authenticate/1` — the same check `ArbiterWeb.Plugs.NodeAuth`
  makes for `/nodes/*` — and nothing else is admitted: a join token, an
  `Arbiter.MCP.Scope` token of any tier, a revoked node's credential, a wrong
  secret and an absent one are all the same refusal (HTTP 403 on the upgrade, no
  oracle between them). It is read from the `token` connect param (the design's
  shape) or the `x-arbiter-node-credential` request header, which keeps it out of
  a logged query string; the header wins.

  Refusals are rate limited (`Arbiter.Nodes.RateLimit`, rule `:socket_connect`:
  30 failures a minute globally). Once that bucket is empty even a good
  credential is refused until it refills, which is the intended trade: the
  limiter is for log noise and resource exhaustion, and an agent retries with
  backoff.

  ## Revocation

  `id/1` is `"node_socket:<node_id>"` (`Arbiter.Nodes.socket_id/1`), so
  `ArbiterWeb.Endpoint.broadcast(id, "disconnect", %{})` closes every socket the
  node has open (U14). `ArbiterWeb.NodeChannel` makes that broadcast when its
  session reports a revoke; `disconnect/1` is the same call for any other caller.
  """

  use Phoenix.Socket

  alias Arbiter.Nodes
  alias Arbiter.Nodes.RateLimit

  channel "node:*", ArbiterWeb.NodeChannel

  @credential_header "x-arbiter-node-credential"

  @impl true
  def connect(params, socket, connect_info) do
    key = source_key(connect_info)

    with :ok <- RateLimit.check(:socket_connect, key),
         {:ok, credential} <- credential(params, connect_info),
         {:ok, node} <- Nodes.authenticate(credential) do
      {:ok,
       socket
       |> assign(:node_id, node.id)
       |> assign(:node_name, node.name)
       |> assign(:agent_version, string(params["agent_version"]))
       |> assign(:proto, proto(params["proto"]))}
    else
      {:error, {:rate_limited, _}} ->
        :error

      _ ->
        RateLimit.record_failure(:socket_connect, key)
        :error
    end
  end

  @impl true
  def id(%Phoenix.Socket{assigns: %{node_id: node_id}}), do: Nodes.socket_id(node_id)

  @doc "Close every socket `node_id` has open."
  @spec disconnect(String.t()) :: :ok | {:error, term()}
  def disconnect(node_id) when is_binary(node_id),
    do: ArbiterWeb.Endpoint.broadcast(Nodes.socket_id(node_id), "disconnect", %{})

  defp credential(params, connect_info) do
    header =
      for {name, value} <- connect_info[:x_headers] || [],
          String.downcase(name) == @credential_header,
          do: value

    case header do
      [value | _] -> {:ok, value}
      [] -> param_credential(params)
    end
  end

  defp param_credential(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp param_credential(_), do: :error

  # Behind `tailscale serve` every peer is loopback, so the caller's tailnet
  # address is serve's X-Forwarded-For — trusted only when the peer is loopback
  # (the rule `DashboardAuth.Default` and the enroll route use).
  defp source_key(connect_info) do
    peer = get_in(connect_info, [:peer_data, :address])

    if loopback?(peer) do
      forwarded(connect_info) || format(peer)
    else
      format(peer)
    end
  end

  defp forwarded(connect_info) do
    Enum.find_value(connect_info[:x_headers] || [], fn {name, value} ->
      if String.downcase(name) == "x-forwarded-for" do
        value |> String.split(",") |> hd() |> String.trim()
      end
    end)
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp format(nil), do: "unknown"

  defp format(address) do
    case :inet.ntoa(address) do
      {:error, _} -> "unknown"
      charlist -> List.to_string(charlist)
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

  defp proto(value) when is_integer(value), do: value

  defp proto(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp proto(_), do: nil
end
