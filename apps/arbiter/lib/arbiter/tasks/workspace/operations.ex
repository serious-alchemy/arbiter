defmodule Arbiter.Tasks.Workspace.Operations do
  @moduledoc """
  Workspace write operations that REST, MCP, the CLI's server side and the
  dashboard all share (parity audit bd-ws8nmk, P-21). One function per
  operation, so a surface is a thin adapter and none re-derives the write.

    * `update/3` — the `:update` action (name / description / prefix / `secrets`
      / `worker_env`) behind `PATCH /api/workspaces/:id` AND the dashboard.
      `patch_worker_env/3` is `update/3` with only a `worker_env` merge-patch:
      set / flip the secret flag of / remove user-defined worker env vars
      (`Arbiter.Tasks.Workspace.Changes.MergeWorkerEnv`). Values are
      write-only: nothing here returns one.
    * `add_standing_order/3` / `remove_standing_order/3` — append or remove ONE
      standing order, workspace-global or repo-scoped.

  ## Why a lock

  `:update` / `:patch_config` read the row the caller handed them and write the
  whole new value back, so two callers that each read the list and write it
  back lose one edit (D-C-37). Every operation here takes a per-workspace lock
  (`:global.trans/3`, local node only — the same primitive as
  `Arbiter.Accounts.Admission`), then re-reads the row *inside* the lock and
  applies its change to that fresh copy. Whatever the caller passes as a
  workspace is used only for its id.

  Options common to every function: `:context` — extra Ash action context (the
  caller's `:guardrail_authority`).
  """

  alias Arbiter.StandingOrders
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  @type ref :: Workspace.t() | String.t()
  @type error :: {:invalid | :not_found, String.t()} | Exception.t() | term()

  @doc """
  Run the `:update` action on the workspace under its lock. `attrs` take the
  action's accepted attributes and arguments (`name`, `description`, `prefix`,
  `config`, `secrets`, `worker_env`), string or atom keys.
  """
  @spec update(ref(), map(), keyword()) :: {:ok, Workspace.t()} | {:error, error()}
  def update(ref, attrs, opts \\ []) when is_map(attrs) do
    locked(ref, fn ws -> ash_update(ws, attrs, :update, opts) end)
  end

  @doc """
  Merge-patch the workspace's worker env: `%{"NAME" => %{"value" => v, "secret"
  => bool}}` sets, `%{"NAME" => %{"secret" => bool}}` toggles the flag of an
  existing var, `%{"NAME" => nil}` removes it.
  """
  @spec patch_worker_env(ref(), map(), keyword()) :: {:ok, Workspace.t()} | {:error, error()}
  def patch_worker_env(ref, patch, opts \\ []) when is_map(patch),
    do: update(ref, %{worker_env: patch}, opts)

  @doc """
  Append one standing order (a string, or a `%{"title" => _, "detail" => _}`
  map). `repo: name` targets that repo's `repo_paths.<repo>.standing_orders`
  instead of the workspace-global list; the repo must already be registered.
  """
  @spec add_standing_order(ref(), String.t() | map(), keyword()) ::
          {:ok, Workspace.t()} | {:error, error()}
  def add_standing_order(ref, order, opts \\ []) do
    with {:ok, order} <- normalize_order(order) do
      locked(ref, fn ws ->
        with {:ok, orders, put} <- orders_and_writer(ws, opts[:repo]) do
          write(ws, put, orders ++ [order], opts)
        end
      end)
    end
  end

  @doc """
  Remove one standing order, by 1-based index (integer or numeric string) or by
  its exact human-readable text.
  """
  @spec remove_standing_order(ref(), pos_integer() | String.t(), keyword()) ::
          {:ok, Workspace.t()} | {:error, error()}
  def remove_standing_order(ref, target, opts \\ []) do
    locked(ref, fn ws ->
      with {:ok, orders, put} <- orders_and_writer(ws, opts[:repo]),
           {:ok, index} <- locate(orders, target, opts[:repo]) do
        write(ws, put, List.delete_at(orders, index), opts)
      end
    end)
  end

  @doc """
  The workspace's standing orders — the global list, or `repo`'s list under
  `repo_paths.<repo>.standing_orders` (empty when the repo is unregistered).
  """
  @spec standing_orders(Workspace.t(), String.t() | nil) :: [String.t() | map()]
  def standing_orders(%Workspace{} = ws, repo \\ nil) do
    case orders_and_writer(ws, repo) do
      {:ok, orders, _put} -> orders
      {:error, _} -> []
    end
  end

  @doc "The result a standing-order write returns on every surface."
  @spec view(Workspace.t(), String.t() | nil) :: map()
  def view(%Workspace{} = ws, repo \\ nil) do
    %{
      workspace: %{id: ws.id, name: ws.name, prefix: ws.prefix},
      repo: repo,
      standing_orders: standing_orders(ws, repo)
    }
  end

  # ---- standing-order internals ---------------------------------------------

  defp normalize_order(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, {:invalid, "standing order text must not be empty"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_order(%{"title" => title} = order) when is_binary(title) do
    if String.trim(title) == "",
      do: {:error, {:invalid, "standing order title must not be empty"}},
      else: {:ok, order}
  end

  defp normalize_order(_),
    do: {:error, {:invalid, "a standing order is a string or a {title, detail} object"}}

  # The current list plus the function that wraps a new list into the patch
  # `:patch_config` deep-merges.
  defp orders_and_writer(ws, repo) when repo in [nil, ""] do
    orders =
      case (ws.config || %{})["standing_orders"] do
        list when is_list(list) -> list
        _ -> []
      end

    {:ok, orders, &%{"standing_orders" => &1}}
  end

  defp orders_and_writer(ws, repo) when is_binary(repo) do
    repo_paths = (ws.config || %{})["repo_paths"]

    case RepoConfig.find_key(repo_paths, repo) do
      nil ->
        {:error,
         {:not_found,
          "no repo named #{inspect(repo)} registered; register its path first " <>
            "(repo_paths.#{repo}.path)"}}

      key ->
        entry =
          case Map.fetch!(repo_paths, key) do
            %{} = m -> m
            path when is_binary(path) -> %{"path" => path}
            _ -> %{}
          end

        orders = if is_list(entry["standing_orders"]), do: entry["standing_orders"], else: []

        {:ok, orders, &%{"repo_paths" => %{key => Map.put(entry, "standing_orders", &1)}}}
    end
  end

  defp locate([], _target, repo),
    do: {:error, {:not_found, "no standing orders#{repo_label(repo)} to remove"}}

  defp locate(orders, target, repo) do
    case parse_index(target) do
      {:ok, n} when n >= 1 and n <= length(orders) ->
        {:ok, n - 1}

      {:ok, n} ->
        {:error, {:invalid, "standing order index #{n} out of range (1..#{length(orders)})"}}

      :text ->
        case Enum.find_index(orders, &(StandingOrders.canonical_text(&1) == target)) do
          nil ->
            {:error,
             {:not_found, "no standing order#{repo_label(repo)} matching #{inspect(target)}"}}

          index ->
            {:ok, index}
        end
    end
  end

  defp parse_index(n) when is_integer(n), do: {:ok, n}

  defp parse_index(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :text
    end
  end

  defp repo_label(repo) when repo in [nil, ""], do: ""
  defp repo_label(repo), do: " for repo #{repo}"

  defp write(ws, put, new_orders, opts),
    do:
      ash_update(
        ws,
        %{patch: put.(new_orders), unset_paths: [], force: false},
        :patch_config,
        opts
      )

  # ---- locking --------------------------------------------------------------

  defp ash_update(ws, args, action, opts) do
    case Ash.update(ws, args, action: action, context: Keyword.get(opts, :context, %{})) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} = err -> err
    end
  end

  defp locked(ref, fun) do
    id = workspace_id(ref)

    result =
      :global.trans({{__MODULE__, id}, self()}, fn -> with_fresh(id, fun) end, [node()])

    case result do
      :aborted -> {:error, {:invalid, "workspace is busy; retry"}}
      other -> other
    end
  end

  defp with_fresh(id, fun) do
    case Ash.get(Workspace, id) do
      {:ok, %Workspace{} = ws} -> fun.(ws)
      _ -> {:error, {:not_found, "workspace #{id} not found"}}
    end
  end

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id) when is_binary(id), do: id
end
