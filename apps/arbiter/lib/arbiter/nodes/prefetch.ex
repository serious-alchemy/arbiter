defmodule Arbiter.Nodes.Prefetch do
  @moduledoc """
  SI7 (`docs/design/remote-workers.md` §21.2.4, §21.9): after a publish yields a new
  run-image ref, send `image.prefetch{ref, cli_set, pull_auth, insecure}` to each online,
  ready machine node that could take that repo's runs, so the next run finds it warm.

  A node is a candidate when it is a connected machine node, `ready`, not draining,
  advertising `caps.image_prefetch`, pinned to (or free of a pin that excludes) the
  workspace, admitted by the workspace's `worker.placement_nodes` allowlist, not blocked
  or unreachable for the registry, and **not already holding the ref** (its `hb.images`).
  Each gets a pull credential it may hold (`Image.PullCredential.for_node/4`, the same
  reach rule a run's `assign` follows); a node that may hold none is skipped, because a
  run there takes the plan path anyway. The push credential never goes anywhere.

  One event, sent once per node per new ref (`Image.Publisher` calls this only when the
  repo's last published ref changed), from a background task: a publish never waits for a
  prefetch, and a prefetch that cannot be sent is dropped without a trace on the run
  path. The agent pulls one image at a time (`NodeAgent.ImagePrefetch`).

  Options: `:prefetch` (`false` disables; a 2-arity function replaces this module, for a
  test), `:nodes` (rows, or a 0-arity function; default `Overview.node_rows/0`),
  `:send_fun` (`(node_id, payload -> :ok | {:error, term})`; default
  `Session.prefetch/2` on the node's session), `:credential_opts` (to `PullCredential`),
  `:credential_fun` (`(workspace, repo, row -> PullCredential.for_node/4's result)`),
  and `:async` (default `true`).
  """

  alias Arbiter.Nodes.{Allowlist, Overview, Placement, Registry, Session}
  alias Arbiter.Worker.Image.PullCredential

  require Logger

  @doc """
  Prefetch `published` (`%{ref, cli_set, …}`, `Publisher.ensure_ready/2`'s result) for
  `ctx`'s repo. Returns `:ok` at once; the sends happen in a task.
  """
  @spec after_publish(map(), map(), keyword()) :: :ok
  def after_publish(ctx, published, opts \\ []) do
    case Keyword.get_lazy(opts, :prefetch, &enabled?/0) do
      false ->
        :ok

      fun when is_function(fun, 2) ->
        fun.(ctx, published)
        :ok

      _ ->
        if Keyword.get(opts, :async, true) do
          {:ok, _} = Task.start(fn -> safely(ctx, published, opts) end)
          :ok
        else
          safely(ctx, published, opts)
        end
    end
  end

  defp enabled? do
    :arbiter |> Application.get_env(:image_publisher, []) |> Keyword.get(:prefetch, true)
  end

  defp safely(ctx, published, opts) do
    _ = run(ctx, published, opts)
    :ok
  rescue
    e ->
      Logger.warning("image.prefetch: skipped: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Send the prefetch to every candidate node; `[{node_id, :ok | {:skipped, reason} |
  {:error, reason}}]`.
  """
  @spec run(map(), map(), keyword()) :: [{String.t(), term()}]
  def run(ctx, %{ref: ref} = published, opts \\ []) when is_binary(ref) do
    workspace = Map.get(ctx, :workspace)
    repo = Map.get(ctx, :repo)

    for row <- rows(opts), candidate?(row, ref, workspace) do
      {row.id, send_to(row, ref, published, workspace, repo, opts)}
    end
  end

  @doc "Whether `row` should be sent a prefetch of `ref` for `workspace`'s repo."
  @spec candidate?(map(), String.t(), map() | nil) :: boolean()
  def candidate?(row, ref, workspace) do
    Map.get(row, :kind) == :machine and row.state == :online and row.health == :ready and
      Map.get(row, :draining?) != true and
      get_in(row, [:caps, "image_prefetch"]) == true and
      pin_allows?(Map.get(row, :workspace_ids, []), workspace) and
      Allowlist.allows?(Allowlist.selectors(workspace), row) and
      not held?(row, ref)
  end

  @doc "Does the node's `hb.images` list `ref`?"
  @spec held?(map(), String.t()) :: boolean()
  def held?(row, ref), do: ref in digests(row)

  @doc "The refs a node reported holding (`hb.images.digests`)."
  @spec digests(map()) :: [String.t()]
  def digests(row) do
    case Map.get(row, :images) do
      %{"digests" => list} when is_list(list) -> list
      _ -> []
    end
  end

  defp pin_allows?([], _workspace), do: true
  defp pin_allows?(pins, %{id: id}), do: id in pins
  defp pin_allows?(_pins, _workspace), do: false

  defp send_to(row, ref, published, workspace, repo, opts) do
    registry = host(ref)

    with true <- Placement.registry_pullable?(row, registry) || {:skipped, :registry_blocked},
         {:ok, %{auth: auth, insecure?: insecure?}} <-
           credential(workspace, repo, row, opts) do
      payload =
        %{"ref" => ref, "insecure" => insecure?}
        |> put("cli_set", Map.get(published, :cli_set))
        |> put("pull_auth", auth)

      deliver(row.id, payload, opts)
    else
      {:skipped, _} = skipped -> skipped
      {:error, reason} -> {:skipped, reason}
    end
  end

  defp credential(workspace, repo, row, opts) do
    case Keyword.get(opts, :credential_fun) do
      fun when is_function(fun, 3) ->
        fun.(workspace, repo, row)

      _ ->
        PullCredential.for_node(workspace, repo, row, Keyword.get(opts, :credential_opts, []))
    end
  end

  defp deliver(node_id, payload, opts) do
    case Keyword.get(opts, :send_fun) do
      fun when is_function(fun, 2) ->
        fun.(node_id, payload)

      _ ->
        case Registry.lookup(node_id) do
          nil -> {:error, :not_connected}
          pid -> Session.prefetch(pid, payload)
        end
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp host(ref), do: ref |> String.split("/", parts: 2) |> hd()

  defp rows(opts) do
    case Keyword.get(opts, :nodes) do
      rows when is_list(rows) -> rows
      fun when is_function(fun, 0) -> fun.()
      nil -> Overview.node_rows()
    end
  end
end
