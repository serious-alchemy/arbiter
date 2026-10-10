defmodule Arbiter.NodeAgent.PodChannel.BootNonce do
  @moduledoc """
  The single-use `/boot` nonce (`docs/design/remote-workers.md` §16 K§12).

  The pod spec carries `ARB_BOOT_NONCE`; the pod's `seed` init container
  redeems it on `:9444/boot` for the run's secrets and certificates. It is the
  only per-run credential a Kubernetes object ever holds, so it is worth
  nothing once used:

    * **256 bits** of randomness;
    * **single-use**: a redeemed nonce is gone;
    * **expiring** at `boot_s` after it was issued (binding the pod IP does not
      extend the window);
    * **bound** to the pod's `status.podIP` (the informer reports it) and to the
      run. Until the IP is bound the nonce cannot be redeemed, and trying does
      not spend it (the pod's `seed` retries); from the wrong address it is
      **spent**, so a nonce read off `kubectl get pod` and replayed from
      elsewhere makes the real pod fail closed rather than race the thief.

  Only a SHA-256 of each nonce is kept, so inspecting or logging this state
  discloses nothing redeemable. This is a pure value; `Arbiter.NodeAgent.PodChannel.Runs`
  owns the one instance.
  """

  @default_ttl_ms 120_000

  defstruct ttl_ms: @default_ttl_ms, clock: nil, entries: %{}, by_run: %{}

  @type t :: %__MODULE__{}
  @type reason :: :unknown | :expired | :unbound | :wrong_ip

  @doc "Options: `:ttl_ms` (default `120_000`, the design's `boot_s`), `:clock` (monotonic ms)."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    }
  end

  @doc "Issue a nonce for `run`, replacing any earlier one. `{nonce, state}`."
  @spec issue(t(), String.t()) :: {String.t(), t()}
  def issue(%__MODULE__{} = state, run) do
    nonce = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    key = digest(nonce)
    state = revoke(state, run)
    entry = %{run: run, ip: nil, expires_at: state.clock.() + state.ttl_ms}

    {nonce,
     %{
       state
       | entries: Map.put(state.entries, key, entry),
         by_run: Map.put(state.by_run, run, key)
     }}
  end

  @doc "The informer reported `run`'s pod IP: its nonce can now be redeemed from `ip`."
  @spec bind(t(), String.t(), :inet.ip_address()) :: t()
  def bind(%__MODULE__{} = state, run, ip) do
    with key when not is_nil(key) <- state.by_run[run],
         %{} = entry <- state.entries[key] do
      %{state | entries: Map.put(state.entries, key, %{entry | ip: ip})}
    else
      _ -> state
    end
  end

  @doc """
  Redeem `nonce` from `peer_ip`. `{{:ok, run}, state}` once; otherwise
  `{{:error, reason}, state}`: `:unknown` (never issued, spent, revoked: not
  told apart), `:expired`, `:unbound` (not spent) or `:wrong_ip`.
  """
  @spec redeem(t(), String.t(), :inet.ip_address()) ::
          {{:ok, String.t()} | {:error, reason()}, t()}
  def redeem(%__MODULE__{} = state, nonce, peer_ip) when is_binary(nonce) do
    key = digest(nonce)

    case state.entries[key] do
      nil -> {{:error, :unknown}, state}
      entry -> redeem_entry(state, key, entry, peer_ip)
    end
  end

  def redeem(%__MODULE__{} = state, _nonce, _peer_ip), do: {{:error, :unknown}, state}

  defp redeem_entry(state, key, entry, peer_ip) do
    cond do
      state.clock.() >= entry.expires_at -> {{:error, :expired}, drop(state, key, entry)}
      entry.ip == nil -> {{:error, :unbound}, state}
      entry.ip != peer_ip -> {{:error, :wrong_ip}, drop(state, key, entry)}
      true -> {{:ok, entry.run}, drop(state, key, entry)}
    end
  end

  @doc "Drop `run`'s nonce (the run ended or was cancelled)."
  @spec revoke(t(), String.t()) :: t()
  def revoke(%__MODULE__{} = state, run) do
    case state.by_run[run] do
      nil -> state
      key -> drop(state, key, %{run: run})
    end
  end

  @doc "Drop every expired nonce."
  @spec sweep(t()) :: t()
  def sweep(%__MODULE__{} = state) do
    now = state.clock.()

    Enum.reduce(state.entries, state, fn {key, entry}, acc ->
      if now >= entry.expires_at, do: drop(acc, key, entry), else: acc
    end)
  end

  @doc "How many nonces are outstanding."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: map_size(entries)

  defp drop(state, key, %{run: run}),
    do: %{state | entries: Map.delete(state.entries, key), by_run: Map.delete(state.by_run, run)}

  defp digest(nonce), do: :crypto.hash(:sha256, nonce)
end
