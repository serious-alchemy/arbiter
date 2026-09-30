defmodule Arbiter.Release.UpdateCheck do
  @moduledoc """
  Periodically asks GitHub for the latest published Arbiter release and records
  whether it is newer than the running version. **Check and notify only** — it
  never deploys or restarts anything.

  The result (`state/1`) is `%{enabled, latest, release_url, checked_at,
  update_available?, error}`, held in memory and served by `GET /api/version`,
  the home page and `arb version`. A failed check (rate limit, network, parse)
  is stored in `:error` and keeps the last good `latest`; it is never logged
  above `:debug` and never crashes the process.

  ## "Latest" matches `arb server deploy`

  Both use `GET /repos/<ARB_RELEASE_REPO>/releases/latest`, which GitHub
  defines as the newest non-draft, non-prerelease release. `GITHUB_TOKEN` is
  sent when set (needed for a private repo); otherwise the request is
  unauthenticated and conditional (`If-None-Match`) so a 304 does not count
  against the rate limit.

  ## Version comparison

  `newer?/2` compares `major.minor.patch` numerically. A `-published`
  suffix or `git describe` suffix (`-5-gabc1234`) on the running version is
  ignored, i.e. it counts as that release. A latest tag carrying a pre-release
  suffix (`-rc1`) is never reported, and unparseable versions are never an
  update.

  ## Configuration

  `config :arbiter, :update_check` (prod enables it; dev/test leave it off):

    * `:enabled` — master switch. `ARBITER_UPDATE_CHECK=0` also disables it, for
      air-gapped installs.
    * `:interval_ms` — base interval (default 6h, jittered ±10%);
      `ARBITER_UPDATE_CHECK_INTERVAL_HOURS` overrides.
    * `:initial_delay_ms` — delay before the first check (default 1 minute).
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.hours(6)
  @default_initial_delay_ms :timer.minutes(1)
  @default_api "https://api.github.com"

  @empty %{
    enabled: false,
    latest: nil,
    release_url: nil,
    checked_at: nil,
    update_available?: false,
    error: nil
  }

  # ── public API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    if enabled?(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Current result. Reports `enabled: false` when the checker is not running."
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  catch
    :exit, _ -> @empty
  end

  @doc "Run a check now (synchronously) and return the resulting state."
  @spec check_now(GenServer.server()) :: map()
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now, 60_000)

  @doc """
  True when `latest` is a stable release newer than `running`.
  """
  @spec newer?(String.t() | nil, String.t() | nil) :: boolean()
  def newer?(latest, running) do
    with {:ok, l} <- parse_latest(latest),
         {:ok, r} <- parse_running(running) do
      l > r
    else
      _ -> false
    end
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      result: %{@empty | enabled: true},
      etag: nil,
      repo: Keyword.get_lazy(opts, :repo, fn -> env("ARB_RELEASE_REPO") end),
      running: Keyword.get_lazy(opts, :running_version, &Arbiter.Version.app_version/0),
      interval_ms: Keyword.get(opts, :interval_ms, interval_ms()),
      req_options: Keyword.get(opts, :req_options, [])
    }

    case Keyword.get(
           opts,
           :initial_delay_ms,
           config(:initial_delay_ms, @default_initial_delay_ms)
         ) do
      :infinity -> :ok
      ms -> Process.send_after(self(), :check, ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.result, state}

  def handle_call(:check_now, _from, state) do
    state = run_check(state)
    {:reply, state.result, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = run_check(state)
    Process.send_after(self(), :check, jitter(state.interval_ms))
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ── checking ──────────────────────────────────────────────────────────────

  defp run_check(%{repo: repo} = state) when repo in [nil, ""] do
    record_error(state, "ARB_RELEASE_REPO is not set")
  end

  defp run_check(state) do
    case fetch(state) do
      {:ok, tag, url, etag} ->
        result = %{
          state.result
          | latest: tag,
            release_url: url,
            checked_at: DateTime.utc_now(),
            update_available?: newer?(tag, state.running),
            error: nil
        }

        %{state | result: result, etag: etag}

      :not_modified ->
        %{state | result: %{state.result | checked_at: DateTime.utc_now(), error: nil}}

      {:error, message} ->
        record_error(state, message)
    end
  rescue
    e -> record_error(state, "update check crashed: " <> Exception.message(e))
  end

  defp record_error(state, message) do
    Logger.debug("Arbiter.Release.UpdateCheck: #{message}")
    %{state | result: %{state.result | checked_at: DateTime.utc_now(), error: message}}
  end

  defp fetch(state) do
    url = api() <> "/repos/" <> state.repo <> "/releases/latest"

    req =
      [
        method: :get,
        url: url,
        headers: headers(state.etag),
        receive_timeout: 15_000,
        retry: false
      ] ++ state.req_options

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => tag} = body} = resp}
      when is_binary(tag) and tag != "" ->
        etag = resp |> Req.Response.get_header("etag") |> List.first()
        {:ok, tag, body["html_url"], etag}

      {:ok, %Req.Response{status: 200}} ->
        {:error, "release response had no tag_name"}

      {:ok, %Req.Response{status: 304}} ->
        :not_modified

      {:ok, %Req.Response{status: status}} ->
        {:error, "GitHub Releases API returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "could not reach GitHub: " <> inspect(reason)}
    end
  end

  defp headers(etag) do
    base = [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
    base = if etag, do: [{"if-none-match", etag} | base], else: base

    case env("GITHUB_TOKEN") do
      nil -> base
      token -> [{"authorization", "Bearer #{token}"} | base]
    end
  end

  # ── version parsing ───────────────────────────────────────────────────────

  defp parse_latest(tag) when is_binary(tag) do
    case Regex.run(~r/^v?(\d+)\.(\d+)\.(\d+)$/, String.trim(tag)) do
      [_, a, b, c] -> {:ok, {String.to_integer(a), String.to_integer(b), String.to_integer(c)}}
      _ -> :error
    end
  end

  defp parse_latest(_), do: :error

  defp parse_running(v) when is_binary(v) do
    case Regex.run(~r/^v?(\d+)\.(\d+)\.(\d+)(?:-.*)?$/, String.trim(v)) do
      [_, a, b, c] -> {:ok, {String.to_integer(a), String.to_integer(b), String.to_integer(c)}}
      _ -> :error
    end
  end

  defp parse_running(_), do: :error

  # ── config ────────────────────────────────────────────────────────────────

  defp enabled?(opts) do
    Keyword.get_lazy(opts, :enabled, fn ->
      config(:enabled, false) and env("ARBITER_UPDATE_CHECK") not in ["0", "false"]
    end)
  end

  defp interval_ms do
    with hours when is_binary(hours) <- env("ARBITER_UPDATE_CHECK_INTERVAL_HOURS"),
         {h, ""} when h > 0 <- Float.parse(hours) do
      round(h * 3_600_000)
    else
      _ -> config(:interval_ms, @default_interval_ms)
    end
  end

  defp jitter(ms), do: ms + :rand.uniform(max(div(ms, 5), 1)) - div(ms, 10)

  defp api, do: String.trim_trailing(env("ARB_GITHUB_API") || @default_api, "/")

  defp config(key, default) do
    :arbiter |> Application.get_env(:update_check, []) |> Keyword.get(key, default)
  end

  defp env(name) do
    case System.get_env(name) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end
end
