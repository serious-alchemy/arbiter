defmodule ArbiterWeb.Api.NodeController do
  @moduledoc """
  Node administration over REST (`docs/design/remote-workers.md` §5.3, §5.6).
  Backs `arb node`.

    * `POST /api/nodes/join-tokens` — **operator**: mint a join token. The
      response carries the token (shown once) and the one-liner, which holds no
      secret. Rate limited per actor (`Nodes.RateLimit`, 20/hour).
    * `GET /api/nodes`, `GET /api/nodes/:ref`, `GET /api/nodes/:ref/events` —
      coordinator reads. `:ref` is a node id or its name.
    * `PATCH /api/nodes/:ref` — **operator**: edit `name`, `labels`,
      `max_workers`.

  Credentials and token hashes are never rendered (`ArbiterWeb.Api.NodeJSON`).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{JoinScript, RateLimit}
  alias Arbiter.Settings
  alias ArbiterWeb.Api.NodeJSON

  action_fallback(ArbiterWeb.Api.FallbackController)

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
      {:error, {:rate_limited, seconds}} -> rate_limited(conn, seconds)
      {:error, {:unprocessable, message}} -> unprocessable(conn, message)
      {:error, other} -> {:error, other}
    end
  end

  def index(conn, _params) do
    json(conn, %{nodes: Enum.map(Nodes.list_nodes(), &NodeJSON.node/1)})
  end

  def show(conn, %{"ref" => ref}) do
    with {:ok, node} <- fetch(ref), do: json(conn, %{node: NodeJSON.node(node)})
  end

  def events(conn, %{"ref" => ref}) do
    with {:ok, node} <- fetch(ref) do
      json(conn, %{events: node_events(node)})
    end
  end

  defp node_events(node),
    do: Nodes.events(node_id: node.id) |> Enum.map(&NodeJSON.event/1)

  def update(conn, %{"ref" => ref} = params) do
    with {:ok, node} <- fetch(ref),
         {:ok, changes} <- changes(params),
         {:ok, updated} <- Nodes.update_node(node, changes, nil) do
      json(conn, %{node: NodeJSON.node(updated)})
    else
      {:error, :name_taken} -> {:error, {:conflict, "a node with that name already exists"}}
      {:error, :revoked} -> {:error, {:conflict, "the node is revoked and cannot be edited"}}
      {:error, {:unprocessable, message}} -> unprocessable(conn, message)
      {:error, other} -> {:error, other}
    end
  end

  # ---- helpers ---------------------------------------------------------------

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

  defp check("name", v, acc) when is_binary(v) and v != "",
    do: {:cont, {:ok, Map.put(acc, :name, String.trim(v))}}

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
