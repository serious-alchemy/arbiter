defmodule Arbiter.Agents.Gemini.ModelCatalog do
  @moduledoc """
  A cached view of the models the installed `agy` CLI will actually accept
  (`agy models`).

  The tier → model maps (`Arbiter.Agents.Gemini.Config.default_tier_models/1`
  plus workspace `tier_models` overrides) are hand-maintained, and `agy`
  auto-updates under a running server: when it drops a model, every spawn that
  resolves to it dies at startup with "invalid model selection" (bd-7wx2lh).
  This module is how the rest of the system stops trusting those maps:

    * `Arbiter.Agents.Gemini` consults `available?/2` / `substitute/3` at spawn
      time and swaps an unavailable model for the nearest available one;
    * `Arbiter.Agents.Gemini.ModelCheck` compares the configured maps with
      `list/1` for `arb server doctor` and the boot-time warning.

  ## Freshness

  A good listing is cached for `@ttl_ms`. A model that is *missing* from the
  cached listing re-probes (at most once per `@retry_ms`) before it is declared
  unavailable, so a CLI update that adds a model is picked up without a restart
  and without waiting out the TTL. A failed probe (agy not installed, timeout,
  unparseable or empty output) yields `:unknown`, retried after `@retry_ms`;
  `available?/2` treats `:unknown` as "available" — a broken probe must never
  block a spawn that might well have worked.

  Tests inject the probe with `probe:` (a 0-arity fun returning
  `{:ok, [model]} | {:error, term}`) or `config :arbiter, :agy_models_probe`,
  and the clock with `now:`.
  """

  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.SpawnEnv

  require Logger

  @cache_key {__MODULE__, :cache}
  @ttl_ms :timer.minutes(10)
  @retry_ms :timer.seconds(30)
  @probe_timeout_ms 15_000

  # Cheapest to most capable. Distance along this ladder decides which tier's
  # model stands in for an unavailable one.
  @ladder ["economy", "standard", "premium", "flagship"]

  @type listing :: {:ok, [String.t()]} | :unknown

  @doc "The tier ladder, cheapest first."
  @spec ladder() :: [String.t()]
  def ladder, do: @ladder

  @doc """
  The models `agy models` lists, from cache when fresh. `:unknown` when the
  probe failed or listed nothing.

  Options: `:probe`, `:now` (ms), `:ttl_ms`, `:retry_ms`.
  """
  @spec list(keyword()) :: listing()
  def list(opts \\ []) do
    {result, _fetched_at} = fetch(opts)
    result
  end

  @doc "Probe now, ignoring the cache, and cache the outcome."
  @spec refresh(keyword()) :: listing()
  def refresh(opts \\ []) do
    {result, _fetched_at} = probe_and_cache(opts)
    result
  end

  @doc "Drop the cache (tests, and after an operator upgrades agy)."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Whether `agy` will accept `model`. `true` when the listing is unknown. A miss
  against a stale-enough cache re-probes once before answering `false`.
  """
  @spec available?(String.t(), keyword()) :: boolean()
  def available?(model, opts \\ []) when is_binary(model) do
    case fetch(opts) do
      {:unknown, _} ->
        true

      {{:ok, models}, fetched_at} ->
        model in models or recheck(model, fetched_at, opts)
    end
  end

  defp recheck(model, fetched_at, opts) do
    if now(opts) - fetched_at >= retry_ms(opts) do
      case refresh(opts) do
        {:ok, models} -> model in models
        :unknown -> true
      end
    else
      false
    end
  end

  @doc """
  Pick a stand-in for an unavailable model.

  `tier` is the requested tier (`nil` starts from the middle of the ladder),
  `tier_models` the effective tier → model map, `available` the listing. The
  nearest tier whose model is available wins (ties go to the higher tier);
  failing that, any available model; `nil` when nothing is available.
  """
  @spec substitute(String.t() | nil, %{String.t() => String.t()}, [String.t()]) ::
          String.t() | nil
  def substitute(tier, tier_models, available) when is_map(tier_models) do
    from = Enum.find_index(@ladder, &(&1 == tier)) || 1

    nearest =
      @ladder
      |> Enum.with_index()
      |> Enum.filter(fn {t, _i} -> Map.get(tier_models, t) in available end)
      |> Enum.min_by(fn {_t, i} -> {abs(i - from), -i} end, fn -> nil end)

    case nearest do
      {t, _i} -> Map.fetch!(tier_models, t)
      nil -> List.first(available)
    end
  end

  @doc "The `{tier, model}` pairs of `tier_models` that `available` does not list."
  @spec missing(%{String.t() => String.t()}, [String.t()]) :: [{String.t(), String.t()}]
  def missing(tier_models, available) when is_map(tier_models) do
    tier_models
    |> Enum.reject(fn {_tier, model} -> model in available end)
    |> Enum.sort_by(fn {tier, _} -> {Enum.find_index(@ladder, &(&1 == tier)) || 99, tier} end)
  end

  @doc """
  Model ids in `agy models` output: the first word of each line that looks like
  an id (lowercase, hyphenated, carrying a digit), after stripping list bullets.
  Prose such as `Available models:` is ignored.
  """
  @spec parse(String.t()) :: [String.t()]
  def parse(output) when is_binary(output) do
    output
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&first_word/1)
    |> Enum.filter(&model_id?/1)
    |> Enum.uniq()
  end

  defp first_word(line) do
    line
    |> String.trim()
    |> String.trim_leading("-")
    |> String.trim_leading("*")
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end

  defp model_id?(word),
    do: Regex.match?(~r/^[a-z][a-z0-9]*(-[a-z0-9.]+)+$/, word) and Regex.match?(~r/\d/, word)

  # ---- cache ------------------------------------------------------------

  defp fetch(opts) do
    now = now(opts)
    ttl = ttl_ms(opts)
    retry = retry_ms(opts)

    case :persistent_term.get(@cache_key, nil) do
      {{:ok, _}, at} = hit when now - at < ttl -> hit
      {:unknown, at} = hit when now - at < retry -> hit
      _ -> probe_and_cache(opts)
    end
  end

  defp probe_and_cache(opts) do
    # A failed re-probe keeps the last good listing (stale-while-error) rather
    # than forgetting what agy served a minute ago.
    result =
      case {run_probe(opts), :persistent_term.get(@cache_key, nil)} do
        {{:ok, [_ | _] = models}, _} -> {:ok, models}
        {_, {{:ok, _} = last_good, _}} -> last_good
        _ -> :unknown
      end

    entry = {result, now(opts)}
    :persistent_term.put(@cache_key, entry)
    entry
  end

  defp run_probe(opts) do
    case opts[:probe] || Application.get_env(:arbiter, :agy_models_probe) do
      fun when is_function(fun, 0) -> fun.()
      _ -> shell_out()
    end
  rescue
    e -> {:error, e}
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)
  defp ttl_ms(opts), do: Keyword.get(opts, :ttl_ms, @ttl_ms)
  defp retry_ms(opts), do: Keyword.get(opts, :retry_ms, @retry_ms)

  # `agy` backgrounds its own language server, which inherits whatever stdout
  # points at; a plain `System.cmd` pipe would never see EOF (see the same
  # note on `Arbiter.Quota.CloudCode`'s usage probe). Redirect to a file at the
  # shell level instead, inside a private directory, under `timeout`.
  defp shell_out do
    cmd = Application.get_env(:arbiter, :agy_cmd) || "agy"

    case System.find_executable(cmd) do
      nil -> {:error, :not_installed}
      path -> run_agy_models(path)
    end
  end

  defp run_agy_models(path) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arbiter-agy-models-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    out = Path.join(dir, "models.txt")
    timeout_s = max(1, ceil(@probe_timeout_ms / 1000))

    try do
      {_, status} =
        ReleaseEnv.cmd(
          "/bin/sh",
          [
            "-c",
            ~s(exec timeout -k 1 #{timeout_s} "$0" models >"$1" 2>/dev/null </dev/null),
            path,
            out
          ],
          env: SpawnEnv.cmd_env([], "gemini")
        )

      with 0 <- status,
           {:ok, raw} <- File.read(out) do
        {:ok, parse(raw)}
      else
        status when is_integer(status) ->
          Logger.warning("Arbiter.Agents.Gemini.ModelCatalog: `agy models` exited #{status}")
          {:error, {:exit, status}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm_rf(dir)
    end
  end
end
