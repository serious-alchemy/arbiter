defmodule Arbiter.Nodes do
  @moduledoc """
  Ash domain for remote nodes and the node auth tier
  (`docs/design/remote-workers.md` §3, §5, §15).

    * `mint_join_token/2` — an operator mints a single-use `arbj_` token.
    * `redeem_join_token/3` — a joining node trades it for a node credential.
      The redemption is **one conditional update** (`used_at IS NULL AND
      expires_at > now`, rows affected checked), not read-then-write, so two
      processes racing on one token yield exactly one node.
    * `authenticate/2` — a presented `arbn_<id>.<secret>` credential to its
      node. Revoked nodes, wrong secrets and anything of another shape are all
      `{:error, :invalid_credential}`: callers answer one generic 401.
    * `rotate_credential/2`, `revoke/2`, `remove/2` — the node's lifecycle.

  Every one of those writes a `Arbiter.Nodes.NodeEvent` row naming the acting
  `Arbiter.Actor` (`:operator` for the human's side, `:node` for the node's
  own enrolment). Secrets are never stored or logged: see
  `Arbiter.Nodes.Credentials`.

  This module has no routes and no live sessions; the join flow (RW4) and the
  channel session (RW6) build on it. `ArbiterWeb.Plugs.NodeAuth` is the HTTP
  edge of `authenticate/2`.
  """

  use Ash.Domain

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.Nodes.{Credentials, JoinToken, Node, NodeEvent, Registry}
  alias Arbiter.Repo
  alias Arbiter.Settings

  resources do
    resource Node
    resource JoinToken
    resource NodeEvent
  end

  @max_ttl_seconds 24 * 3600
  @rotation_overlap_seconds 10 * 60
  @touch_every_seconds 60

  @type enrolled :: %{node: Node.t(), credential: String.t()}

  # The characters the join script accepts in a node name. A name outside this
  # set would be spent at enroll and then rejected on the node, so it is
  # refused up front: at mint, at enroll and at edit.
  @name_pattern ~r/\A[A-Za-z0-9._=:\/@-]{1,128}\z/

  @doc "Whether `name` is a well-formed node name (`A-Za-z0-9._=:/@-`, 1-128 chars)."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name_pattern, name)

  defp name_ok?(nil), do: true
  defp name_ok?(name), do: valid_name?(name)

  # ---- join tokens -------------------------------------------------------

  @doc """
  Mint a join token. Options: `:ttl_seconds` (default `nodes.join_token_ttl_minutes`
  — 15 minutes — and at most 24 hours), and the pre-bound `:name`, `:labels`,
  `:max_workers` the enrolling node inherits.

  Returns the secret **once**; only its hash is stored. Writes a
  `token_minted` event attributed to `actor`.
  """
  @spec mint_join_token(keyword(), Actor.t() | String.t() | nil) ::
          {:ok, %{token: String.t(), join_token: JoinToken.t()}} | {:error, term()}
  def mint_join_token(opts \\ [], actor) do
    ttl = Keyword.get(opts, :ttl_seconds, default_ttl_seconds())

    cond do
      not name_ok?(Keyword.get(opts, :name)) ->
        {:error, :invalid_name}

      is_integer(ttl) and ttl > 0 and ttl <= @max_ttl_seconds ->
        do_mint(opts, ttl, actor)

      true ->
        {:error, :invalid_ttl}
    end
  end

  defp do_mint(opts, ttl, actor) do
    {secret, hash} = Credentials.generate_join_token()
    label = Actor.resolve_label(actor)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    attrs = %{
      token_hash: hash,
      expires_at: DateTime.add(now, ttl, :second),
      name: Keyword.get(opts, :name),
      labels: Keyword.get(opts, :labels, []),
      max_workers: Keyword.get(opts, :max_workers),
      created_by: label
    }

    with {:ok, row} <- Ash.create(JoinToken, attrs, action: :mint) do
      record(:token_minted, nil, label, %{
        "join_token_id" => row.id,
        "expires_at" => DateTime.to_iso8601(row.expires_at)
      })

      {:ok, %{token: secret, join_token: row}}
    end
  end

  @doc """
  Redeem a join token and enrol a node. `attrs` (atom or string keys) takes the
  joiner's `name`, `labels` and `max_workers`; the token's pre-bound values win.
  Options: `:remote_addr_hint` (audit only) and `:now` (a clock seam).

  Returns `{:ok, %{node: node, credential: "arbn_…"}}` — the credential is
  shown once — or `{:error, :invalid_token}` for an unknown, expired, used or
  malformed token (one error, so a caller can answer one generic 401), or
  `{:error, :name_taken}` / `{:error, :invalid_name}`, which do not consume the
  token.
  """
  @spec redeem_join_token(term(), map(), keyword()) ::
          {:ok, enrolled()} | {:error, :invalid_token | :name_taken | :invalid_name | term()}
  def redeem_join_token(secret, attrs \\ %{}, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    hint = Keyword.get(opts, :remote_addr_hint)

    case do_redeem(secret, attrs || %{}, now, hint) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        record(:join_failed, nil, nil, %{"reason" => Atom.to_string(reason)}, hint)
        error
    end
  end

  defp do_redeem(secret, attrs, now, hint) do
    with true <- Credentials.join_token?(secret) || {:error, :invalid_token},
         %JoinToken{} = token <-
           find_join_token(Credentials.hash(secret)) || {:error, :invalid_token},
         node_id = Ash.UUIDv7.generate(),
         name = bound_name(token, attrs, node_id),
         :ok <- ensure_name_valid(name),
         :ok <- ensure_name_free(name),
         :ok <- claim(token, node_id, now) do
      enroll(token, node_id, name, attrs, now, hint)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_token}
    end
  end

  defp find_join_token(hash) do
    JoinToken
    |> Ash.Query.filter(token_hash == ^hash)
    |> Ash.read_one!()
  end

  # THE single-use guard (design §5.1.2, U15): one conditional UPDATE. SQLite
  # serialises writers, so of N racers exactly one sees `used_at IS NULL`; the
  # rest affect zero rows. Not `Ash.transact`: that does not roll back under
  # the test sandbox, so the guard is the conditional update itself.
  defp claim(%JoinToken{id: id}, node_id, now) do
    query =
      from(t in "join_tokens",
        where:
          t.id == type(^id, :string) and is_nil(t.used_at) and
            t.expires_at > type(^now, :utc_datetime_usec)
      )

    case Repo.update_all(query,
           set: [used_at: now, used_by_node: node_id]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :invalid_token}
    end
  end

  # Compensation for the (narrow) window where the name was free at the check
  # but a racer took it before our insert: hand the token back, but only if it
  # is still the claim we made.
  defp unclaim(%JoinToken{id: id}, node_id) do
    query =
      from(t in "join_tokens", where: t.id == type(^id, :string) and t.used_by_node == ^node_id)

    Repo.update_all(query, set: [used_at: nil, used_by_node: nil])
    :ok
  end

  defp enroll(token, node_id, name, attrs, now, hint) do
    cred = Credentials.generate_node_credential(node_id)

    fields = %{
      id: node_id,
      name: name,
      labels: bound_labels(token, attrs),
      max_workers: token.max_workers || attr(attrs, :max_workers),
      credential_hash: cred.hash,
      credential_prefix: cred.prefix,
      join_token_id: token.id,
      enrolled_at: now
    }

    case Ash.create(Node, fields, action: :enroll) do
      {:ok, node} ->
        record(
          :enrolled,
          node.id,
          Actor.label(Actor.node(node.name)),
          %{"join_token_id" => token.id},
          hint
        )

        {:ok, %{node: node, credential: cred.credential}}

      {:error, _} ->
        unclaim(token, node_id)
        {:error, :name_taken}
    end
  end

  defp bound_name(token, attrs, node_id) do
    case token.name || attr(attrs, :name) do
      name when is_binary(name) and name != "" -> String.trim(name)
      _ -> "node-" <> String.slice(node_id, -8, 8)
    end
  end

  defp bound_labels(%JoinToken{labels: [_ | _] = labels}, _attrs), do: labels

  defp bound_labels(_token, attrs) do
    case attr(attrs, :labels) do
      labels when is_list(labels) -> Enum.filter(labels, &is_binary/1)
      _ -> []
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  # Before the claim: a name the node script would reject must not spend the token.
  defp ensure_name_valid(name),
    do: if(valid_name?(name), do: :ok, else: {:error, :invalid_name})

  defp ensure_name_free(name) do
    case Node |> Ash.Query.filter(name == ^name) |> Ash.read_one!() do
      nil -> :ok
      _ -> {:error, :name_taken}
    end
  end

  # ---- node credential ---------------------------------------------------

  @doc """
  The node a presented `arbn_<id>.<secret>` credential belongs to. A revoked
  node, a wrong secret, an unknown id, a join token or any other shape is
  `{:error, :invalid_credential}`. A credential replaced by `rotate_credential/2`
  keeps working until its overlap ends.

  Stamps `last_seen_at` (at most once a minute). Option `:now` is a clock seam.
  """
  @spec authenticate(term(), keyword()) :: {:ok, Node.t()} | {:error, :invalid_credential}
  def authenticate(credential, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, id, secret} <- Credentials.parse_node_credential(credential),
         {:ok, _} <- Ecto.UUID.cast(id),
         %Node{status: status} = node when status != :revoked <- get_node(id),
         true <- secret_valid?(node, secret, now) do
      {:ok, touch(node, now)}
    else
      _ -> {:error, :invalid_credential}
    end
  end

  defp secret_valid?(node, secret, now) do
    Credentials.matches?(secret, node.credential_hash) or
      (previous_valid?(node, now) and Credentials.matches?(secret, node.previous_credential_hash))
  end

  defp previous_valid?(%Node{previous_valid_until: %DateTime{} = until}, now),
    do: DateTime.compare(now, until) == :lt

  defp previous_valid?(_node, _now), do: false

  defp touch(%Node{last_seen_at: seen} = node, now) do
    if is_nil(seen) or DateTime.diff(now, seen) >= @touch_every_seconds do
      case Ash.update(node, %{last_seen_at: now}, action: :touch) do
        {:ok, touched} -> touched
        {:error, _} -> node
      end
    else
      node
    end
  end

  @doc """
  Replace the node's credential. The new `arbn_` string is returned once; the
  old one stays valid for a 10 minute overlap so the agent can persist the new
  one before the old stops working. Writes a `rotated` event.
  """
  @spec rotate_credential(Node.t(), Actor.t() | String.t() | nil) ::
          {:ok, enrolled()} | {:error, :revoked | term()}
  def rotate_credential(%Node{id: id}, actor) do
    case get_node(id) do
      %Node{status: :revoked} ->
        {:error, :revoked}

      %Node{} = node ->
        now = DateTime.utc_now()
        cred = Credentials.generate_node_credential(node.id)

        changes = %{
          credential_hash: cred.hash,
          credential_prefix: cred.prefix,
          previous_credential_hash: node.credential_hash,
          previous_valid_until: DateTime.add(now, @rotation_overlap_seconds, :second),
          rotated_at: now
        }

        with {:ok, rotated} <- Ash.update(node, changes, action: :rotate) do
          record(:rotated, node.id, Actor.resolve_label(actor), %{})
          {:ok, %{node: rotated, credential: cred.credential}}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Revoke a node: status `:revoked`, both credential hashes cleared, so its next
  request fails. Idempotent (one `revoked` event).

  A node with a live session is disconnected at once: the session is told to go
  (it tells its channel, which closes the socket through
  `ArbiterWeb.NodeSocket.id/1`, design §4.1/U14) and `{:node_revoked, id}` goes
  out on `topic/0`. Should that notification be lost the session stops itself on
  its next heartbeat. Interrupting the node's runs is the placement layer's job.
  """
  @spec revoke(Node.t(), Actor.t() | String.t() | nil) :: {:ok, Node.t()} | {:error, term()}
  def revoke(%Node{id: id}, actor) do
    case get_node(id) do
      %Node{status: :revoked} = node ->
        {:ok, node}

      %Node{} = node ->
        with {:ok, revoked} <- Ash.update(node, %{}, action: :revoke) do
          record(:revoked, node.id, Actor.resolve_label(actor), %{})
          Registry.notify(node.id, {:disconnect, :revoked})
          broadcast({:node_revoked, node.id})
          {:ok, revoked}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Put a node into drain: no new assignments, runs already live untouched
  (§13). Idempotent. A revoked node is `{:error, :revoked}`. Writes a `drained`
  event (`detail.drain` true) and tells the node's live session.
  """
  @spec drain(Node.t(), Actor.t() | String.t() | nil) :: {:ok, Node.t()} | {:error, term()}
  def drain(%Node{id: id}, actor), do: set_drain(id, true, actor)

  @doc "Leave drain (`drained` event with `detail.drain` false). A revoked node is `{:error, :revoked}`."
  @spec undrain(Node.t(), Actor.t() | String.t() | nil) :: {:ok, Node.t()} | {:error, term()}
  def undrain(%Node{id: id}, actor), do: set_drain(id, false, actor)

  defp set_drain(id, on?, actor) do
    {action, wanted, message} =
      if on?, do: {:drain, :draining, :drain}, else: {:undrain, :active, :undrain}

    case get_node(id) do
      nil ->
        {:error, :not_found}

      %Node{status: :revoked} ->
        {:error, :revoked}

      %Node{status: ^wanted} = node ->
        {:ok, node}

      %Node{} = node ->
        with {:ok, updated} <- Ash.update(node, %{}, action: action) do
          record(:drained, id, Actor.resolve_label(actor), %{"drain" => on?})
          Registry.notify(id, message)
          {:ok, updated}
        end
    end
  end

  @doc """
  Delete a revoked node's row. Its `NodeEvent` history stays. An active node is
  `{:error, :not_revoked}`.
  """
  @spec remove(Node.t(), Actor.t() | String.t() | nil) :: :ok | {:error, term()}
  def remove(%Node{id: id}, actor) do
    case get_node(id) do
      %Node{status: :revoked} = node ->
        with :ok <- Ash.destroy(node) do
          record(:removed, node.id, Actor.resolve_label(actor), %{"name" => node.name})
          :ok
        end

      %Node{} ->
        {:error, :not_revoked}

      nil ->
        {:error, :not_found}
    end
  end

  @settable [:name, :labels, :max_workers]

  @doc """
  Edit a node's `name`, `labels` and `max_workers` (anything else in `changes`
  is ignored: credentials and status have their own verbs). A revoked node is
  `{:error, :revoked}`, a name another node holds `{:error, :name_taken}`.
  Writes an `updated` event naming the fields that actually changed.
  """
  @spec update_node(Node.t(), map(), Actor.t() | String.t() | nil) ::
          {:ok, Node.t()}
          | {:error, :revoked | :name_taken | :invalid_name | :not_found | term()}
  def update_node(%Node{id: id}, changes, actor) do
    case get_node(id) do
      nil ->
        {:error, :not_found}

      %Node{status: :revoked} ->
        {:error, :revoked}

      %Node{} = node ->
        wanted =
          Map.new(@settable, &{&1, settable(changes, &1)}) |> Map.reject(&(elem(&1, 1) == :skip))

        delta = Map.reject(wanted, fn {k, v} -> Map.get(node, k) == v end)

        cond do
          not name_ok?(Map.get(delta, :name)) -> {:error, :invalid_name}
          delta == %{} -> {:ok, node}
          true -> apply_set(node, delta, actor)
        end
    end
  end

  defp settable(changes, key) do
    cond do
      Map.has_key?(changes, key) -> Map.fetch!(changes, key)
      Map.has_key?(changes, Atom.to_string(key)) -> Map.fetch!(changes, Atom.to_string(key))
      true -> :skip
    end
  end

  defp apply_set(node, delta, actor) do
    case Ash.update(node, delta, action: :set) do
      {:ok, updated} ->
        detail = %{"changes" => Map.new(delta, fn {k, v} -> {Atom.to_string(k), v} end)}
        record(:updated, node.id, Actor.resolve_label(actor), detail)
        {:ok, updated}

      {:error, error} ->
        if name_conflict?(error), do: {:error, :name_taken}, else: {:error, error}
    end
  end

  defp name_conflict?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &(Map.get(&1, :field) == :name))

  defp name_conflict?(_), do: false

  # ---- live sessions -----------------------------------------------------

  @doc "The PubSub topic node session events are broadcast on (see `Arbiter.Nodes.Session`)."
  @spec topic() :: String.t()
  def topic, do: "nodes"

  @doc """
  The Phoenix socket id of a node's connection: `ArbiterWeb.NodeSocket.id/1`.
  `Endpoint.broadcast(socket_id(id), "disconnect", %{})` closes it.
  """
  @spec socket_id(String.t()) :: String.t()
  def socket_id(node_id), do: "node_socket:" <> node_id

  @boot_epoch_key {__MODULE__, :boot_epoch}

  @doc """
  The primary's `boot_epoch`: 128 random bits (URL-safe base64) fixed once per
  BEAM start (`Arbiter.Nodes.Supervisor` forces it at boot). Carried in `hello_ok`
  and every `hb_ack`: an agent that sees it change knows the primary restarted
  and that its runs were not carried across (design §10.4).
  """
  @spec boot_epoch() :: String.t()
  def boot_epoch do
    case :persistent_term.get(@boot_epoch_key, nil) do
      nil ->
        epoch = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

        :global.trans({@boot_epoch_key, self()}, fn ->
          case :persistent_term.get(@boot_epoch_key, nil) do
            nil ->
              :persistent_term.put(@boot_epoch_key, epoch)
              epoch

            existing ->
              existing
          end
        end)

      epoch ->
        epoch
    end
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, topic(), message)
  end

  # ---- reads -------------------------------------------------------------

  @doc "A node by id, or `nil`."
  @spec get_node(String.t()) :: Node.t() | nil
  def get_node(id) when is_binary(id) do
    Node |> Ash.Query.filter(id == ^id) |> Ash.read_one!()
  end

  @doc "A node by id or by (unique) name, or `nil`."
  @spec find_node(String.t()) :: Node.t() | nil
  def find_node(ref) when is_binary(ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, _} -> get_node(ref) || get_node_by_name(ref)
      :error -> get_node_by_name(ref)
    end
  end

  defp get_node_by_name(name), do: Node |> Ash.Query.filter(name == ^name) |> Ash.read_one!()

  @doc "Every node, by name."
  @spec list_nodes() :: [Node.t()]
  def list_nodes, do: Node |> Ash.Query.sort(name: :asc) |> Ash.read!()

  @doc "Audit events, oldest first. Options: `:node_id`, `:kind`."
  @spec events(keyword()) :: [NodeEvent.t()]
  def events(opts \\ []) do
    NodeEvent
    |> filter_opt(:node_id, Keyword.get(opts, :node_id))
    |> filter_opt(:kind, Keyword.get(opts, :kind))
    |> Ash.Query.sort(at: :asc, id: :asc)
    |> Ash.read!()
  end

  defp filter_opt(query, _field, nil), do: query
  defp filter_opt(query, :node_id, id), do: Ash.Query.filter(query, node_id == ^id)
  defp filter_opt(query, :kind, kind), do: Ash.Query.filter(query, kind == ^kind)

  # ---- audit -------------------------------------------------------------

  @doc """
  Append a `NodeEvent`. A failure to audit is logged, never raised: the
  security decision it records has already been made.
  """
  @spec record(atom(), String.t() | nil, String.t() | nil, map(), String.t() | nil) :: :ok
  def record(kind, node_id, actor_label, detail, remote_addr_hint \\ nil) do
    attrs = %{
      kind: kind,
      node_id: node_id,
      actor: actor_label,
      detail: detail,
      remote_addr_hint: remote_addr_hint
    }

    case Ash.create(NodeEvent, attrs, action: :record) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        require Logger
        Logger.error("Nodes.record(#{kind}) failed: #{Exception.message(error)}")
        :ok
    end
  end

  defp default_ttl_seconds, do: Settings.nodes_join_token_ttl_minutes() * 60
end
