defmodule ArbiterWeb.DashboardAuth.LoginTokens do
  @moduledoc """
  One-time dashboard login tokens (bd-3gycsz).

  `arb dashboard login` asks `POST /api/dashboard/login_tokens` (coordinator
  token required) for one; the browser redeems it at `/login`. A token is 256
  random bits, lives `@ttl_seconds` and is deleted when redeemed. They are
  held in memory only (stored as SHA-256 digests), so a restart invalidates
  every outstanding one — they are minutes-long by design.
  """

  use GenServer

  @table __MODULE__
  @ttl_seconds 120

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Mint a token valid for `ttl_seconds` (default #{@ttl_seconds})."
  @spec mint(integer()) :: String.t()
  def mint(ttl_seconds \\ @ttl_seconds) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    :ets.insert(@table, {digest(token), now() + ttl_seconds})
    sweep()
    token
  end

  @doc "Redeem a token. Succeeds at most once."
  @spec consume(term()) :: {:ok, :redeemed} | :error
  def consume(token) when is_binary(token) do
    case :ets.take(@table, digest(token)) do
      [{_digest, expires}] -> if expires > now(), do: {:ok, :redeemed}, else: :error
      [] -> :error
    end
  end

  def consume(_), do: :error

  @doc false
  def ttl_seconds, do: @ttl_seconds

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, nil}
  end

  defp sweep do
    cutoff = now()
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}])
  end

  defp digest(token), do: :crypto.hash(:sha256, token)
  defp now, do: System.system_time(:second)
end
