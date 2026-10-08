defmodule Arbiter.Nodes.RateLimit do
  @moduledoc """
  Rate limiting for the node auth tier (`docs/design/remote-workers.md` §5.4).
  No dependency: one process owns a map of token buckets, so every
  read-modify-write is atomic. The traffic it sees (enrolment attempts, mints,
  socket-connect failures) is far too low for that to matter.

  256-bit tokens make brute force infeasible; the limiter exists for resource
  exhaustion and log noise. Rules:

    * `:enroll` — `POST /nodes/enroll`: 10 attempts a minute **globally**, and 5
      *failures* per 10 minutes per source `key`.
    * `:mint` — join-token minting: 20 an hour per `key` (the actor label).
    * `:socket_connect` — `NodeSocket.connect/3`: 30 *failures* a minute
      globally. A check costs nothing; only `record_failure/3` spends.

    * `:pair` — `POST /nodes/pair` (a device-code pairing request,
      `Arbiter.Nodes.Pairing`): 5 per 10 minutes per source `key`. The cap on
      pending requests is the domain's.
    * `:pair_poll` — a node polling its request: 60 a minute per source `key`,
      and 10 *failures* (unknown request or wrong poll secret) per 10 minutes.

  `check/3` answers `:ok` or `{:error, {:rate_limited, retry_after_seconds}}`
  (the route's `429` + `Retry-After`). A failure bucket blocks while empty: five
  recorded failures block that source until one token refills.

  ## Source key

  Behind `tailscale serve` every peer is `127.0.0.1`, so the caller should key
  on `X-Forwarded-For` **only when the peer is loopback** (the condition
  `DashboardAuth.Default` uses for Tailscale headers), else on the peer
  address. That choice is the route's: this module only takes a string.

  Options on every function: `:server` (default this module's registered name)
  and `:now_ms` (a clock seam).
  """

  use GenServer

  # rule => attempts / failures bucket specs as {scope, capacity, window_ms}
  @rules %{
    enroll: %{attempts: {:global, 10, 60_000}, failures: {:key, 5, 600_000}},
    mint: %{attempts: {:key, 20, 3_600_000}, failures: nil},
    socket_connect: %{attempts: nil, failures: {:global, 30, 60_000}},
    pair: %{attempts: {:key, 5, 600_000}, failures: nil},
    pair_poll: %{attempts: {:key, 60, 60_000}, failures: {:key, 10, 600_000}}
  }
  @rule_names Map.keys(@rules)
  @sweep_interval_ms 5 * 60_000

  @type rule :: :enroll | :mint | :socket_connect | :pair | :pair_poll

  # ---- client ------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Spend one attempt for `rule` / `key`. `:ok`, or `{:error, {:rate_limited,
  retry_after_seconds}}` when an attempt bucket is empty or a failure bucket is
  exhausted. Nothing is spent when refused.
  """
  @spec check(rule(), String.t(), keyword()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(rule, key, opts \\ []) when rule in @rule_names and is_binary(key),
    do: call(opts, {:check, rule, key, now(opts)})

  @doc "Record a failed attempt for `rule` / `key` against its failure bucket."
  @spec record_failure(rule(), String.t(), keyword()) :: :ok
  def record_failure(rule, key, opts \\ []) when rule in @rule_names and is_binary(key),
    do: call(opts, {:record_failure, rule, key, now(opts)})

  @doc "Forget every bucket."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []), do: call(opts, :reset)

  @doc "The number of live buckets (for tests and the sweeper)."
  @spec size(keyword()) :: non_neg_integer()
  def size(opts \\ []), do: call(opts, :size)

  @doc "Drop buckets that have fully refilled (equivalent to never having been used)."
  @spec sweep(keyword()) :: :ok
  def sweep(opts \\ []), do: call(opts, {:sweep, now(opts)})

  defp call(opts, msg), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), msg)
  defp now(opts), do: Keyword.get(opts, :now_ms) || System.monotonic_time(:millisecond)

  # ---- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    unless Keyword.get(opts, :sweep, true) == false,
      do: Process.send_after(self(), :sweep, @sweep_interval_ms)

    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, rule, key, now}, _from, buckets) do
    %{attempts: attempts, failures: failures} = Map.fetch!(@rules, rule)

    with {:ok, buckets} <- peek_failures(buckets, rule, failures, key, now),
         {:ok, buckets} <- spend_attempt(buckets, rule, attempts, key, now) do
      {:reply, :ok, buckets}
    else
      {:error, retry, buckets} -> {:reply, {:error, {:rate_limited, retry}}, buckets}
    end
  end

  def handle_call({:record_failure, rule, key, now}, _from, buckets) do
    case Map.fetch!(@rules, rule).failures do
      nil ->
        {:reply, :ok, buckets}

      spec ->
        {_result, buckets} = take(buckets, bucket_id(rule, :failures, spec, key), spec, now)
        {:reply, :ok, buckets}
    end
  end

  def handle_call(:reset, _from, _buckets), do: {:reply, :ok, %{}}
  def handle_call(:size, _from, buckets), do: {:reply, map_size(buckets), buckets}
  def handle_call({:sweep, now}, _from, buckets), do: {:reply, :ok, sweep_buckets(buckets, now)}

  @impl true
  def handle_info(:sweep, buckets) do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, sweep_buckets(buckets, System.monotonic_time(:millisecond))}
  end

  def handle_info(_msg, buckets), do: {:noreply, buckets}

  # A failure bucket blocks while it holds less than one token; the peek spends
  # nothing.
  defp peek_failures(buckets, _rule, nil, _key, _now), do: {:ok, buckets}

  defp peek_failures(buckets, rule, spec, key, now) do
    id = bucket_id(rule, :failures, spec, key)
    {_scope, capacity, window} = spec
    {tokens, _at} = refill(Map.get(buckets, id), capacity, window, now)

    if tokens >= 1,
      do: {:ok, buckets},
      else: {:error, retry_after(tokens, capacity, window), buckets}
  end

  defp spend_attempt(buckets, _rule, nil, _key, _now), do: {:ok, buckets}

  defp spend_attempt(buckets, rule, spec, key, now) do
    case take(buckets, bucket_id(rule, :attempts, spec, key), spec, now) do
      {:ok, buckets} -> {:ok, buckets}
      {{:empty, retry}, buckets} -> {:error, retry, buckets}
    end
  end

  # Take one token from the bucket (creating it full).
  defp take(buckets, id, {_scope, capacity, window}, now) do
    {tokens, _at} = refill(Map.get(buckets, id), capacity, window, now)

    if tokens >= 1 do
      {:ok, Map.put(buckets, id, {tokens - 1, now})}
    else
      {{:empty, retry_after(tokens, capacity, window)}, Map.put(buckets, id, {tokens, now})}
    end
  end

  defp refill(nil, capacity, _window, now), do: {capacity * 1.0, now}

  defp refill({tokens, at}, capacity, window, now) do
    elapsed = max(now - at, 0)
    {min(capacity * 1.0, tokens + elapsed * capacity / window), now}
  end

  defp retry_after(tokens, capacity, window) do
    ms = (1 - tokens) * window / capacity
    max(ceil(ms / 1000), 1)
  end

  defp bucket_id(rule, kind, {:global, _, _}, _key), do: {rule, kind, :global}
  defp bucket_id(rule, kind, {:key, _, _}, key), do: {rule, kind, key}

  defp sweep_buckets(buckets, now) do
    Map.reject(buckets, fn {{rule, kind, _}, {tokens, at}} ->
      {_scope, capacity, window} = Map.fetch!(@rules, rule) |> Map.fetch!(kind)
      {refilled, _} = refill({tokens, at}, capacity, window, now)
      refilled >= capacity
    end)
  end
end
