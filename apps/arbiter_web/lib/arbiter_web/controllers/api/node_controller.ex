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
      `local + Σ remote caps`,
      `warnings`, and the `nodes.public_url` with its `exposure`
      (`private | public | unset`) and the image `registry` status (K8: reachability,
      published images, last error; never the password) for `arb server doctor`.
    * `GET /api/nodes/pairings`, `POST /api/nodes/pairings/:ref/{approve,deny}` —
      **operator**: the pending device-code pairing requests (code, hostname,
      source address) and the decision on one. `:ref` is the typed code or the
      request id. Approval creates no node itself: the node collects its
      credential by polling (`Arbiter.Nodes.Pairing`).
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
  alias Arbiter.Nodes.{ClusterInstall, JoinScript, Overview, Pairing, RateLimit}
  alias Arbiter.Settings
  alias Arbiter.Worker.Image.Publisher
  alias ArbiterWeb.Api.NodeJSON

  action_fallback(ArbiterWeb.Api.FallbackController)

  @local_cap_message "local takes max_workers only: a whole number, 0 or more, or null to clear"
  @name_message "name may only contain A-Za-z0-9._=:/@- and be 1-128 characters"
  @kind_message "kind must be machine or cluster"

  def create_join_token(conn, params) do
    with {:ok, url} <- public_url(),
         {:ok, kind} <- kind(params),
         {:ok, opts} <- mint_opts(params),
         {:ok, cluster} <- cluster_plan(kind, params, opts),
         :ok <- mint_limit(),
         {:ok, %{token: token, join_token: row}} <-
           Nodes.mint_join_token([{:kind, kind} | opts], nil) do
      conn
      |> put_status(:created)
      |> put_resp_header("cache-control", "no-store")
      |> json(
        %{
          token: token,
          join_token: NodeJSON.join_token(row),
          one_liner: JoinScript.one_liner(url),
          public_url: url
        }
        |> put_cluster(cluster)
      )
    else
      {:error, :invalid_ttl} -> {:error, {:invalid, "ttl_seconds must be between 1 and 86400"}}
      {:error, :invalid_name} -> {:error, {:invalid, @name_message}}
      {:error, :invalid_kind} -> {:error, {:invalid, @kind_message}}
      {:error, {:rate_limited, seconds}} -> rate_limited(conn, seconds)
      {:error, other} -> {:error, other}
    end
  end

  defp kind(params) do
    case params["kind"] do
      kind when kind in [nil, "machine"] -> {:ok, "machine"}
      "cluster" -> {:ok, "cluster"}
      _ -> {:error, {:invalid, @kind_message}}
    end
  end

  # K9: the manifest URL, apply command and join-Secret command for a cluster node.
  # Planned before the token is minted, so a request that cannot be rendered (no
  # `nodes.registry`, a bad value) spends nothing. The manifests and the token agree
  # on the node's name, so a cluster node needs one.
  defp cluster_plan("machine", _params, _opts), do: {:ok, nil}

  defp cluster_plan("cluster", params, opts) do
    case Keyword.get(opts, :name) do
      nil ->
        {:error, {:invalid, "name is required for a cluster node: the manifests are bound to it"}}

      name ->
        form =
          params
          |> Map.take(ClusterInstall.form_keys())
          |> Map.new(fn {k, v} -> {k, form_value(k, v)} end)
          |> Map.put("name", name)
          |> put_max(Keyword.get(opts, :max_workers))

        case ClusterInstall.plan(form) do
          {:ok, plan} -> {:ok, plan}
          {:error, errors} when is_list(errors) -> {:error, {:invalid, Enum.join(errors, "; ")}}
          {:error, reason} -> {:error, {:invalid, cluster_unavailable(reason)}}
        end
    end
  end

  defp put_max(form, nil), do: form
  defp put_max(form, max), do: Map.put(form, "max", Integer.to_string(max))

  # JSON gives numbers and booleans; the renderer's vocabulary is the query string's.
  defp form_value("admission", true), do: "policy"
  defp form_value("admission", false), do: "none"
  defp form_value(key, true) when key in ["self_upgrade"], do: "on"
  defp form_value(key, false) when key in ["self_upgrade"], do: "off"

  defp form_value("node_selector", %{} = map),
    do: Enum.map_join(map, ",", fn {k, v} -> "#{k}=#{v}" end)

  defp form_value(_key, value) when is_integer(value), do: Integer.to_string(value)
  defp form_value(_key, value), do: value

  defp cluster_unavailable(:no_registry),
    do:
      "nodes.registry is not set; a cluster node needs an image it can pull (see arb server doctor)"

  defp cluster_unavailable(:no_public_url), do: "nodes.public_url is not set"

  defp cluster_unavailable(:no_release),
    do: "the primary has no deployed release to name an image for"

  defp put_cluster(body, nil), do: body
  defp put_cluster(body, plan), do: body |> Map.delete(:one_liner) |> Map.put(:cluster, plan)

  # ---- device-code pairing (design §5.7) --------------------------------------

  def pairings(conn, _params),
    do: json(conn, %{pairings: Enum.map(Pairing.list_pending(), &NodeJSON.pairing/1)})

  def approve_pairing(conn, %{"ref" => ref} = params) do
    attrs = Map.take(params, ["name", "max_workers"])

    with :ok <- check_pairing_attrs(attrs),
         {:ok, req} <- Pairing.approve(ref, attrs, nil) do
      json(conn, %{pairing: NodeJSON.pairing(req)})
    else
      {:error, :invalid_name} -> {:error, {:invalid, @name_message}}
      {:error, :name_taken} -> {:error, {:conflict, "a node with that name already exists"}}
      {:error, :not_pending} -> {:error, {:conflict, "that pairing request is no longer pending"}}
      {:error, other} -> {:error, other}
    end
  end

  def deny_pairing(conn, %{"ref" => ref}) do
    case Pairing.deny(ref, nil) do
      {:ok, req} -> json(conn, %{pairing: NodeJSON.pairing(req)})
      {:error, :not_pending} -> {:error, {:conflict, "that pairing request is no longer pending"}}
      {:error, other} -> {:error, other}
    end
  end

  defp check_pairing_attrs(attrs) do
    case attrs do
      %{"max_workers" => n} when not is_nil(n) and not (is_integer(n) and n >= 1) ->
        {:error, {:invalid, "max_workers must be a whole number, 1 or more"}}

      %{"name" => n} when not is_binary(n) ->
        {:error, :invalid_name}

      _ ->
        :ok
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
      remote_execution: overview.remote_execution?,
      local_cap_advisory: Settings.local_cap_advisory(),
      warnings: overview.warnings,
      public_url: url,
      exposure: Overview.exposure(url),
      registry: Publisher.status(),
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
      {:error, :invalid_value} -> {:error, {:invalid, @local_cap_message}}
      {:error, other} -> {:error, other}
    end
  end

  def update(conn, %{"ref" => ref} = params) do
    with {:ok, node} <- fetch(ref),
         {:ok, changes} <- changes(params),
         {:ok, updated} <- Nodes.update_node(node, changes, nil) do
      json(conn, %{node: node_view(updated)})
    else
      {:error, :invalid_name} ->
        {:error, {:invalid, @name_message}}

      {:error, :invalid_max_workers} ->
        {:error, {:invalid, "max_workers must be 1 or more, or null"}}

      {:error, :invalid_allow_unenforced_network} ->
        {:error, {:invalid, "allow_unenforced_network must be true or false"}}

      {:error, :name_taken} ->
        {:error, {:conflict, "a node with that name already exists"}}

      {:error, :revoked} ->
        {:error, {:conflict, "the node is revoked and cannot be edited"}}

      {:error, other} ->
        {:error, other}
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
      :error -> {:error, {:invalid, @local_cap_message}}
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
      nil -> {:error, {:invalid, "nodes.public_url is not set; set it before adding nodes"}}
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
    keys = ["name", "labels", "max_workers", "workspace_ids", "allow_unenforced_network"]

    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
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
      else: {:halt, {:error, {:invalid, @name_message}}}
  end

  defp check("labels", v, acc) when is_list(v) do
    if Enum.all?(v, &is_binary/1),
      do: {:cont, {:ok, Map.put(acc, :labels, v)}},
      else: {:halt, {:error, {:invalid, "labels must be a list of strings"}}}
  end

  defp check("workspace_ids", v, acc) when is_list(v) do
    if Enum.all?(v, &is_binary/1),
      do: {:cont, {:ok, Map.put(acc, :workspace_ids, v)}},
      else: {:halt, {:error, {:invalid, "workspace_ids must be a list of workspace ids"}}}
  end

  defp check("allow_unenforced_network", v, acc) when is_boolean(v),
    do: {:cont, {:ok, Map.put(acc, :allow_unenforced_network, v)}}

  defp check("max_workers", v, acc) when is_nil(v) or is_integer(v),
    do: {:cont, {:ok, Map.put(acc, :max_workers, v)}}

  defp check(key, _v, _acc),
    do: {:halt, {:error, {:invalid, "#{key} has the wrong type"}}}

  defp rate_limited(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{type: "rate_limited", message: "too many join tokens minted", details: %{}}
    })
  end
end
