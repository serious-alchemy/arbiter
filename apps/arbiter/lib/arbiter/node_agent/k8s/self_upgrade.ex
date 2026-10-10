defmodule Arbiter.NodeAgent.K8s.SelfUpgrade do
  @moduledoc """
  The controller moves itself to a new image (`docs/design/remote-workers.md` K§2.4,
  ticket K9). A cluster node's image is immutable, so the tarball upgrade of a machine
  does not apply: the primary's `hello_ok` carries `upgrade{version, image}`
  (`caps.upgrade = "image"`), and with `rbac.selfUpgrade` on (the default in the rendered
  manifests) this module patches **the controller's own Deployment's image**; the
  `Recreate` strategy restarts it, and worker pods survive a controller restart (K§3.5).

  ## What it will and will not touch

    * One Deployment, `arbiter-controller`, in the controller's own namespace (the
      `Client`'s), and one container in it, `controller`. Those are constants here, not
      options and not fields of the spec: a spec that names another Deployment, container
      or namespace is read for its `image` only. The Role the renderer emits grants `get`
      and (only with `rbac.selfUpgrade`) `patch` on exactly that name, so the API server
      enforces the same line.
    * An image of **the repository it already runs** (tag or digest changes, nothing else).
      A compromised or confused primary cannot point the controller at an arbitrary image
      through this path, and a string that is not an image reference is refused before it
      reaches the API.
    * Nothing when `ARB_K8S_SELF_UPGRADE` is not `true` (what the manifest sets from
      `rbac.selfUpgrade`) or when a run is live (`:idle?`, the conservative `when_idle`
      default), and nothing when the API says 403: the caller then reports `outdated` with
      the command `Arbiter.Nodes.ClusterInstall.set_image_command/2` builds.
  """

  alias Arbiter.NodeAgent.K8s.Client

  @deployment "arbiter-controller"
  @container "controller"

  @image_re ~r|\A[a-z0-9][a-z0-9._-]*(:\d{1,5})?(/[a-z0-9][a-z0-9._-]*)+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(@sha256:[0-9a-f]{64})?\z|

  @type result ::
          {:ok, :patched | :current}
          | {:error,
             :disabled | :busy | :bad_image | :not_found | {:forbidden, String.t()} | term()}

  @doc "Whether the manifest let this controller patch itself (`ARB_K8S_SELF_UPGRADE=true`)."
  @spec available?(%{optional(String.t()) => String.t()}) :: boolean()
  def available?(env \\ System.get_env()), do: env["ARB_K8S_SELF_UPGRADE"] == "true"

  @doc """
  Move to `spec["image"]` (the `upgrade` map of a `hello_ok`). Options: `:enabled?`
  (default `available?/1`), `:env` (what `available?/1` reads, for tests), `:idle?`
  (default `true`: no run is live).
  """
  @spec run(Client.t(), map(), keyword()) :: result()
  def run(%Client{} = client, spec, opts \\ []) when is_map(spec) do
    enabled? =
      Keyword.get_lazy(opts, :enabled?, fn -> available?(opts[:env] || System.get_env()) end)

    cond do
      not enabled? -> {:error, :disabled}
      not Keyword.get(opts, :idle?, true) -> {:error, :busy}
      not image?(spec["image"]) -> {:error, :bad_image}
      true -> patch(client, spec["image"])
    end
  end

  defp patch(client, image) do
    with {:ok, deployment} <- Client.get_deployment(client, @deployment),
         {:ok, current} <- current_image(deployment),
         :ok <- same_repository(current, image) do
      if current == image, do: {:ok, :current}, else: apply_patch(client, image)
    end
  end

  defp apply_patch(client, image) do
    patch = %{
      "spec" => %{
        "template" => %{"spec" => %{"containers" => [%{"name" => @container, "image" => image}]}}
      }
    }

    case Client.patch_deployment(client, @deployment, patch) do
      {:ok, _deployment} -> {:ok, :patched}
      {:error, _} = error -> error
    end
  end

  defp current_image(deployment) do
    containers = get_in(deployment, ["spec", "template", "spec", "containers"]) || []

    case Enum.find(containers, &(&1["name"] == @container)) do
      %{"image" => image} when is_binary(image) -> {:ok, image}
      _ -> {:error, :not_found}
    end
  end

  defp same_repository(current, image),
    do: if(repository(current) == repository(image), do: :ok, else: {:error, :bad_image})

  # `host[:port]/path` without the tag or digest.
  defp repository(image) do
    image |> String.split("@", parts: 2) |> hd() |> strip_tag()
  end

  defp strip_tag(name) do
    case String.split(name, "/") |> List.pop_at(-1) do
      {last, rest} -> Enum.join(rest ++ [last |> String.split(":", parts: 2) |> hd()], "/")
    end
  end

  defp image?(image),
    do: is_binary(image) and byte_size(image) <= 512 and Regex.match?(@image_re, image)
end
