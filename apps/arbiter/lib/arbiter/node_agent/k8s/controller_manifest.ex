defmodule Arbiter.NodeAgent.K8s.ControllerManifest do
  @moduledoc """
  The `Deployment arbiter-controller` of `docs/design/remote-workers.md` §2.2,
  with the reachability variant of §2.3 (`?reach=`):

    * `:direct` (default) — the controller dials `primary_url` itself, which must
      be a reachable `https` endpoint with a verified chain (the agent refuses
      plain `http` to a non-loopback host).
    * `:tailscale` — adds a **tailscale sidecar** in userspace networking
      (`TS_USERSPACE=true`): no `NET_ADMIN`, no `/dev/net/tun`, no privilege. It
      exposes an outbound HTTP proxy on `127.0.0.1:1055`, and the controller is
      pointed at it with `ARB_NODE_PROXY`. The auth key comes from the Secret
      `arbiter-tailscale` (key `authkey`): an ephemeral, pre-authorised key tagged
      `tag:arbiter-node`. Readiness is `tailscale status` = Running, not "the proxy
      port is open": a logged-out `tailscaled` listens and answers every CONNECT
      with 500.

  Returns plain maps (JSON-shaped, as `PodSpec` does).
  """

  @uid 10_001
  @name "arbiter-controller"
  @proxy_addr "127.0.0.1:1055"
  @tailscale_image "ghcr.io/tailscale/tailscale:stable"
  @tailscale_secret "arbiter-tailscale"
  @tailscale_tag "tag:arbiter-node"
  @socket "/tmp/tailscaled.sock"

  @type reach :: :direct | :tailscale

  @doc "Parse the `?reach=` query value."
  @spec parse_reach(String.t() | nil) :: {:ok, reach()} | {:error, {:bad_reach, term()}}
  def parse_reach(value) when value in [nil, "", "direct"], do: {:ok, :direct}
  def parse_reach("tailscale"), do: {:ok, :tailscale}
  def parse_reach(other), do: {:error, {:bad_reach, other}}

  @doc """
  Options: `:image`, `:primary_url`, `:node_name` (required), `:namespace`
  (default `arbiter-workers`), `:reach` (default `:direct`).
  """
  @spec deployment(keyword()) :: {:ok, map()} | {:error, term()}
  def deployment(opts) do
    reach = Keyword.get(opts, :reach, :direct)

    with {:ok, image} <- fetch(opts, :image),
         {:ok, primary_url} <- fetch(opts, :primary_url),
         {:ok, node_name} <- fetch(opts, :node_name),
         true <- reach in [:direct, :tailscale] || {:error, {:bad_reach, reach}} do
      namespace = Keyword.get(opts, :namespace, "arbiter-workers")
      {:ok, build(image, primary_url, node_name, namespace, reach)}
    end
  end

  defp fetch(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp build(image, primary_url, node_name, namespace, reach) do
    labels = %{"app.kubernetes.io/name" => @name}

    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{"name" => @name, "namespace" => namespace},
      "spec" => %{
        "replicas" => 1,
        "strategy" => %{"type" => "Recreate"},
        "selector" => %{"matchLabels" => labels},
        "template" => %{
          "metadata" => %{
            "labels" => Map.put(labels, "app.kubernetes.io/component", "controller")
          },
          "spec" => %{
            "serviceAccountName" => @name,
            "priorityClassName" => "arbiter-worker",
            "securityContext" => %{
              "runAsNonRoot" => true,
              "runAsUser" => @uid,
              "runAsGroup" => @uid,
              "seccompProfile" => %{"type" => "RuntimeDefault"}
            },
            "containers" => [controller(image, primary_url, node_name, reach)] ++ sidecar(reach),
            "volumes" => volumes(reach)
          }
        }
      }
    }
  end

  defp controller(image, primary_url, node_name, reach) do
    env =
      [
        %{"name" => "ARB_ROLE", "value" => "agent"},
        %{"name" => "ARB_AGENT_BACKEND", "value" => "k8s"},
        %{"name" => "ARB_PRIMARY_URL", "value" => primary_url},
        %{"name" => "ARB_NODE_NAME", "value" => node_name}
      ] ++ proxy_env(reach)

    %{
      "name" => "controller",
      "image" => image,
      "env" => env,
      "securityContext" => hardening(),
      "resources" => %{
        "requests" => %{"cpu" => "100m", "memory" => "256Mi"},
        "limits" => %{"cpu" => "1", "memory" => "512Mi"}
      }
    }
  end

  defp proxy_env(:tailscale),
    do: [%{"name" => "ARB_NODE_PROXY", "value" => "http://" <> @proxy_addr}]

  defp proxy_env(:direct), do: []

  defp sidecar(:direct), do: []

  defp sidecar(:tailscale) do
    [
      %{
        "name" => "tailscale",
        "image" => @tailscale_image,
        "env" => [
          %{"name" => "TS_USERSPACE", "value" => "true"},
          %{"name" => "TS_OUTBOUND_HTTP_PROXY_LISTEN", "value" => @proxy_addr},
          %{"name" => "TS_EXTRA_ARGS", "value" => "--advertise-tags=" <> @tailscale_tag},
          %{"name" => "TS_STATE_DIR", "value" => "/tmp/tailscale"},
          %{"name" => "TS_SOCKET", "value" => @socket},
          %{
            "name" => "TS_AUTHKEY",
            "valueFrom" => %{
              "secretKeyRef" => %{"name" => @tailscale_secret, "key" => "authkey"}
            }
          }
        ],
        "readinessProbe" => %{
          "exec" => %{
            "command" => [
              "sh",
              "-c",
              "tailscale --socket=#{@socket} status --json | grep -q '\"BackendState\": \"Running\"'"
            ]
          },
          "periodSeconds" => 5,
          "failureThreshold" => 12
        },
        "securityContext" => hardening(),
        "resources" => %{
          "requests" => %{"cpu" => "50m", "memory" => "64Mi"},
          "limits" => %{"cpu" => "500m", "memory" => "256Mi"}
        },
        "volumeMounts" => [%{"name" => "tmp", "mountPath" => "/tmp"}]
      }
    ]
  end

  defp volumes(:direct), do: []
  defp volumes(:tailscale), do: [%{"name" => "tmp", "emptyDir" => %{"sizeLimit" => "128Mi"}}]

  defp hardening do
    %{
      "allowPrivilegeEscalation" => false,
      "privileged" => false,
      "readOnlyRootFilesystem" => true,
      "capabilities" => %{"drop" => ["ALL"]}
    }
  end
end
