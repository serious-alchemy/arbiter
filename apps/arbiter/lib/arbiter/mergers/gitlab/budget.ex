defmodule Arbiter.Mergers.Gitlab.Budget do
  @moduledoc """
  Arbiter's GitLab API budget (bd-dpimvl): the per-user rate limit is shared
  with the operator's `glab`, so every request is metered and cached.

    * `path_lookup/3` — `path_with_namespace` per `(host, project_id)` for the
      process lifetime. Success is kept forever; a 403/404 is negatively cached
      for `:gitlab_path_negative_ttl_ms` (default 1 h); any other failure
      (timeout, 5xx) for `:gitlab_path_transient_ttl_ms` (default 30 s). The
      result carries `:fresh | :cached` so a caller logs once per TTL.
    * `gate/3` — wraps one request: waits out a per-host cooldown set by an
      earlier 429 (`Retry-After` / `RateLimit-Reset`, capped at 5 min), counts
      the request per call site, and records `RateLimit-*` headers.
    * `snapshot/0`, `doctor_check/0` — read side for doctor.

  State lives in a public ETS table owned by a small lazily-spawned process.
  The clock and sleep are overridable via `:gitlab_budget_now_ms` /
  `:gitlab_budget_sleep` app env for tests.
  """

  @table :arbiter_gitlab_budget
  @max_wait_ms 300_000
  @default_cooldown_ms 30_000

  # ---- path cache ---------------------------------------------------------

  @spec path_lookup(String.t(), String.t(), (-> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term(), :fresh | :cached}
  def path_lookup(host, project_id, fetch) when is_function(fetch, 0) do
    ensure_table()
    key = {:path, host, project_id}
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, {:ok, path}, _}] ->
        {:ok, path}

      [{^key, {:error, reason}, expires}] when expires > now ->
        {:error, reason, :cached}

      _ ->
        case fetch.() do
          {:ok, path} = ok ->
            :ets.insert(@table, {key, ok, :infinity})
            {:ok, path}

          {:error, reason} ->
            :ets.insert(@table, {key, {:error, reason}, now + failure_ttl(reason)})
            {:error, reason, :fresh}
        end
    end
  end

  defp failure_ttl({:http_status, s}) when s in [403, 404],
    do: Application.get_env(:arbiter, :gitlab_path_negative_ttl_ms, 3_600_000)

  defp failure_ttl(_),
    do: Application.get_env(:arbiter, :gitlab_path_transient_ttl_ms, 30_000)

  # ---- request gate -------------------------------------------------------

  @spec gate(String.t(), String.t(), (-> term())) :: term()
  def gate(host, site, fun) when is_function(fun, 0) do
    ensure_table()
    wait_for_cooldown(host)
    :ets.update_counter(@table, {:count, site}, 1, {{:count, site}, 0})
    result = fun.()
    record(host, result)
    result
  end

  defp wait_for_cooldown(host) do
    case :ets.lookup(@table, {:cooldown, host}) do
      [{_, until}] ->
        wait = min(until - now_ms(), @max_wait_ms)
        if wait > 0, do: sleep(wait)

      _ ->
        :ok
    end
  end

  defp record(host, {:ok, %Req.Response{status: status} = resp}) do
    remaining = header_int(resp, "ratelimit-remaining")
    limit = header_int(resp, "ratelimit-limit")
    prev = host_state(host)

    state = %{
      prev
      | remaining: remaining || prev.remaining,
        limit: limit || prev.limit
    }

    state =
      if status == 429 do
        wait = rate_limit_wait_ms(resp)
        :ets.insert(@table, {{:cooldown, host}, now_ms() + wait})
        %{state | last_429_at: DateTime.utc_now(), last_429_wait_ms: wait}
      else
        state
      end

    :ets.insert(@table, {{:host, host}, state})
  end

  defp record(_host, _other), do: :ok

  defp rate_limit_wait_ms(resp) do
    retry =
      case header_int(resp, "retry-after") do
        s when is_integer(s) and s >= 0 -> s * 1_000
        _ -> nil
      end

    reset =
      case header_int(resp, "ratelimit-reset") do
        epoch when is_integer(epoch) ->
          ms = (epoch - System.os_time(:second)) * 1_000
          if ms > 0, do: ms

        _ ->
          nil
      end

    case Enum.filter([retry, reset], & &1) do
      [] -> @default_cooldown_ms
      list -> Enum.max(list)
    end
  end

  defp header_int(resp, name) do
    with [v | _] <- Req.Response.get_header(resp, name),
         {n, _} <- Integer.parse(to_string(v)) do
      n
    else
      _ -> nil
    end
  end

  defp host_state(host) do
    case :ets.lookup(@table, {:host, host}) do
      [{_, s}] -> s
      _ -> %{remaining: nil, limit: nil, last_429_at: nil, last_429_wait_ms: nil}
    end
  end

  @doc "Call-site label for a request: `\"GET /api/v4/projects/:id/...\"`."
  @spec site(atom(), String.t()) :: String.t()
  def site(method, url) do
    path = url |> URI.parse() |> Map.get(:path) |> to_string()
    norm = Regex.replace(~r{/\d+(?=/|$)}, path, "/:id")
    String.upcase(to_string(method)) <> " " <> norm
  end

  # ---- read side ----------------------------------------------------------

  @spec snapshot() :: %{counts: map(), hosts: map()}
  def snapshot do
    ensure_table()
    rows = :ets.tab2list(@table)

    %{
      counts: for({{:count, site}, n} <- rows, into: %{}, do: {site, n}),
      hosts: for({{:host, host}, s} <- rows, into: %{}, do: {host, s})
    }
  end

  @spec doctor_check() :: %{severity: :ok | :warn, summary: String.t(), detail: String.t()}
  def doctor_check do
    %{counts: counts, hosts: hosts} = snapshot()
    total = counts |> Map.values() |> Enum.sum()
    top = counts |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(3)

    parts =
      Enum.map(hosts, fn {host, s} ->
        remaining = if s.remaining, do: "remaining #{s.remaining}", else: "remaining unknown"

        last =
          if s.last_429_at,
            do: "last 429 #{DateTime.to_iso8601(s.last_429_at)}",
            else: "no 429"

        "#{host}: #{remaining}, #{last}"
      end)

    top_s = Enum.map_join(top, "; ", fn {site, n} -> "#{site} ×#{n}" end)

    detail =
      Enum.join(
        parts ++ ["#{total} requests since boot" <> if(top_s == "", do: "", else: " (#{top_s})")],
        " | "
      )

    limited? = Enum.any?(hosts, fn {_, s} -> s.last_429_at end)

    %{
      severity: if(limited?, do: :warn, else: :ok),
      summary: if(limited?, do: "GitLab rate limit hit", else: "GitLab API budget ok"),
      detail: detail
    }
  end

  @doc "Clears all cached state (tests)."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
  end

  # ---- internals ----------------------------------------------------------

  defp now_ms do
    case Application.get_env(:arbiter, :gitlab_budget_now_ms) do
      f when is_function(f, 0) -> f.()
      _ -> System.monotonic_time(:millisecond)
    end
  end

  defp sleep(ms) do
    case Application.get_env(:arbiter, :gitlab_budget_sleep) do
      f when is_function(f, 1) -> f.(ms)
      _ -> Process.sleep(ms)
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      parent = self()
      ref = make_ref()

      spawn(fn ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          send(parent, {ref, :ok})
        rescue
          ArgumentError -> send(parent, {ref, :ok})
        end

        Process.sleep(:infinity)
      end)

      receive do
        {^ref, :ok} -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end
end
