defmodule Arbiter.Nodes.Pairing do
  @moduledoc """
  Device-code style enrolment (`docs/design/remote-workers.md` §5.7): a node
  asks for a pairing, shows the operator a short code, and the operator approves
  that code on the primary. No long secret is typed anywhere.

  The **code is not the secret.** It only binds "the request on the node's
  screen" to "the request the operator approves". The credential goes to
  whoever presents the **poll secret** (`arbp_…`, 256 bits, returned once by
  `request/2` to the requesting node and stored only as a hash).

  ## State machine

      pending ──approve──▶ approved ──redeem──▶ redeemed
         │                    │
         ├──deny──▶ denied    └──(ttl)──▶ expired
         └──(ttl)──▶ expired

  Every transition is **one conditional update** (`state = from [AND expires_at
  > now]`, rows affected checked), so two racers on one request yield exactly one
  winner: one approval, one credential. The credential is generated at
  `redeem/3` and never stored.

    * `request/2` — anonymous side (the node, via `POST /nodes/pair`). Refuses
      past the per-source and total caps of pending requests.
    * `approve/4`, `deny/3`, `list_pending/1`, `get/2` — operator side. The HTTP
      and CLI edges enforce the operator-proof token; the dashboard is behind
      `DashboardAuth`.
    * `redeem/3` — the node polling with its secret: `{:pending, _}` until the
      operator acts; the credential once approved; `{:error, :denied |
      :expired | :invalid}` otherwise. Unknown request, wrong secret and an
      already-redeemed request are all `:invalid`.

  Every outcome is a `Arbiter.Nodes.NodeEvent` (`pairing_requested`,
  `pairing_approved`, `pairing_denied`, `pairing_expired`, `pairing_rejected`,
  and `enrolled` at redemption). Expiry is applied lazily by whatever touches
  the table next (and audited then, with the request's own `expires_at`).

  Options on the functions that take them: `:now` (a clock seam).
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Credentials, PairingRequest}
  alias Arbiter.Repo

  @ttl_seconds 10 * 60
  @max_pending 20
  @max_pending_per_peer 3
  @keep_terminal_seconds 24 * 3600
  @code_attempts 5
  @label_pattern ~r/\A[A-Za-z0-9._=:\/@-]{1,64}\z/
  @max_labels 16

  @type result :: {:ok, PairingRequest.t()} | {:error, atom()}

  @doc "How long a request stays valid, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc "The most pending requests the primary holds at once."
  @spec max_pending() :: pos_integer()
  def max_pending, do: @max_pending

  @doc "The most pending requests one source address may hold."
  @spec max_pending_per_peer() :: pos_integer()
  def max_pending_per_peer, do: @max_pending_per_peer

  # ---- the node's side -----------------------------------------------------

  @doc """
  Open a pairing request. `attrs` takes the node's `hostname` (sanitised: it is
  the node's own claim) and optional proposed `name`, `labels`, `max_workers`.
  Option `:peer` (required) is the source address as the route saw it.

  `{:ok, %{request: req, secret: "arbp_…"}}` — the secret is shown once — or
  `{:error, :invalid_name}` / `{:error, :too_many_pending}` (audited as
  `pairing_rejected`).
  """
  @spec request(map(), keyword()) ::
          {:ok, %{request: PairingRequest.t(), secret: String.t()}}
          | {:error, :invalid_name | :too_many_pending | :unavailable}
  def request(attrs, opts) do
    peer = Keyword.fetch!(opts, :peer)
    now = now(opts)
    name = attr(attrs, :name)

    with :ok <- check_name(name),
         :ok <- expire_stale(now),
         :ok <- check_caps(peer, now) do
      insert(attrs, name, peer, now, @code_attempts)
    end
  end

  defp check_name(nil), do: :ok

  defp check_name(name),
    do: if(Nodes.valid_name?(name), do: :ok, else: {:error, :invalid_name})

  # Best-effort, not atomic with the insert that follows: concurrent requests
  # from one source can briefly pass the per-peer cap. The per-source request
  # rate limit in front of `POST /nodes/pair` bounds the overshoot, and every
  # request still expires after the TTL. (Wrapping count + insert in one
  # transaction is avoided: the audit write in `reject/2` and the code-collision
  # retry in `insert/5` must not be rolled back with it.)
  defp check_caps(peer, now) do
    cond do
      count_pending(now, nil) >= @max_pending -> reject(peer, "total")
      count_pending(now, peer) >= @max_pending_per_peer -> reject(peer, "peer")
      true -> :ok
    end
  end

  defp reject(peer, scope) do
    Nodes.record(
      :pairing_rejected,
      nil,
      nil,
      %{"reason" => "too_many_pending", "scope" => scope},
      peer
    )

    {:error, :too_many_pending}
  end

  defp count_pending(now, nil) do
    PairingRequest
    |> Ash.Query.filter(state == :pending and expires_at > ^now)
    |> Ash.count!()
  end

  defp count_pending(now, peer) do
    PairingRequest
    |> Ash.Query.filter(state == :pending and expires_at > ^now and peer == ^peer)
    |> Ash.count!()
  end

  defp insert(_attrs, _name, _peer, _now, 0), do: {:error, :unavailable}

  defp insert(attrs, name, peer, now, attempts_left) do
    {secret, hash} = Credentials.generate_pairing_secret()

    fields = %{
      code: Credentials.generate_pairing_code(),
      secret_hash: hash,
      hostname: sanitize_hostname(attr(attrs, :hostname)),
      peer: peer,
      name: name,
      labels: clean_labels(attr(attrs, :labels)),
      max_workers: clean_max_workers(attr(attrs, :max_workers)),
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    case Ash.create(PairingRequest, fields, action: :request) do
      {:ok, req} ->
        Nodes.record(
          :pairing_requested,
          nil,
          nil,
          %{
            "request_id" => req.id,
            "code" => req.code,
            "hostname" => req.hostname,
            "expires_at" => DateTime.to_iso8601(req.expires_at)
          },
          peer
        )

        Nodes.broadcast({:pairing_requested, req.id})
        {:ok, %{request: req, secret: secret}}

      {:error, _} ->
        # The only expected failure is a code collision (40 random bits).
        insert(attrs, name, peer, now, attempts_left - 1)
    end
  end

  @doc """
  The node polling for its outcome. `{:pending, request}` while the operator
  has not acted; `{:ok, %{node: node, credential: "arbn_…"}}` once approved, and
  only once; `{:error, :denied | :expired | :name_taken | :invalid}` otherwise.
  Option `:remote_addr_hint` is the audit address.
  """
  @spec redeem(term(), term(), keyword()) ::
          {:ok, Nodes.enrolled()}
          | {:pending, PairingRequest.t()}
          | {:error, :denied | :expired | :name_taken | :invalid}
  def redeem(id, secret, opts \\ []) do
    now = now(opts)

    case authentic(id, secret) do
      {:ok, req} -> advance(req, now, Keyword.get(opts, :remote_addr_hint))
      :error -> {:error, :invalid}
    end
  end

  defp authentic(id, secret) when is_binary(id) and is_binary(secret) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %PairingRequest{} = req <- fetch(id),
         true <- Credentials.matches?(secret, req.secret_hash) do
      {:ok, req}
    else
      _ -> :error
    end
  end

  defp authentic(_id, _secret), do: :error

  defp advance(%{state: :denied}, _now, _hint), do: {:error, :denied}
  defp advance(%{state: :expired}, _now, _hint), do: {:error, :expired}
  defp advance(%{state: :redeemed}, _now, _hint), do: {:error, :invalid}

  defp advance(%{state: state} = req, now, hint) when state in [:pending, :approved] do
    cond do
      expired?(req, now) ->
        expire(req, now)
        {:error, :expired}

      state == :pending ->
        {:pending, req}

      true ->
        claim(req, now, hint)
    end
  end

  # THE single-use guard: approved → redeemed as one conditional UPDATE. Of N
  # racers on one approval exactly one affects a row and mints the credential.
  defp claim(req, now, hint) do
    node_id = Ash.UUIDv7.generate()

    case transition(req.id, :approved, :redeemed, now, [node_id: node_id], expiry: true) do
      1 -> enroll(req, node_id, now, hint)
      0 -> {:error, :invalid}
    end
  end

  defp enroll(req, node_id, now, hint) do
    binding = %{
      node_id: node_id,
      name: req.name || "node-" <> String.slice(node_id, -8, 8),
      labels: req.labels,
      max_workers: req.max_workers,
      detail: %{"pairing_request_id" => req.id}
    }

    case Nodes.insert_node(binding, now, hint) do
      {:ok, enrolled} ->
        Nodes.broadcast({:pairing_resolved, req.id, :redeemed})
        Nodes.broadcast({:node_enrolled, node_id, nil})
        {:ok, enrolled}

      {:error, _} = error ->
        # Hand the approval back (only if it is still our claim), so the node's
        # next poll can retry once the operator has renamed or cleared the clash.
        revert(req.id, node_id)
        error
    end
  end

  defp revert(id, node_id) do
    from(r in "pairing_requests",
      where: r.id == type(^id, :string) and r.node_id == ^node_id and r.state == "redeemed"
    )
    |> Repo.update_all(set: [state: "approved", node_id: nil, resolved_at: nil])

    :ok
  end

  # ---- the operator's side ---------------------------------------------------

  @doc """
  Live (pending or approved, unexpired) requests by id or typed code, or `nil`.
  """
  @spec get(String.t(), keyword()) :: PairingRequest.t() | nil
  def get(ref, opts \\ []) when is_binary(ref) do
    now = now(opts)

    req =
      case Credentials.normalize_pairing_code(ref) do
        {:ok, code} -> fetch_by_code(code)
        :error -> if match?({:ok, _}, Ecto.UUID.cast(ref)), do: fetch(ref)
      end

    if req && req.state in [:pending, :approved] && not expired?(req, now), do: req
  end

  @doc "Pending requests, oldest first. Stale ones are expired (and audited) first."
  @spec list_pending(keyword()) :: [PairingRequest.t()]
  def list_pending(opts \\ []) do
    now = now(opts)
    :ok = expire_stale(now)

    PairingRequest
    |> Ash.Query.filter(state == :pending and expires_at > ^now)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!()
  end

  @doc """
  Approve a pending request by id or code. `attrs` (`name`, `max_workers`)
  replace the node's proposal (its labels stand; `arb node set` edits them); a name the node script would
  reject, or one already taken, refuses the approval and leaves the request
  pending. `actor` is the acting `Arbiter.Actor` (or label, or `nil` for the
  ambient one).
  """
  @spec approve(String.t(), map(), Actor.t() | String.t() | nil, keyword()) ::
          result() | {:error, :not_found | :not_pending | :invalid_name | :name_taken}
  def approve(ref, attrs, actor, opts \\ []) do
    now = now(opts)

    with %PairingRequest{} = req <- get(ref, opts) || {:error, :not_found},
         :ok <- if(req.state == :pending, do: :ok, else: {:error, :not_pending}),
         name = attr(attrs, :name) || req.name,
         :ok <- check_name(name),
         :ok <- name_free(name),
         label = Actor.resolve_label(actor),
         set = approval(req, attrs, name, label, now),
         1 <- transition(req.id, :pending, :approved, now, set, expiry: true) do
      Nodes.record(
        :pairing_approved,
        nil,
        label,
        %{"request_id" => req.id, "hostname" => req.hostname, "name" => name},
        req.peer
      )

      Nodes.broadcast({:pairing_resolved, req.id, :approved})
      {:ok, fetch(req.id)}
    else
      {:error, _} = error -> error
      0 -> {:error, :not_pending}
    end
  end

  defp approval(req, attrs, name, label, now) do
    [name: name, approved_by: label, approved_at: now]
    |> put_present(:max_workers, attrs, :max_workers, req, &clean_max_workers/1)
  end

  # An operator-supplied key replaces the node's proposal (`max_workers: nil`
  # clears it); an absent key keeps it.
  defp put_present(set, field, attrs, key, req, clean) do
    if has_attr?(attrs, key),
      do: Keyword.put(set, field, clean.(attr(attrs, key))),
      else: Keyword.put(set, field, Map.fetch!(req, field))
  end

  defp name_free(nil), do: :ok
  defp name_free(name), do: if(Nodes.name_taken?(name), do: {:error, :name_taken}, else: :ok)

  @doc "Deny a pending request by id or code."
  @spec deny(String.t(), Actor.t() | String.t() | nil, keyword()) ::
          result() | {:error, :not_found | :not_pending}
  def deny(ref, actor, opts \\ []) do
    now = now(opts)

    with %PairingRequest{} = req <- get(ref, opts) || {:error, :not_found},
         1 <- transition(req.id, :pending, :denied, now, [], expiry: true) do
      Nodes.record(
        :pairing_denied,
        nil,
        Actor.resolve_label(actor),
        %{"request_id" => req.id, "hostname" => req.hostname},
        req.peer
      )

      Nodes.broadcast({:pairing_resolved, req.id, :denied})
      {:ok, fetch(req.id)}
    else
      {:error, _} = error -> error
      0 -> {:error, :not_pending}
    end
  end

  # ---- expiry ----------------------------------------------------------------

  @doc """
  Expire every pending or approved request past its `expires_at` (auditing each
  as `pairing_expired`) and prune long-finished rows.
  """
  @spec expire_stale(DateTime.t()) :: :ok
  def expire_stale(now \\ DateTime.utc_now()) do
    PairingRequest
    |> Ash.Query.filter(state in [:pending, :approved] and expires_at <= ^now)
    |> Ash.read!()
    |> Enum.each(&expire(&1, now))

    cutoff = DateTime.add(now, -@keep_terminal_seconds, :second)

    from(r in "pairing_requests",
      where:
        r.state in ["denied", "expired", "redeemed"] and
          r.updated_at < type(^cutoff, :utc_datetime_usec)
    )
    |> Repo.delete_all()

    :ok
  end

  defp expire(%PairingRequest{state: from_state} = req, now) do
    if transition(req.id, from_state, :expired, now, []) == 1 do
      Nodes.record(
        :pairing_expired,
        nil,
        nil,
        %{
          "request_id" => req.id,
          "was" => Atom.to_string(from_state),
          "expires_at" => DateTime.to_iso8601(req.expires_at)
        },
        req.peer
      )

      Nodes.broadcast({:pairing_resolved, req.id, :expired})
    end

    :ok
  end

  # ---- plumbing --------------------------------------------------------------

  # The one write path for `state`: `UPDATE … SET state = to WHERE id = ? AND
  # state = from [AND expires_at > now]`. Returns the rows affected.
  defp transition(id, from_state, to_state, now, set, opts \\ []) do
    base =
      from(r in "pairing_requests",
        where: r.id == type(^id, :string) and r.state == ^Atom.to_string(from_state)
      )

    query =
      if Keyword.get(opts, :expiry, false),
        do: from(r in base, where: r.expires_at > type(^now, :utc_datetime_usec)),
        else: base

    resolved = if to_state in [:redeemed, :denied, :expired], do: [resolved_at: now], else: []

    {count, _} =
      Repo.update_all(query,
        set: [state: Atom.to_string(to_state), updated_at: now] ++ resolved ++ set
      )

    count
  end

  defp fetch(id), do: PairingRequest |> Ash.Query.filter(id == ^id) |> Ash.read_one!()

  defp fetch_by_code(code),
    do: PairingRequest |> Ash.Query.filter(code == ^code) |> Ash.read_one!()

  defp expired?(%{expires_at: at}, now), do: DateTime.compare(at, now) != :gt

  defp now(opts), do: Keyword.get(opts, :now) || DateTime.utc_now()

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp has_attr?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  # The hostname is the node's own claim, shown to the operator: keep it to a
  # hostname-safe alphabet (no escapes, no newlines, no look-alike markup).
  defp sanitize_hostname(host) when is_binary(host) do
    case host |> String.replace(~r/[^A-Za-z0-9._-]/, "") |> String.slice(0, 64) do
      "" -> "unknown"
      clean -> clean
    end
  end

  defp sanitize_hostname(_), do: "unknown"

  defp clean_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&(is_binary(&1) and Regex.match?(@label_pattern, &1)))
    |> Enum.take(@max_labels)
  end

  defp clean_labels(_), do: []

  defp clean_max_workers(n) when is_integer(n) and n >= 1, do: n
  defp clean_max_workers(_), do: nil
end
