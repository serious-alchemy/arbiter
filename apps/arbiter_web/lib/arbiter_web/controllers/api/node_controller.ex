defmodule ArbiterWeb.Api.NodeController do
  @moduledoc """
  Node administration over REST (`docs/design/remote-workers.md` §5.3, §5.6).
  Backs `arb node`.

    * `POST /api/nodes/join-tokens` — **operator**: mint a join token. The
      response carries the token (shown once) and the one-liner, which holds no
      secret. Rate limited per actor (`Nodes.RateLimit`, 20/hour).
    * `GET /api/nodes`, `GET /api/nodes/:ref`, `GET /api/nodes/:ref/events` —
      **operator** reads. `:ref` is a node id or its name, or `local` for the
      primary. The list also carries the `local` row, the `total` of
      `local + Σ remote caps` against the `ceiling` (`conductor.max_concurrent`),
      `warnings`, and the `nodes.public_url` with its `exposure`
      (`private | public | unset`) for `arb server doctor`.
    * `PATCH /api/nodes/:ref` — **operator**: edit `name`, `labels`,
      `max_workers`. `local` takes `max_workers` only (0 allowed, `null` clears).
    * `POST /api/nodes/:ref/{drain,undrain,revoke,upgrade}` and
      `DELETE /api/nodes/:ref` (a revoked node only) — **operator**; each
      writes a `NodeEvent`.

  Credentials and token hashes are never rendered (`ArbiterWeb.Api.NodeJSON`).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{JoinScript, Overview, RateLimit}
  alias Arbiter.Settings
  alias ArbiterWeb.Api.NodeJSON

  action_fallback(ArbiterWeb.Api.FallbackController)

  @local_cap_message "local takes max_workers only: a whole number, 0 or more, or null to clear"
  @name_message "name may only contain A-Za-z0-9._=:/@- and be 1-128 characters"

  def create_join_token(conn, params) do
    with {:ok, url} <- public_url(),
         {:ok, opts} <- mint_opts(params),
         :ok <- mint_limit(),
         {:ok, %{token: token, join_token: row}} <- Nodes.mint_join_token(opts, nil) do
      conn
      |> put_status(:created)
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        token: token,
        join_token: NodeJSON.join_token(row),
        one_liner: JoinScript.one_liner(url),
        public_url: url
      })
    else
      {:error, :invalid_ttl} -> unprocessable(conn, "ttl_seconds must be between 1 and 86400")
      {:error, :invalid_name} -> unprocessable(conn, @name_message)
      {:error, {:rate_limited, seconds}} -> rate_limited(conn, seconds)
      {:error, {:unprocessable, message}} -> unprocessable(conn, message)
      {:error, other} -> {:error, other}
    end
  end

  def index(conn, _params) do
    overview = Overview.build()
    rows = Map.new(overview.nodes, &{&1.id, &1})
    url = Settings.nodes_public_url()

    json(conn, %{
      nodes: Enum.map(Nodes.list_nodes(), &NodeJSON.node(&1, Map.fetch!(rows, &1.id))),
      local: NodeJSON.local(overview.local),
      total: overview.total,
      ceiling: overview.ceiling,
      warnings: overview.warnings,
      public_url: url,
      exposure: Overview.exposure(url),
      allow_public_endpoint: Settings.nodes_allow_public_endpoint?()
    })
  end

  def show(conn, %{"ref" => "local"}),
    do: json(conn, %{node: NodeJSON.local(Overview.build().local)})

  def show(conn, %{"ref" => ref}) do
    with {:ok, node} <- fetch(ref), do: json(conn, %{node: node_view(node)})
  end

  def events(conn, %{"ref" => ref}) do
    with {:ok, node} <- fetch(ref) do
      json(conn, %{events: node_events(node)})
    end
  end

  defp node_events(node),
    do: Nodes.events(node_id: node.id) |> Enum.map(&NodeJSON.event/1)

  def update(conn, %{"ref" => "local"} = params) do
    with {:ok, n} <- local_cap(params),
         {:ok, _} <- Nodes.set_local_max_workers(n, nil) do
      json(conn, %{node: NodeJSON.local(Overview.build().local)})
    else
      {:error, :invalid_value} -> unprocessable(conn, @local_cap_message)
      {:error, {:unprocessable, message}} -> unprocessable(conn, message)
      {:error, other} -> {:error, other}
    end
  end

  def update(conn, %{"ref" => ref} = params) do
    with {:ok, node} <- fetch(ref),
         {:ok, changes} <- changes(params),
         {:ok, updated} <- Nodes.update_node(node, changes, nil) do
      json(conn, %{node: node_view(updated)})
    else
      {:error, :invalid_name} -> unprocessable(conn, @name_message)
      {:error, :name_taken} -> {:error, {:conflict, "a node with that name already exists"}}
      {:error, :revoked} -> {:error, {:conflict, "the node is revoked and cannot be edited"}}
      {:error, {:unprocessable, message}} -> unprocessable(conn, message)
      {:error, other} -> {:error, other}
    end
  end

  def drain(conn, %{"ref" => ref}), do: lifecycle(conn, ref, &Nodes.drain/2)
  def undrain(conn, %{"ref" => ref}), do: lifecycle(conn, ref, &Nodes.undrain/2)
  def revoke(conn, %{"ref" => ref}), do: lifecycle(conn, ref, &Nodes.revoke/2)

  def upgrade(conn, %{"ref" => ref}) do
    with {:ok, node} <- fetch(ref),
         {:ok, %{version: version}} <- Nodes.upgrade(node, nil) do
      json(conn, %{node: node_view(node), upgrading_to: version})
    else
      {:error, :offline} -> {:error, {:conflict, "the node is not connected"}}
      {:error, :revoked} -> {:error, {:conflict, "the node is revoked"}}
      {:error, :unavailable} -> {:error, {:conflict, "this install has no release to serve"}}
      {:error, other} -> {:error, other}
    end
  end

  def delete(conn, %{"ref" => ref}) do
    with {:ok, node} <- fetch(ref),
         :ok <- Nodes.remove(node, nil) do
      json(conn, %{removed: node.name})
    else
      {:error, :not_revoked} -> {:error, {:conflict, "revoke the node before removing it"}}
      {:error, other} -> {:error, other}
    end
  end

  defp lifecycle(conn, ref, fun) do
    with {:ok, node} <- fetch(ref),
         {:ok, updated} <- fun.(node, nil) do
      json(conn, %{node: node_view(updated)})
    else
      {:error, :revoked} -> {:error, {:conflict, "the node is revoked"}}
      {:error, other} -> {:error, other}
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp node_view(%Arbiter.Nodes.Node{} = node),
    do: NodeJSON.node(node, Overview.get(node.id) || %{})

  defp local_cap(params) do
    case Map.fetch(params, "max_workers") do
      {:ok, n} when is_nil(n) or (is_integer(n) and n >= 0) -> {:ok, n}
      {:ok, _} -> {:error, :invalid_value}
      :error -> {:error, {:unprocessable, @local_cap_message}}
    end
  end

  defp fetch(ref) do
    case Nodes.find_node(ref) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  defp public_url do
    case Settings.nodes_public_url() do
      nil -> {:error, {:unprocessable, "nodes.public_url is not set; set it before adding nodes"}}
      url -> {:ok, url}
    end
  end

  defp mint_limit do
    key = Actor.resolve_label(nil) || "operator"
    RateLimit.check(:mint, key)
  end

  defp mint_opts(params) do
    with {:ok, changes} <- changes(Map.take(params, ["name", "labels", "max_workers"])) do
      opts =
        changes
        |> Map.to_list()
        |> Keyword.take([:name, :labels, :max_workers])
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case params["ttl_seconds"] do
        nil -> {:ok, opts}
        ttl when is_integer(ttl) -> {:ok, [{:ttl_seconds, ttl} | opts]}
        _ -> {:error, :invalid_ttl}
      end
    end
  end

  # Well-typed `name` / `labels` / `max_workers`, or a 422. `max_workers: null`
  # clears the cap; an invalid number is left to the resource's constraint.
  defp changes(params) do
    Enum.reduce_while(["name", "labels", "max_workers"], {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(params, key) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> check(key, value, acc)
      end
    end)
  end

  defp check("name", v, acc) when is_binary(v) do
    name = String.trim(v)

    if Nodes.valid_name?(name),
      do: {:cont, {:ok, Map.put(acc, :name, name)}},
      else: {:halt, {:error, {:unprocessable, @name_message}}}
  end

  defp check("labels", v, acc) when is_list(v) do
    if Enum.all?(v, &is_binary/1),
      do: {:cont, {:ok, Map.put(acc, :labels, v)}},
      else: {:halt, {:error, {:unprocessable, "labels must be a list of strings"}}}
  end

  defp check("max_workers", v, acc) when is_nil(v) or is_integer(v),
    do: {:cont, {:ok, Map.put(acc, :max_workers, v)}}

  defp check(key, _v, _acc),
    do: {:halt, {:error, {:unprocessable, "#{key} has the wrong type"}}}

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{type: "validation_error", message: message, details: %{}}})
  end

  defp rate_limited(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{type: "rate_limited", message: "too many join tokens minted", details: %{}}
    })
  end
end
