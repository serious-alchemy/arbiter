defmodule Arbiter.NodeAgent.PodChannel.CAStore.Secret do
  @moduledoc """
  The cluster's `Arbiter.NodeAgent.PodChannel.CAStore` (`docs/design/remote-workers.md`
  §16 K§2.4 step 2, K§12; ticket K14). The argument is the controller's
  `Arbiter.NodeAgent.K8s.Client`:

    * the CA certificate and private key live in the Secret `arbiter-controller-ca`
      (keys `ca.crt`, `ca.key`), readable only by the controller's Role;
    * the public certificate alone is published to the ConfigMap `arbiter-ca` (key
      `ca.crt`), which every worker pod mounts at `/etc/arb/ca`.

  The install renders both as empty placeholders, and the Role grants `get`/`update` on
  exactly those names, so this module **never creates** an object: a missing placeholder
  is an error. Every write is a `PUT` carrying the `resourceVersion` it read, so a
  concurrent writer is a conflict and not a lost update, and `save/2` refuses outright
  when the Secret already holds a CA: a stored CA is never replaced behind
  `Arbiter.NodeAgent.PodChannel.CA`'s back (that would orphan every running pod's
  identity). Half a CA, or a value that is not base64, is an error too.
  """
  @behaviour Arbiter.NodeAgent.PodChannel.CAStore

  alias Arbiter.NodeAgent.K8s.Client

  @secret "arbiter-controller-ca"
  @config_map "arbiter-ca"
  @cert "ca.crt"
  @key "ca.key"

  @impl true
  def load(%Client{} = client) do
    with {:ok, secret} <- Client.get_secret(client, @secret) do
      case secret["data"] || %{} do
        %{@cert => cert, @key => key} -> decode(cert, key)
        data when map_size(data) == 0 -> :none
        data -> if half?(data), do: {:error, :incomplete}, else: :none
      end
    end
  end

  @impl true
  def save(%Client{} = client, %{cert: cert, key: key}) do
    with {:ok, secret} <- Client.get_secret(client, @secret),
         :ok <- empty(secret) do
      data = %{@cert => Base.encode64(cert), @key => Base.encode64(key)}

      case Client.update_secret(client, Map.put(secret, "data", data)) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  def publish(%Client{} = client, cert_pem) do
    with {:ok, config_map} <- Client.get_config_map(client, @config_map) do
      data = config_map["data"] || %{}

      if data[@cert] == cert_pem do
        :ok
      else
        updated = Map.put(config_map, "data", Map.put(data, @cert, cert_pem))

        case Client.update_config_map(client, updated) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end
    end
  end

  defp decode(cert, key) do
    with {:ok, cert} <- Base.decode64(cert),
         {:ok, key} <- Base.decode64(key) do
      {:ok, %{cert: cert, key: key}}
    else
      :error -> {:error, :bad_encoding}
    end
  end

  defp half?(data), do: Map.has_key?(data, @cert) or Map.has_key?(data, @key)

  defp empty(secret) do
    if half?(secret["data"] || %{}), do: {:error, :already_stored}, else: :ok
  end
end
