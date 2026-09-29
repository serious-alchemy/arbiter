defmodule Arbiter.Mergers.ForgeRepos do
  @moduledoc """
  The forge repositories a workspace merges into — one entry per repo whose
  **effective** strategy (`Arbiter.Mergers.scope/2`, bd-73zv62) is a hosted
  forge (`github` / `gitlab`). This is what `PRPatrolSupervisor`,
  `ReviewPatrolSupervisor`, `MergedPRFinalizerSupervisor` and
  `Arbiter.Reviews.ExternalReview` start (or check) one process per.

  Resolution, per `repo_paths` key, against that repo's effective merge block:

    * `github` — the pinned `merge.config.owner` / `.repo` when both are set,
      else `owner/repo` parsed from the checkout's `origin` remote.
    * `gitlab` — the pinned `merge.config.project_id`, else the remote's
      `owner/repo`. With `gitlab: :remote_first` (PRPatrol, whose `repo` is
      threaded into `Dispatch` and so must be a `repo_paths`-resolvable slug,
      bd-7rxwzc) the remote slugs win, and pinned project ids are used only
      when no gitlab repo's remote resolves.
    * `direct` — nothing. A repo on a `merge.repos.<repo>.strategy = "direct"`
      override spawns no patrol and no finalizer.

  A workspace with no `repo_paths` resolves from its workspace-level merge
  block alone (the pinned repo / project, or nothing). Slugs are de-duplicated
  (every repo inheriting one pinned `owner/repo` is a single entry) and sorted.
  A repo whose remote is missing or unparseable is logged and skipped.
  """

  require Logger

  alias Arbiter.Mergers
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  @type entry :: %{slug: String.t(), repo_key: String.t() | nil, strategy: :github | :gitlab}
  @type opts :: [gitlab: :project_id_first | :remote_first, log: String.t()]

  @doc "Every forge repo `workspace` resolves to. See the moduledoc."
  @spec list(Workspace.t(), opts()) :: [entry()]
  def list(%Workspace{} = workspace, opts \\ []) do
    entries =
      case repo_paths(workspace) do
        paths when map_size(paths) == 0 -> workspace_level(workspace)
        paths -> per_repo(workspace, paths, opts)
      end

    entries
    |> Enum.uniq_by(& &1.slug)
    |> Enum.sort_by(& &1.slug)
  end

  @doc "`list/2`'s slugs — one patrol / finalizer each."
  @spec slugs(Workspace.t(), opts()) :: [String.t()]
  def slugs(%Workspace{} = workspace, opts \\ []), do: Enum.map(list(workspace, opts), & &1.slug)

  @doc """
  `workspace` narrowed (`Arbiter.Mergers.scope/2`) to the repo the forge
  `slug` belongs to, for a per-slug process (a patrol, a finalizer) that has
  only the slug on hand. A no-op — no git call — when the workspace declares
  no `merge.repos` override, and when no repo resolves to `slug`.
  """
  @spec scope(Workspace.t(), String.t() | nil, opts()) :: Workspace.t()
  def scope(workspace, slug, opts \\ [])

  def scope(%Workspace{} = workspace, slug, opts) when is_binary(slug) and slug != "" do
    if overrides?(workspace) do
      case Enum.find(list(workspace, opts), &(&1.slug == slug)) do
        %{repo_key: key} when is_binary(key) -> Mergers.scope(workspace, key)
        _ -> workspace
      end
    else
      workspace
    end
  end

  def scope(%Workspace{} = workspace, _slug, _opts), do: workspace

  defp overrides?(%Workspace{config: %{"merge" => %{"repos" => repos}}})
       when is_map(repos) and map_size(repos) > 0,
       do: true

  defp overrides?(_workspace), do: false

  defp repo_paths(%Workspace{config: %{"repo_paths" => paths}}) when is_map(paths), do: paths
  defp repo_paths(_workspace), do: %{}

  defp workspace_level(workspace) do
    merge = Mergers.merge_config(workspace, nil)

    case pinned(Workspace.merger_strategy(%Workspace{config: %{"merge" => merge}}), merge) do
      nil -> []
      {strategy, slug} -> [%{slug: slug, repo_key: nil, strategy: strategy}]
    end
  end

  defp per_repo(workspace, paths, opts) do
    forge =
      paths
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.flat_map(fn {key, raw} ->
        merge = Mergers.merge_config(workspace, key)
        strategy = Workspace.merger_strategy(%Workspace{config: %{"merge" => merge}})

        if Mergers.forge?(strategy),
          do: [
            %{
              key: key,
              path: RepoConfig.repo_path_from_config(raw),
              merge: merge,
              strategy: strategy
            }
          ],
          else: []
      end)

    {gitlab, github} = Enum.split_with(forge, &(&1.strategy == :gitlab))

    Enum.flat_map(github, &pinned_or_remote(&1, opts)) ++ gitlab_entries(gitlab, opts)
  end

  defp gitlab_entries(gitlab, opts) do
    case Keyword.get(opts, :gitlab, :project_id_first) do
      :remote_first ->
        case Enum.flat_map(gitlab, &remote_entry(&1, opts)) do
          [] -> Enum.flat_map(gitlab, &pinned_entry/1)
          remotes -> remotes
        end

      _ ->
        Enum.flat_map(gitlab, &pinned_or_remote(&1, opts))
    end
  end

  defp pinned_or_remote(repo, opts) do
    case pinned_entry(repo) do
      [] -> remote_entry(repo, opts)
      pinned -> pinned
    end
  end

  defp pinned_entry(%{key: key, merge: merge, strategy: strategy}) do
    case pinned(strategy, merge) do
      {^strategy, slug} -> [%{slug: slug, repo_key: key, strategy: strategy}]
      nil -> []
    end
  end

  defp remote_entry(%{key: key, path: path, strategy: strategy}, opts) do
    case RepoResolver.from_remote(path) do
      {:ok, {owner, name}} ->
        [%{slug: "#{owner}/#{name}", repo_key: key, strategy: strategy}]

      {:error, err} ->
        Logger.info(
          "#{Keyword.get(opts, :log, "Mergers.ForgeRepos")}: could not derive repo for " <>
            "#{key} (path #{inspect(path)}), skipping: #{inspect(err)}"
        )

        []
    end
  end

  defp pinned(:github, merge) do
    owner = adapter_config(merge, "owner")
    repo = adapter_config(merge, "repo")

    if present?(owner) and present?(repo), do: {:github, "#{owner}/#{repo}"}
  end

  defp pinned(:gitlab, merge) do
    case adapter_config(merge, "project_id") do
      v when is_integer(v) -> {:gitlab, "#{v}"}
      v when is_binary(v) and v != "" -> {:gitlab, v}
      _ -> nil
    end
  end

  defp pinned(_strategy, _merge), do: nil

  defp adapter_config(%{"config" => %{} = config}, key), do: Map.get(config, key)
  defp adapter_config(_merge, _key), do: nil

  defp present?(v), do: is_binary(v) and v != ""
end
