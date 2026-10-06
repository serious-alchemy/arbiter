defmodule Arbiter.Nodes.Credentials do
  @moduledoc """
  Secret formats for the node auth tier (`docs/design/remote-workers.md`
  §5.1–5.2, §15). Pure: no database, no clock.

    * **Join token** `arbj_<52 base32>` — 256 random bits, single-use, shown to
      the operator once. Only `hash/1` of it is persisted.
    * **Node credential** `arbn_<node_id>.<52 base32>` — what an enrolled node
      presents. The id routes the lookup; only `hash/1` of the secret half and a
      short display `prefix` are persisted.

  Both are 256-bit random values, so a fast hash (SHA-256) is appropriate: there
  is nothing to brute-force, and the hash exists so a database read does not
  yield a usable credential. Neither format is an `Arbiter.MCP.Scope` token, so
  `Scope.from_token/1` rejects them and no `/api` or `/mcp` route accepts one.
  """

  @join_prefix "arbj_"
  @node_prefix "arbn_"
  @secret_bytes 32
  @display_prefix_len 8

  @type node_credential :: %{
          credential: String.t(),
          hash: String.t(),
          prefix: String.t()
        }

  @doc "The join-token prefix, `\"arbj_\"`."
  @spec join_prefix() :: String.t()
  def join_prefix, do: @join_prefix

  @doc "The node-credential prefix, `\"arbn_\"`."
  @spec node_prefix() :: String.t()
  def node_prefix, do: @node_prefix

  @doc "A fresh join token: `{secret, hash}`. Persist only the hash."
  @spec generate_join_token() :: {String.t(), String.t()}
  def generate_join_token do
    secret = @join_prefix <> random_secret()
    {secret, hash(secret)}
  end

  @doc """
  A fresh credential for `node_id`: the full `arbn_<id>.<secret>` string (shown
  once), the `hash` of the secret half and its short display `prefix`.
  """
  @spec generate_node_credential(String.t()) :: node_credential()
  def generate_node_credential(node_id) when is_binary(node_id) do
    secret = random_secret()

    %{
      credential: @node_prefix <> node_id <> "." <> secret,
      hash: hash(secret),
      prefix: String.slice(secret, 0, @display_prefix_len)
    }
  end

  @doc "Hex SHA-256 of a secret."
  @spec hash(String.t()) :: String.t()
  def hash(secret) when is_binary(secret),
    do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  @doc "Whether `value` has the shape of a join token (not whether it is valid)."
  @spec join_token?(term()) :: boolean()
  def join_token?(@join_prefix <> body) when body != "", do: true
  def join_token?(_), do: false

  @doc """
  Split `arbn_<id>.<secret>` into `{:ok, node_id, secret}`; `:error` for any
  other shape (including a join token or a Scope token).
  """
  @spec parse_node_credential(term()) :: {:ok, String.t(), String.t()} | :error
  def parse_node_credential(@node_prefix <> rest) do
    case String.split(rest, ".", parts: 2) do
      [id, secret] when id != "" and secret != "" -> {:ok, id, secret}
      _ -> :error
    end
  end

  def parse_node_credential(_), do: :error

  @doc """
  Whether `secret` hashes to the stored `stored_hash`, compared in constant
  time. A missing or empty stored hash (revoked, or no rotation overlap) never
  matches.
  """
  @spec matches?(String.t(), String.t() | nil) :: boolean()
  def matches?(secret, stored_hash)
      when is_binary(secret) and is_binary(stored_hash) and stored_hash != "",
      do: Plug.Crypto.secure_compare(hash(secret), stored_hash)

  def matches?(_secret, _stored_hash), do: false

  defp random_secret,
    do:
      @secret_bytes |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
end
