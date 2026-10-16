defmodule Arbiter.Nodes.ClusterInstall do
  @moduledoc """
  What the primary tells an operator adding a **cluster** node (`docs/design/remote-workers.md`
  K§2.1, ticket K9). The "Add node" modal, `POST /api/nodes/join-tokens` (and so
  `arb node add --kind cluster`) all build their output here, so the three surfaces
  cannot disagree.

    * `plan/2` — the form values to the Helm install (KH9: the namespace, the join Secret,
      `helm install` fed by `GET /nodes/join/values.yaml`) and, when `nodes.registry` is set,
      the raw manifest URL, the `kubectl apply` command and the controller image.
    * `helm_upgrade_command/4` — the `helm upgrade` a Helm-installed node needs instead.
    * `set_image_command/2` — the exact `kubectl set image` an `outdated` cluster node
      needs when its Role cannot patch its own Deployment.
    * `controller_facts/1` — what the enrolled controller itself asks for at boot
      (`GET /nodes/cluster`, K14): the install id, the registry, the canary's image.

  Nothing here handles a secret. The join token is never part of a URL or a command: the
  Secret command reads it from the operator's terminal (`read -rs`), so it stays out of
  shell history and `ps`.
  """

  alias Arbiter.NodeAgent.K8s.InstallManifest
  alias Arbiter.Nodes.Agent
  alias Arbiter.Nodes.InstallId
  alias Arbiter.Settings
  alias Arbiter.Worker.Image.Publisher

  @form_keys ~w(name namespace max cpu memory node_selector pull_secret registries reach admission self_upgrade api_cidrs cluster_cidrs primary_cidrs proxy_url proxy_cidrs)

  @default_chart "oci://ghcr.io/serious-alchemy/charts/arbiter-node"
  # Where release CI publishes the controller image (`.github/workflows/release.yml`).
  @default_controller_image "ghcr.io/serious-alchemy/arbiter-controller"

  @type helm_command :: %{values_url: String.t(), install_command: String.t()}

  @type helm :: %{
          chart_ref: String.t(),
          chart_version: String.t(),
          release: String.t(),
          values_url: String.t(),
          namespace_command: String.t(),
          secret_command: String.t(),
          install_command: String.t(),
          split: %{bootstrap: helm_command(), node: helm_command()}
        }

  # `manifest_url`, `apply_command` and `image` are `nil` while `nodes.registry` is unset
  # (`registry_set` is `false`): the raw manifests need a controller image the primary
  # publishes there, the chart pulls its own.
  @type plan :: %{
          manifest_url: String.t() | nil,
          apply_command: String.t() | nil,
          secret_command: String.t(),
          pull_secret_commands: [%{registry: String.t(), secret: String.t(), command: String.t()}],
          namespace: String.t(),
          image: String.t() | nil,
          node_name: String.t(),
          registry_set: boolean(),
          helm: helm()
        }

  @doc "The chart reference for `helm install`: `nodes.chart_ref`, else the release repo's."
  @spec chart_ref() :: String.t()
  def chart_ref, do: Settings.nodes_chart_ref() || @default_chart

  @doc """
  What `GET /nodes/join/values.yaml` needs from the primary: its public URL and the chart
  reference, plus `nodes.registry` when set (the chart does not need it for its own
  image, so its absence is not an error here). `{:error, :no_public_url |
  {:insecure_public_url, url}}`.
  """
  @spec values_server() ::
          {:ok, InstallManifest.values_server()}
          | {:error, :no_public_url | {:insecure_public_url, String.t()}}
  def values_server do
    with {:ok, url} <- present(Settings.nodes_public_url(), :no_public_url),
         :ok <- controller_accepts(url) do
      {:ok,
       [
         primary_url: url,
         registry: Settings.nodes_registry(),
         chart_ref: chart_ref(),
         image_repository: @default_controller_image,
         image_tag: Agent.release_tag()
       ]}
    end
  end

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
  @spec server_opts(keyword()) ::
          {:ok, InstallManifest.server()} | {:error, atom() | {:insecure_public_url, String.t()}}
  def server_opts(opts \\ []) do
    with {:ok, url} <- present(Settings.nodes_public_url(), :no_public_url),
         :ok <- controller_accepts(url),
         {:ok, registry} <- present(Settings.nodes_registry(), :no_registry),
         {:ok, version} <-
           present(Keyword.get_lazy(opts, :version, &Agent.release_tag/0), :no_release) do
      {:ok, [image: image(registry, version), primary_url: url, registry: registry]}
    end
  end

  # The controller refuses a primary URL that is neither https nor loopback http
  # (`Arbiter.NodeAgent.Config`); rendering one would leave it retrying forever.
  defp controller_accepts(url) do
    case Arbiter.NodeAgent.Config.validate_url(url) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:insecure_public_url, url}}
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
  What a cluster controller asks for at every boot (`GET /nodes/cluster`, K14), before it
  can label, build or watch a pod:

    * `install_id` — `Arbiter.Nodes.InstallId`: the `arbiter.dev/install` label of every
      pod, and what a run spec's `install` and a `reap{install}` must match;
    * `registry` — `nodes.registry`: the prefix the pod builder pins every image under;
    * `canary_image` — the image the NetworkPolicy canary runs: the worker image published
      since boot when there is one, else the controller image (both digest-pinned and under
      `registry`), `nil` while neither exists. The controller image is always the fallback
      because the primary publishes it at every boot, before any run needs a worker image,
      so a fresh install does not wait on a remote run to prove its network policy.

  Options: `:published` (the publisher's list, a seam for tests).
  """
  @spec controller_facts(keyword()) :: %{
          install_id: String.t(),
          registry: String.t() | nil,
          canary_image: String.t() | nil
        }
  def controller_facts(opts \\ []) do
    registry = Settings.nodes_registry()
    published = Keyword.get_lazy(opts, :published, &Publisher.published/0)

    %{
      install_id: InstallId.get(),
      registry: registry,
      canary_image: canary_image(published, registry)
    }
  end

  defp canary_image(_published, registry) when registry in [nil, ""], do: nil

  defp canary_image(published, registry) do
    Enum.find_value([:worker, :controller], fn kind ->
      Enum.find_value(published, fn
        %{kind: ^kind, ref: ref} when is_binary(ref) ->
          if String.starts_with?(ref, registry <> "/"), do: ref

        _ ->
          nil
      end)
    end)
  end

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
  @spec plan(map(), keyword()) ::
          {:ok, plan()}
          | {:error, [String.t()] | atom() | {:insecure_public_url, String.t()}}
  def plan(params, opts \\ []) do
    with {:ok, spec} <- InstallManifest.parse(params),
         {:ok, public_url, version} <- helm_server_opts(opts) do
      raw = raw_plan(params, opts)

      {:ok,
       %{
         manifest_url: raw[:manifest_url],
         apply_command: raw[:apply_command],
         secret_command: secret_command(spec.namespace),
         pull_secret_commands: pull_secret_commands(spec.registries, spec.namespace),
         namespace: spec.namespace,
         image: raw[:image],
         node_name: spec.node_name,
         registry_set: raw != %{},
         helm: helm_plan(spec, params, public_url, version)
       }}
    end
  end

  # What the Helm install needs from the primary: where the chart's controller dials, and
  # which chart version (the release's). No `nodes.registry` is needed.
  defp helm_server_opts(opts) do
    with {:ok, url} <- present(Settings.nodes_public_url(), :no_public_url),
         :ok <- controller_accepts(url),
         {:ok, version} <-
           present(Keyword.get_lazy(opts, :version, &Agent.release_tag/0), :no_release) do
      {:ok, url, String.trim_leading(version, "v")}
    end
  end

  # The raw manifests are only offered where the primary can name a controller image.
  defp raw_plan(params, opts) do
    case server_opts(opts) do
      {:ok, server} ->
        url = manifest_url(server[:primary_url], params)
        %{manifest_url: url, apply_command: apply_command(url), image: server[:image]}

      {:error, _} ->
        %{}
    end
  end

  defp helm_plan(spec, params, public_url, version) do
    chart = chart_ref()
    release = release_name(spec.node_name)
    values_url = values_url(public_url, params)
    install = &install_command(&1, &2, chart, version, spec.namespace)

    %{
      chart_ref: chart,
      chart_version: version,
      release: release,
      values_url: values_url,
      namespace_command: namespace_command(spec.namespace),
      secret_command: secret_command(spec.namespace),
      install_command: install.(release, values_url),
      split: %{
        bootstrap:
          split_command(public_url, params, "bootstrap", release <> "-bootstrap", install),
        node: split_command(public_url, params, "node", release, install)
      }
    }
  end

  defp split_command(public_url, params, part, release, install) do
    url = values_url(public_url, params, [{"part", part}])
    %{values_url: url, install_command: install.(release, url)}
  end

  defp install_command(release, values_url, chart, version, namespace) do
    ~s(curl -fsSL "#{values_url}" | helm install #{release} #{chart} ) <>
      "--version #{version} --namespace #{namespace} -f -"
  end

  # A Helm release name is a DNS-1123 label of at most 53 characters; a node name allows more.
  defp release_name(node_name) do
    name =
      node_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 40)
      |> String.trim("-")

    if name == "", do: "arbiter-node", else: name
  end

  @doc """
  Create the namespace and label it for Pod Security: a cluster-admin act, because the chart
  does not template the `Namespace` (`docs/design/remote-workers.md` §20.6).
  """
  @spec namespace_command(String.t()) :: String.t()
  def namespace_command(namespace) do
    labels =
      Enum.map_join(~w(enforce audit warn), " ", &"pod-security.kubernetes.io/#{&1}=restricted")

    "kubectl create namespace #{namespace} && kubectl label namespace #{namespace} " <>
      "pod-security.kubernetes.io/enforce-version=latest #{labels}"
  end

  @doc "`<public_url>/nodes/join/k8s.yaml?...`, from the known form keys only."
  @spec manifest_url(String.t(), map()) :: String.t()
  def manifest_url(public_url, params),
    do: public_url <> "/nodes/join/k8s.yaml?" <> query(params, [])

  @doc """
  `<public_url>/nodes/join/values.yaml?...`: the chart values for the same form values
  (`extra` adds query pairs such as `part`).
  """
  @spec values_url(String.t(), map(), [{String.t(), String.t()}]) :: String.t()
  def values_url(public_url, params, extra \\ []),
    do: public_url <> "/nodes/join/values.yaml?" <> query(params, extra)

  defp query(params, extra) do
    pairs =
      for key <- @form_keys,
          value = params[key],
          is_binary(value) and String.trim(value) != "",
          do: {key, String.trim(value)}

    URI.encode_query(pairs ++ extra)
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
  The one command that moves a Helm-installed cluster node to chart `version` (KH8). Helm
  owns that Deployment, so `kubectl set image` on it would fight the release.
  """
  @spec helm_upgrade_command(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def helm_upgrade_command(release, chart, version, namespace),
    do:
      "helm upgrade #{release} #{chart} --version #{version} -n #{namespace} " <>
        "--reset-then-reuse-values"

  @doc """
  KH13 (§20.10): one command per registry that names a pull secret, creating it with a
  read-only deploy token read from the terminal. `kubectl create secret docker-registry
  --docker-password=` would put the password on argv, so the dockerconfigjson is built by
  `printf` from two `read`s (`-s` for the password) and piped in. The registry host is
  the first path segment of the prefix.
  """
  @spec pull_secret_commands([%{prefix: String.t(), pull_secret: String.t() | nil}], String.t()) ::
          [%{registry: String.t(), secret: String.t(), command: String.t()}]
  def pull_secret_commands(registries, namespace) do
    for %{prefix: prefix, pull_secret: secret} <- registries, is_binary(secret) do
      host = prefix |> String.split("/", parts: 2) |> hd()

      %{
        registry: prefix,
        secret: secret,
        command:
          "read -r U && read -rs P && printf " <>
            ~s|'{"auths":{"#{host}":{"username":"%s","password":"%s"}}}' "$U" "$P" \| | <>
            "kubectl -n #{namespace} create secret generic #{secret} " <>
            "--type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin"
      }
    end
  end

  @doc """
  The one command that moves an `outdated` cluster node to `image` by hand: its Deployment
  is `arbiter-controller` and its container `controller` (`ControllerManifest`).
  """
  @spec set_image_command(String.t(), String.t()) :: String.t()
  def set_image_command(namespace, image),
    do: "kubectl -n #{namespace} set image deployment/arbiter-controller controller=#{image}"
end
