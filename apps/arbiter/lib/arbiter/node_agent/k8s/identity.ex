defmodule Arbiter.NodeAgent.K8s.Identity do
  @moduledoc """
  What a cluster controller must know about itself before it can label, build or watch a
  pod (ticket K14): the `Arbiter.NodeAgent.K8s.Controller`'s `:identity`, which is also
  every pod's `arbiter.dev/*` labels and the facts `Arbiter.NodeAgent.K8s.PodSpec` needs.

  | fact | from |
  |---|---|
  | `install_id`, `registry` | the primary, `GET /nodes/cluster` with the node credential (`primary_facts/1`); asked again on every boot, so a changed `nodes.registry` reaches the controller at its next restart |
  | `node_id` | the credential (`arbn_<id>.…`) |
  | `owner_uid` | the controller's own Deployment (`get deployments/arbiter-controller`): pods are owned by it, so uninstalling removes them (K§3.6) |
  | `bridge_addr` | the controller Service's `clusterIP` (`get services/arbiter-controller`): what pods dial, and what the pod channel's server certificate names |
  | `gate_addr` | `KUBERNETES_SERVICE_HOST:KUBERNETES_SERVICE_PORT`, the API server's Service: an address no worker may reach, which the per-pod netpol gate dials until it is refused |
  | `own_pod` | `HOSTNAME`, the pod's name: the Lease holder, and never swept |
  | `max_wall_s` | `ARB_K8S_MAX_WALL_S`, default #{86_400} (a day): a pod's `activeDeadlineSeconds` is this plus 30 minutes, the backstop for a pod whose controller is gone |

  The primary also names `canary_image`, the image the NetworkPolicy canary runs
  (`Arbiter.Nodes.ClusterInstall.controller_facts/1`).
  """

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.K8s.Client

  @deployment "arbiter-controller"
  @service "arbiter-controller"
  @default_max_wall_s 86_400
  @max_wall_s 31_536_000

  @type facts :: %{
          install_id: String.t(),
          registry: String.t() | nil,
          canary_image: String.t() | nil
        }

  @doc "The primary's facts for this controller (`GET /nodes/cluster`)."
  @spec primary_facts(Config.t()) :: {:ok, facts()} | {:error, term()}
  def primary_facts(%Config{} = config) do
    request =
      Keyword.merge(
        [
          url: Config.http_url(config, "/nodes/cluster"),
          headers: [
            {"authorization", "Bearer " <> config.credential},
            {"accept", "application/json"}
          ],
          receive_timeout: 30_000,
          retry: false
        ],
        config.req_options || []
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{"install_id" => install} = body}}
      when is_binary(install) and install != "" ->
        {:ok,
         %{
           install_id: install,
           registry: string(body["registry"]),
           canary_image: string(body["canary_image"])
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:primary, status, message(body)}}

      {:error, exception} ->
        {:error, {:primary_unreachable, exception}}
    end
  end

  @doc """
  The controller's identity from the primary's `facts`, the API and the pod's
  environment (`:env`, default `System.get_env/0`).
  """
  @spec resolve(Client.t(), Config.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(%Client{} = client, %Config{} = config, facts, opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with {:ok, registry} <- registry(facts),
         {:ok, owner_uid} <- owner_uid(client),
         {:ok, bridge_addr} <- bridge_addr(client),
         {:ok, gate_addr} <- gate_addr(env) do
      {:ok,
       %{
         registry: registry,
         install_id: facts.install_id,
         node_id: config.node_id,
         owner_uid: owner_uid,
         bridge_addr: bridge_addr,
         gate_addr: gate_addr,
         own_pod: env["HOSTNAME"],
         max_wall_s: max_wall_s(env)
       }}
    end
  end

  defp registry(%{registry: registry}) when is_binary(registry) and registry != "",
    do: {:ok, registry}

  defp registry(_facts), do: {:error, :no_registry}

  defp owner_uid(client) do
    case Client.get_deployment(client, @deployment) do
      {:ok, %{"metadata" => %{"uid" => uid}}} when is_binary(uid) and uid != "" -> {:ok, uid}
      {:ok, _} -> {:error, {:deployment, :no_uid}}
      {:error, reason} -> {:error, {:deployment, reason}}
    end
  end

  defp bridge_addr(client) do
    case Client.get_service(client, @service) do
      {:ok, %{"spec" => %{"clusterIP" => ip}}} when is_binary(ip) and ip not in ["", "None"] ->
        {:ok, ip}

      {:ok, _} ->
        {:error, {:service, :no_cluster_ip}}

      {:error, reason} ->
        {:error, {:service, reason}}
    end
  end

  defp gate_addr(env) do
    case env["KUBERNETES_SERVICE_HOST"] do
      host when is_binary(host) and host != "" ->
        {:ok, host <> ":" <> (env["KUBERNETES_SERVICE_PORT"] || "443")}

      _ ->
        {:error, :no_gate_addr}
    end
  end

  defp max_wall_s(env) do
    case Integer.parse(env["ARB_K8S_MAX_WALL_S"] || "") do
      {n, ""} when n > 0 and n <= @max_wall_s -> n
      _ -> @default_max_wall_s
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp message(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp message(body), do: inspect(body, limit: 5, printable_limit: 200)
end
