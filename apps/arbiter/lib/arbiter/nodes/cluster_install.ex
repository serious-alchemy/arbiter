defmodule Arbiter.Nodes.ClusterInstall do
  @moduledoc """
  What the primary tells an operator adding a **cluster** node (`docs/design/remote-workers.md`
  K§2.1, ticket K9). The "Add node" modal, `POST /api/nodes/join-tokens` (and so
  `arb node add --kind cluster`) all build their output here, so the three surfaces
  cannot disagree.

    * `plan/2` — the form values to the manifest URL, the `kubectl apply` command, the
      join-Secret command and the controller image.
    * `set_image_command/2` — the exact `kubectl set image` an `outdated` cluster node
      needs when its Role cannot patch its own Deployment.

  Nothing here handles a secret. The join token is never part of a URL or a command: the
  Secret command reads it from the operator's terminal (`read -rs`), so it stays out of
  shell history and `ps`.
  """

  alias Arbiter.NodeAgent.K8s.InstallManifest
  alias Arbiter.Nodes.Agent
  alias Arbiter.Settings

  @form_keys ~w(name namespace max cpu memory node_selector pull_secret reach admission self_upgrade api_cidrs cluster_cidrs)

  @type plan :: %{
          manifest_url: String.t(),
          apply_command: String.t(),
          secret_command: String.t(),
          namespace: String.t(),
          image: String.t(),
          node_name: String.t()
        }

  @doc "The namespace the manifests default to."
  @spec default_namespace() :: String.t()
  def default_namespace, do: InstallManifest.default_namespace()

  @doc "The form fields that are carried into the manifest URL."
  @spec form_keys() :: [String.t()]
  def form_keys, do: @form_keys

  @doc """
  The server-side values the renderer needs, or why there are none: `{:error,
  :no_public_url}` (`nodes.public_url` unset), `{:error, :no_registry}` (`nodes.registry`
  unset, so a cluster has no image it could pull; the doctor says how to set it) or
  `{:error, :no_release}` (no deployed release to name an image for). Options:
  `:version` (a seam for tests).
  """
  @spec server_opts(keyword()) :: {:ok, InstallManifest.server()} | {:error, atom()}
  def server_opts(opts \\ []) do
    with {:ok, url} <- present(Settings.nodes_public_url(), :no_public_url),
         {:ok, registry} <- present(Settings.nodes_registry(), :no_registry),
         {:ok, version} <-
           present(Keyword.get_lazy(opts, :version, &Agent.release_tag/0), :no_release) do
      {:ok, [image: image(registry, version), primary_url: url, registry: registry]}
    end
  end

  @doc """
  The controller image of the running release alone (no `nodes.public_url` needed):
  what an upgrade names. `{:error, :no_registry | :no_release}`.
  """
  @spec controller_image(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def controller_image(opts \\ []) do
    with {:ok, registry} <- present(Settings.nodes_registry(), :no_registry),
         {:ok, version} <-
           present(Keyword.get_lazy(opts, :version, &Agent.release_tag/0), :no_release) do
      {:ok, image(registry, version)}
    end
  end

  defp present(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, error), do: {:error, error}

  @doc """
  The controller image for `version`, as `Arbiter.Worker.Image.Publisher` publishes it
  (`<registry>/controller:<version>`, with the tag characters it allows).
  """
  @spec image(String.t(), String.t()) :: String.t()
  def image(registry, version),
    do: registry <> "/controller:" <> Regex.replace(~r/[^A-Za-z0-9_.-]/, version, "_")

  @doc """
  The operator's output for `params` (the form / CLI values, string keys; see
  `Arbiter.NodeAgent.K8s.InstallManifest.parse/1`). `{:error, [message]}` when a value
  is refused.
  """
  @spec plan(map(), keyword()) :: {:ok, plan()} | {:error, [String.t()] | atom()}
  def plan(params, opts \\ []) do
    with {:ok, spec} <- InstallManifest.parse(params),
         {:ok, server} <- server_opts(opts) do
      url = manifest_url(server[:primary_url], params)

      {:ok,
       %{
         manifest_url: url,
         apply_command: apply_command(url),
         secret_command: secret_command(spec.namespace),
         namespace: spec.namespace,
         image: server[:image],
         node_name: spec.node_name
       }}
    end
  end

  @doc "`<public_url>/nodes/join/k8s.yaml?...`, from the known form keys only."
  @spec manifest_url(String.t(), map()) :: String.t()
  def manifest_url(public_url, params) do
    query =
      for key <- @form_keys,
          value = params[key],
          is_binary(value) and String.trim(value) != "",
          do: {key, String.trim(value)}

    public_url <> "/nodes/join/k8s.yaml?" <> URI.encode_query(query)
  end

  @doc "Apply the rendered manifests straight from the primary (it holds no secret)."
  @spec apply_command(String.t()) :: String.t()
  def apply_command(url), do: ~s|kubectl apply -f <(curl -fsSL "#{url}")|

  @doc """
  Create the join Secret with the token read from the terminal: not in the shell
  history, not in argv.
  """
  @spec secret_command(String.t()) :: String.t()
  def secret_command(namespace) do
    "read -rs T && printf %s \"$T\" | kubectl -n #{namespace} create secret generic " <>
      "arbiter-join --from-file=token=/dev/stdin"
  end

  @doc """
  The one command that moves an `outdated` cluster node to `image` by hand: its Deployment
  is `arbiter-controller` and its container `controller` (`ControllerManifest`).
  """
  @spec set_image_command(String.t(), String.t()) :: String.t()
  def set_image_command(namespace, image),
    do: "kubectl -n #{namespace} set image deployment/arbiter-controller controller=#{image}"
end
