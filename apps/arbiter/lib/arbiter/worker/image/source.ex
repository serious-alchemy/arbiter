defmodule Arbiter.Worker.Image.Source do
  @moduledoc """
  Which image a run placed on a node takes, chosen per run (SI4,
  `docs/design/remote-workers.md` §21.2.1, §21.6). It replaces the single read of
  `caps.image` (`registry_node?/1`) in `Arbiter.Worker.ContainerSpawn`.

    * `:registry` — a node that only runs registry images (`caps.image =
      "registry"`: a cluster). The primary publishes and sends the digest-pinned
      `ref` and no plan; the cluster pulls with its own pull secrets (KH13).
    * `{:pull, %{auth, level, insecure?}}` — a machine node that lists `"registry"`
      in `caps.image_sources`, under `nodes.machine_image_source: auto`, for a repo
      whose registry has a pull credential that node may hold
      (`Arbiter.Worker.Image.PullCredential`, the reach rule of §21.4). The primary
      publishes and sends the pinned `ref`, the image's CLI set and `pull_auth`, and
      no CLI files.
    * `:build` — everything else, exactly as before: the node builds the plan and
      fetches the CLI files. `nodes.machine_image_source` defaults to `auto` since SI4a;
      `build` forces every machine node back to this path.

  Options: `:machine_image_source` (replaces the setting's read; tests) and
  `PullCredential.for_node/4`'s.
  """

  alias Arbiter.Settings
  alias Arbiter.Worker.Image.PullCredential

  require Logger

  @type t :: :registry | {:pull, PullCredential.t()} | :build

  @doc "Whether `node` only runs registry images (`caps.image = \"registry\"`)."
  @spec registry_only?(map()) :: boolean()
  def registry_only?(node), do: caps(node)["image"] == "registry"

  @doc "Whether `node`'s agent can pull a published image (`caps.image_sources`)."
  @spec pulls?(map()) :: boolean()
  def pulls?(node) do
    case caps(node)["image_sources"] do
      sources when is_list(sources) -> "registry" in sources
      _ -> false
    end
  end

  @doc """
  Where `node`'s worker images come from, for the doctor and the nodes page (SI4a):
  `"registry"` for a node that can take the published image (a cluster, or a machine
  whose agent lists `registry` under `nodes.machine_image_source: auto`), else `"build"`.
  Whether a given run pulls also depends on the repo's pull credential (`choose/3`).
  """
  @spec node_source(map(), keyword()) :: String.t()
  def node_source(node, opts \\ []) do
    cond do
      registry_only?(node) -> "registry"
      pulls?(node) and machine_source(opts) == "auto" -> "registry"
      true -> "build"
    end
  end

  @doc """
  The source for a run of `ctx.repo` in `ctx.workspace` (`ctx` is the publish
  context, or any map with those keys) placed on `node` (a placement row).
  """
  @spec choose(map(), map(), keyword()) :: t()
  def choose(node, ctx, opts \\ []) do
    cond do
      registry_only?(node) -> :registry
      not pulls?(node) -> :build
      machine_source(opts) != "auto" -> :build
      true -> pull(node, ctx, opts)
    end
  end

  defp pull(node, ctx, opts) do
    repo = Map.get(ctx, :repo)

    case PullCredential.for_node(Map.get(ctx, :workspace), repo, node, opts) do
      {:ok, pull} ->
        {:pull, pull}

      # debug: it is evaluated more than once per placement (preflight, spawn), and SI4a
      # gives the operator a doctor row for it
      {:error, reason} ->
        Logger.debug(
          "Image.Source: node #{label(node)} builds #{repo || "the repo"} from a plan: " <>
            inspect(reason)
        )

        :build
    end
  end

  defp machine_source(opts) do
    case Keyword.fetch(opts, :machine_image_source) do
      {:ok, source} when is_binary(source) -> source
      _ -> Settings.machine_image_source()
    end
  end

  defp caps(node), do: Map.get(node, :caps) || %{}

  defp label(node), do: Map.get(node, :name) || Map.get(node, :id) || "?"
end
