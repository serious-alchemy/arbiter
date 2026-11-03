defmodule Arbiter.Worker.Image.PullCredential do
  @moduledoc """
  The registry **read** credential a machine node is handed for one pull of a repo's
  published image (SI4, `docs/design/remote-workers.md` §21.4), or why it gets none.

  ## Where it comes from

  The registry is the one the repo's images are pushed to (`Registry.resolve/3`); the
  credential is a read token next to the push one, never the push one:

    * `worker.repos.<repo>.image.pull_credentials_ref` (`:repo`), else
      `worker.image.pull_credentials_ref` (`:workspace`): a workspace secret holding
      `user:password`, bound to the registry it was written next to
      (`Arbiter.Worker.Image.RepoConfig`);
    * else `nodes.registry_pull_username` / `nodes.registry_pull_password` (`:install`),
      for `nodes.registry`'s own host only: never sent to another host;
    * else, for a registry the operator marked `public_ok`, nothing (`:anonymous`);
    * else `{:error, :no_pull_credential}`. The push credential is never the
      fallback.

  ## The reach rule

  One credential can read more than the repository a run needs, so a node is given it
  only when every repository it can read holds runs that node may take:

    * `:repo` (and `:anonymous`) always: it reads that repo's repository;
    * `:workspace` when the node's pin (`workspace_ids`, empty = any) admits the
      workspace and the workspace's node allowlist (`worker.placement_nodes`) admits
      the node;
    * `:install` only for an unpinned node that no workspace's allowlist leaves out:
      it reads every repo on `nodes.registry`. A workspace list that cannot be read
      means no.

  Otherwise `{:error, {:out_of_reach, level}}`, and the run takes the plan path.

  ## Never the push credential

  A pull password that equals the push password of the repo's registry,
  `nodes.registry_password`, or any `credentials_ref` the workspace configures (for any
  registry) is refused (`:pull_credential_is_push_credential`), with a warning naming
  no value: a node holding a push credential could overwrite the images every node and
  cluster run. `Arbiter.Settings` and `ValidateConfig` refuse the same
  at write time where they can see both.

  The credential travels as `Arbiter.NodeAgent.PullAuth`, whose `Inspect` shows only
  the registry.

  Options: `:config` (the install-wide values, as `Registry.fetch/1`'s plus
  `:pull_username` and `:pull_password`), `:workspaces` (a list, or a 0-arity function;
  default every workspace), `:node_lookup` (`id -> node | nil`, for a row with no
  `:workspace_ids`; default `Arbiter.Nodes.get_node/1`).
  """

  alias Arbiter.NodeAgent.PullAuth
  alias Arbiter.Nodes
  alias Arbiter.Nodes.Allowlist
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Image.Registry
  alias Arbiter.Worker.Image.RepoConfig

  require Logger

  @type level :: :repo | :workspace | :install | :anonymous
  @type t :: %{auth: PullAuth.t() | nil, level: level(), insecure?: boolean()}

  @doc """
  The pull credential `node` may be handed for `repo`'s published image in
  `workspace`: `{:ok, %{auth, level, insecure?}}` (`auth` is `nil` for an anonymous
  pull) or `{:error, reason}`.
  """
  @spec for_node(term(), String.t() | nil, map(), keyword()) :: {:ok, t()} | {:error, term()}
  def for_node(workspace, repo, node, opts \\ []) do
    with {:ok, registry} <- registry(workspace, repo, opts),
         {:ok, level, login} <- credential(workspace, repo, registry, opts),
         :ok <- reach(level, node, workspace, opts),
         :ok <- not_push(login, registry, workspace, repo, opts) do
      {:ok, %{auth: auth(registry, login), level: level, insecure?: registry.insecure? == true}}
    end
  end

  @doc """
  The credential the **primary itself** pulls its own repo image with (SI-L: a local
  run takes the published image). The same sources as `for_node/4` and the same refusal
  of a push credential, but no reach rule: the primary holds the push credential
  already, and the pull token never leaves it. `{:ok, %{auth, level, insecure?}}` or
  `{:error, reason}` (`:no_pull_credential` when none is configured).
  """
  @spec for_local(term(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def for_local(workspace, repo, opts \\ []) do
    with {:ok, registry} <- registry(workspace, repo, opts),
         {:ok, level, login} <- credential(workspace, repo, registry, opts),
         :ok <- not_push(login, registry, workspace, repo, opts) do
      {:ok, %{auth: auth(registry, login), level: level, insecure?: registry.insecure? == true}}
    end
  end

  defp registry(workspace, repo, opts) do
    case Registry.resolve(workspace, repo, opts) do
      {:ok, %Registry{} = cfg} -> {:ok, cfg}
      :unset -> {:error, :no_registry}
      {:error, _} = error -> error
    end
  end

  # -- where the credential comes from ----------------------------------------------

  defp credential(workspace, repo, registry, opts) do
    case RepoConfig.resolve(workspace, repo) do
      %{pull_credentials_ref: ref, pull_credentials_level: level}
      when is_binary(ref) and level in [:repo, :workspace] ->
        case Registry.login(ref, workspace) do
          {:ok, login} ->
            {:ok, level, login}

          {:error, {:registry_credentials, _ref, reason}} ->
            {:error, {:pull_credentials, ref, reason}}
        end

      _ ->
        install_or_anonymous(registry, opts)
    end
  end

  defp install_or_anonymous(%Registry{} = registry, opts) do
    install = install(opts)

    cond do
      host(install.registry) == registry.host and present?(install.pull_username) and
          present?(install.pull_password) ->
        {:ok, :install, {install.pull_username, install.pull_password}}

      registry.public_ok ->
        {:ok, :anonymous, nil}

      true ->
        {:error, :no_pull_credential}
    end
  end

  defp install(opts) do
    case Keyword.get(opts, :config) do
      %{} = config ->
        %{
          registry: config[:registry],
          password: config[:password],
          pull_username: config[:pull_username],
          pull_password: config[:pull_password]
        }

      _ ->
        %{
          registry: Settings.nodes_registry(),
          password: Settings.nodes_registry_password(),
          pull_username: Settings.nodes_registry_pull_username(),
          pull_password: Settings.nodes_registry_pull_password()
        }
    end
  end

  # -- the reach rule -----------------------------------------------------------------

  defp reach(level, _node, _workspace, _opts) when level in [:repo, :anonymous], do: :ok

  defp reach(:workspace, node, workspace, opts) do
    with {:ok, facts} <- node_facts(node, opts),
         true <- pin_admits?(facts.workspace_ids, workspace_id(workspace)),
         true <- Allowlist.allows?(Allowlist.selectors(workspace), facts) do
      :ok
    else
      _ -> {:error, {:out_of_reach, :workspace}}
    end
  end

  defp reach(:install, node, _workspace, opts) do
    with {:ok, %{workspace_ids: []} = facts} <- node_facts(node, opts),
         {:ok, workspaces} <- workspaces(opts),
         true <- Enum.all?(workspaces, &Allowlist.allows?(Allowlist.selectors(&1), facts)) do
      :ok
    else
      _ -> {:error, {:out_of_reach, :install}}
    end
  end

  defp pin_admits?([], _workspace_id), do: true
  defp pin_admits?(pins, workspace_id), do: is_binary(workspace_id) and workspace_id in pins

  defp workspace_id(%{id: id}) when is_binary(id), do: id
  defp workspace_id(_), do: nil

  # What the allowlist and the pins are matched against: the placement row, and the
  # node's record when the row does not carry its pins. Unknown pins are never "any".
  defp node_facts(%{workspace_ids: pins} = node, _opts) when is_list(pins),
    do: {:ok, facts(node, %{}, pins)}

  defp node_facts(%{id: id} = node, opts) when is_binary(id) do
    lookup = Keyword.get(opts, :node_lookup, &Nodes.get_node/1)

    case safely(fn -> lookup.(id) end) do
      %{workspace_ids: pins} = found when is_list(pins) -> {:ok, facts(node, found, pins)}
      _ -> :unknown
    end
  end

  defp node_facts(_node, _opts), do: :unknown

  defp facts(node, found, pins) do
    %{
      id: Map.get(node, :id),
      name: Map.get(node, :name) || Map.get(found, :name),
      labels: Map.get(node, :labels) || Map.get(found, :labels) || [],
      kind: Map.get(node, :kind) || Map.get(found, :kind),
      workspace_ids: pins
    }
  end

  defp workspaces(opts) do
    case Keyword.get(opts, :workspaces, fn -> Ash.read!(Workspace) end) do
      list when is_list(list) ->
        {:ok, list}

      fun when is_function(fun, 0) ->
        case safely(fun) do
          list when is_list(list) -> {:ok, list}
          _ -> :error
        end
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # -- never the push credential --------------------------------------------------------

  defp not_push(nil, _registry, _workspace, _repo, _opts), do: :ok

  defp not_push({_user, password}, %Registry{} = registry, workspace, repo, opts) do
    pushes =
      Enum.filter(
        [registry.password, install(opts).password | workspace_pushes(workspace)],
        &present?/1
      )

    if password in pushes do
      Logger.warning(
        "PullCredential: the pull credential for #{repo || "the repo"} on #{registry.host} " <>
          "is a push credential; no node is handed it (configure a read-only token)"
      )

      {:error, :pull_credential_is_push_credential}
    else
      :ok
    end
  end

  # Every push token the workspace configures (`worker.image` and each repo's
  # `credentials_ref`): a pull secret that is any of them never goes to a node, whatever
  # registry it was meant for.
  defp workspace_pushes(%{config: %{"worker" => %{} = worker}} = workspace) do
    repos =
      case Map.get(worker, "repos") do
        %{} = repos -> Map.values(repos)
        _ -> []
      end

    [Map.get(worker, "image") | Enum.map(repos, &(is_map(&1) && &1["image"]))]
    |> Enum.flat_map(fn
      %{"credentials_ref" => ref} when is_binary(ref) -> [ref]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn ref ->
      case Registry.login(ref, workspace) do
        {:ok, {_user, push}} -> [push]
        _ -> []
      end
    end)
  end

  defp workspace_pushes(_workspace), do: []

  defp auth(_registry, nil), do: nil

  defp auth(%Registry{host: host}, {user, password}),
    do: %PullAuth{registry: host, username: user, password: password}

  defp host(registry) when is_binary(registry) and registry != "",
    do: registry |> String.split("/", parts: 2) |> hd()

  defp host(_), do: nil

  defp present?(value), do: is_binary(value) and value != ""
end
