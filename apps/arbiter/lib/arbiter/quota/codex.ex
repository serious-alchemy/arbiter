defmodule Arbiter.Quota.Codex do
  @moduledoc """
  Direct Codex (OpenAI) quota tracking (bd-cqfn5i), modeled on 9router's
  `open-sse/services/usage/codex.js` (`getCodexUsage`).

  Arbiter has no passive quota signal for Codex the way it does for Claude (via
  `Arbiter.Quota.OAuthUsage` polling and header capture from worker traffic).
  This module makes **one direct GET** to OpenAI's usage endpoint using the
  OAuth token the real `codex` CLI already keeps fresh in `~/.codex/auth.json`,
  and upserts the result into `Arbiter.Quota.CodexQuota`.

  ## Credentials — read-only

  We read `tokens.access_token` (sent as `Authorization: Bearer …`) and
  `tokens.account_id` (sent as the `ChatGPT-Account-ID` header) from
  `~/.codex/auth.json`. **We never write to that file.** No refresh logic lives
  here: the `codex` CLI refreshes the token during normal worker dispatch. If
  the token is expired at read time the endpoint returns `401`, and we skip the
  cycle gracefully (no snapshot written) rather than trying to refresh it
  ourselves.

  ## Response shape

  The endpoint returns a `rate_limit` object (also seen as `rate_limits` or
  `rate_limits_by_limit_id.codex`) with a `primary_window` (the **session**
  window) and a `secondary_window` (the **weekly** window). Each carries a
  used-percent (`used_percent` / `percent_used`) and a reset time
  (`reset_at` / `resets_at` / `resetAt`). `normalize/1` translates that into
  `CodexQuota` attrs; `serialize/1` renders the public
  `{used, total: 100, remaining, reset_at, unlimited: false}` window shape
  9router uses.

  ## Graceful no-op

  When Codex isn't authenticated for this machine (no readable auth file / no
  access token), `fetch/2` returns `%{codex: nil, message: …}` and makes **no**
  HTTP call, mirroring 9router's "Usage API not implemented for X" handling of
  unsupported providers.

  ## Configuration

  Via `config :arbiter, :codex_quota`:

    * `:auth_path` — override the `~/.codex/auth.json` location (tests).
    * `:usage_url` — override the usage endpoint URL.

  In test, `config :arbiter, :codex_quota_http_stub, true` routes the request
  through `Req.Test` stub `#{inspect(__MODULE__)}.HTTP`.
  """

  require Logger
  require Ash.Query

  alias Arbiter.Accounts.Resolver
  alias Arbiter.Quota.CodexPlanWindows
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.CodexQuotaSnapshot
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Pace

  @stub_name __MODULE__.HTTP
  @default_usage_url "https://chatgpt.com/backend-api/wham/usage"
  @default_provider "codex"
  @request_timeout_ms 15_000
  @history_retention_days 90
  @window_columns [
    :session_used_percent,
    :session_reset_at,
    :weekly_used_percent,
    :weekly_reset_at,
    :session_window_minutes,
    :weekly_window_minutes
  ]

  defp default_auth_path do
    case System.get_env("CODEX_HOME") do
      dir when is_binary(dir) and dir != "" -> Path.join(dir, "auth.json")
      _ -> "~/.codex/auth.json"
    end
  end

  @type window :: %{
          used: float(),
          total: 100,
          remaining: float(),
          reset_at: String.t() | nil,
          unlimited: false
        }

  @type result :: %{codex: map() | nil, message: String.t() | nil, auth_expired: boolean()}

  # ---- fetch -------------------------------------------------------------

  @doc """
  Fetch Codex quota for `workspace_id` via a direct usage API call, upsert the
  snapshot, and return the serialized windows.

  The row is keyed by the provider account the workspace meters under (P5,
  `docs/provider-account-design.md` §6), resolved here so the probe's call
  site is unchanged; two workspaces on one Codex plan write the same row.

  Never raises. Returns `%{codex: map() | nil, message: String.t() | nil,
  auth_expired: boolean()}`:

    * creds absent → `%{codex: nil, message: "Codex CLI not authenticated…"}`,
      no HTTP call.
    * expired-token `401` → `%{codex: nil, message: "Codex connected. Usage
      API temporarily unavailable (401).", auth_expired: true}`, no snapshot
      written. `auth_expired` is the free credential-expiry signal
      `Arbiter.Quota.CloudProbe` feeds to `Arbiter.Agents.CredentialWatchdog`
      after N consecutive 401s (bd-1fpjgx) — a dedicated boolean rather than
      something parsed back out of the message text, since any other non-200
      status produces the same message shape with a different number spliced
      in.
    * other non-200 → `%{codex: nil, message: …, auth_expired: false}`, no
      snapshot written.
    * `200` with no window data → `%{codex: nil, message: …, auth_expired:
      false}`.
    * `200` with windows → `%{codex: serialized, message: nil, auth_expired:
      false}` and a fresh `CodexQuota` row.

  Options:

    * `:credentials` — inject `%{access_token, account_id}`, bypassing the file.
    * `:auth_path`   — override the auth file path.
    * `:usage_url`   — override the endpoint URL.
  """
  @spec fetch(String.t(), keyword()) :: result()
  def fetch(workspace_id, opts \\ []) when is_binary(workspace_id) do
    case resolve_credentials(opts) do
      {:ok, creds} ->
        fetch_with_credentials(workspace_id, creds, opts)

      {:error, _reason} ->
        %{
          codex: nil,
          message: "Codex CLI not authenticated for this workspace",
          auth_expired: false
        }
    end
  rescue
    e ->
      Logger.debug("Arbiter.Quota.Codex.fetch raised: #{Exception.message(e)}")
      %{codex: nil, message: "Codex quota unavailable", auth_expired: false}
  end

  defp fetch_with_credentials(workspace_id, creds, opts) do
    case request_usage(creds, opts) do
      {:ok, 200, body} ->
        handle_ok_body(workspace_id, body)

      {:ok, 401, _body} ->
        %{
          codex: nil,
          message: "Codex connected. Usage API temporarily unavailable (401).",
          auth_expired: true
        }

      {:ok, status, _body} ->
        %{
          codex: nil,
          message: "Codex connected. Usage API temporarily unavailable (#{status}).",
          auth_expired: false
        }

      {:error, reason} ->
        Logger.debug("Arbiter.Quota.Codex: usage request failed: #{inspect(reason)}")
        %{codex: nil, message: "Codex connected. Usage API unreachable.", auth_expired: false}
    end
  end

  defp handle_ok_body(workspace_id, body) do
    case normalize(body) do
      {:ok, attrs} ->
        case upsert(workspace_id, attrs) do
          {:ok, row} ->
            %{codex: serialize(row), message: nil, auth_expired: false}

          {:error, _} ->
            %{codex: nil, message: "Codex quota could not be stored", auth_expired: false}
        end

      :noop ->
        %{
          codex: nil,
          message: "Codex connected. Usage API returned no rate-limit windows.",
          auth_expired: false
        }
    end
  end

  # ---- persistence -------------------------------------------------------

  defp upsert(workspace_id, attrs) do
    with {:ok, account_id} <- Arbiter.Quota.ensure_account_id(workspace_id, @default_provider) do
      # A capture overwrites the row wholesale: a window the response no longer
      # carries (a downgrade to free drops `weekly`, or the API stops reporting
      # a length) must clear, not linger from the previous plan and pace the
      # new one against the old plan's window.
      full =
        @window_columns
        |> Map.new(&{&1, nil})
        |> Map.merge(attrs)
        |> Map.put(:provider_account_id, account_id)
        |> Map.put(:provider, @default_provider)
        |> Map.put_new(:captured_at, DateTime.utc_now() |> DateTime.truncate(:second))

      result =
        CodexQuota
        |> Ash.Changeset.for_create(:upsert, full)
        |> Ash.create()

      with {:ok, row} <- result do
        record_history(row)
        Arbiter.Quota.History.record(account_id, row)
        broadcast(account_id, row)
      end

      result
    end
  end

  # Append the capture to the history table and drop rows past retention. Best
  # effort: a history failure must never lose the live snapshot.
  defp record_history(%CodexQuota{} = row) do
    attrs =
      row
      |> Map.take([:provider_account_id, :plan, :limit_reached, :captured_at] ++ @window_columns)

    CodexQuotaSnapshot |> Ash.Changeset.for_create(:record, attrs) |> Ash.create!()

    cutoff = DateTime.add(DateTime.utc_now(), -@history_retention_days * 86_400, :second)

    CodexQuotaSnapshot
    |> Ash.Query.filter(provider_account_id == ^row.provider_account_id and captured_at < ^cutoff)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: :stream, return_errors?: true)
  rescue
    e -> Logger.warning("Arbiter.Quota.Codex: history write failed: #{Exception.message(e)}")
  end

  @doc """
  Persisted capture history for `provider_account_id`, oldest first (bd-afvsnc):
  `captured_at`, `plan`, used percents, reset times and reported window lengths
  of every capture still within retention. Use it to read the real burn rate
  or to infer a plan's window length from the `reset_at` jump across a reset.
  """
  @spec history(String.t() | nil, keyword()) :: [CodexQuotaSnapshot.t()]
  def history(account_id, opts \\ [])

  def history(account_id, opts) when is_binary(account_id) do
    CodexQuotaSnapshot
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.Query.sort(captured_at: :asc, inserted_at: :asc)
    |> then(fn q ->
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n > 0 -> Ash.Query.limit(q, n)
        _ -> q
      end
    end)
    |> Ash.read!()
  end

  def history(_account_id, _opts), do: []

  # Broadcast the uniform `{:quota_updated, ws, view}` (not the raw resource
  # struct) so the LiveView `:quota` hook — which only handles that message —
  # picks up Codex live, exactly like the Anthropic and Google paths (bd-ajh7bd).
  # One account-keyed write fans out to every workspace on that account (P5).
  defp broadcast(account_id, %CodexQuota{} = row) do
    Arbiter.Quota.Broadcast.quota_updated(account_id, view(row))
  end

  @doc "Latest stored Codex snapshot for `provider_account_id`, or `nil`."
  @spec latest(String.t() | nil, String.t()) :: CodexQuota.t() | nil
  def latest(account_id, provider \\ @default_provider)

  def latest(account_id, provider) when is_binary(account_id) do
    CodexQuota
    |> Ash.Query.filter(provider_account_id == ^account_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %CodexQuota{} = row} -> row
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A workspace with no Codex account yet reads as "nothing captured".
  def latest(_account_id, _provider), do: nil

  # ---- normalize ---------------------------------------------------------

  @doc """
  Translate a decoded usage-endpoint body into `CodexQuota` upsert attrs.

  Returns `{:ok, attrs}` when at least one window (session/weekly) was found,
  or `:noop` when the body carries no rate-limit data. Mirrors the defensive
  multi-key parsing 9router's `getCodexUsage` / `formatCodexWindow` apply.
  """
  @spec normalize(map()) :: {:ok, map()} | :noop
  def normalize(body) when is_map(body) do
    rate_limit = rate_limit_body(body)
    session = window(rate_limit, ["primary_window", "primary"], body)
    weekly = window(rate_limit, ["secondary_window", "secondary"], body)

    if is_nil(session) and is_nil(weekly) do
      :noop
    else
      attrs =
        %{
          plan: plan(body),
          limit_reached: truthy(get_any(rate_limit, ["limit_reached"]))
        }
        |> put_window(:session_used_percent, :session_reset_at, session)
        |> put_window(:weekly_used_percent, :weekly_reset_at, weekly)
        |> put_minutes(:session_window_minutes, session)
        |> put_minutes(:weekly_window_minutes, weekly)

      {:ok, attrs}
    end
  end

  def normalize(_), do: :noop

  # The rate-limit object may live under a few keys; fall back to the body
  # itself so a flat `{primary_window, secondary_window}` shape still parses.
  defp rate_limit_body(body) do
    get_any(body, ["rate_limit", "rate_limits"]) ||
      get_in(body, ["rate_limits_by_limit_id", "codex"]) ||
      body
  end

  # Look up a window under any of `keys` in the rate-limit object, else in the
  # top-level body (9router checks both).
  defp window(rate_limit, keys, body) do
    win = get_any(rate_limit, keys) || get_any(body, keys)
    if is_map(win), do: win, else: nil
  end

  defp put_window(attrs, _used_key, _reset_key, nil), do: attrs

  defp put_window(attrs, used_key, reset_key, win) do
    attrs
    |> Map.put(used_key, used_percent(win))
    |> Map.put(reset_key, reset_at(win))
  end

  # The window's length, stored as whole minutes. `wham/usage` reports
  # `limit_window_seconds`; `window_minutes` is accepted as an alias. Omitted
  # when absent or non-positive so the upsert leaves the column as it was.
  defp put_minutes(attrs, _key, nil), do: attrs

  defp put_minutes(attrs, key, win) do
    seconds = get_any(win, ["limit_window_seconds", "window_seconds"])
    minutes = get_any(win, ["window_minutes", "limit_window_minutes"])

    cond do
      is_number(seconds) and seconds > 0 -> Map.put(attrs, key, round(seconds / 60))
      is_number(minutes) and minutes > 0 -> Map.put(attrs, key, round(minutes))
      true -> attrs
    end
  end

  defp used_percent(win) do
    raw = get_any(win, ["used_percent", "percent_used"])
    raw |> to_finite_number(0.0) |> clamp(0.0, 100.0)
  end

  defp reset_at(win) do
    win
    |> get_any(["reset_at", "resets_at", "resetAt"])
    |> parse_reset_time()
  end

  defp plan(body) do
    case get_any(body, ["plan_type"]) || get_in(body, ["summary", "plan"]) do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  # ---- serialize ---------------------------------------------------------

  @doc """
  Render a stored `CodexQuota` row into the public map shape returned by
  `arb quota` and `GET /api/quota`. This is a pure transformation of persisted
  data, with each window as `{used, total: 100, remaining, reset_at,
  unlimited: false}` and no live fetch.
  """
  @spec serialize(CodexQuota.t()) :: map()
  def serialize(%CodexQuota{} = row) do
    %{
      plan: row.plan,
      limit_reached: row.limit_reached,
      session: serialize_window(row.session_used_percent, row.session_reset_at),
      weekly: serialize_window(row.weekly_used_percent, row.weekly_reset_at),
      captured_at: iso(row.captured_at)
    }
  end

  @doc """
  Serialize the latest stored snapshot for `provider_account_id`, or `nil`.

  The map also carries the pacing state (`pacing/3`, bd-afvsnc) judged under
  the account's own gate policy: `elapsed_fraction`, `used_fraction`,
  `gating_reason` (`nil` unless dispatch is held) and a `pacing` detail map.
  """
  @spec serialize_latest(String.t()) :: map() | nil
  def serialize_latest(account_id) do
    case latest(account_id) do
      nil ->
        nil

      %CodexQuota{} = row ->
        pacing = pacing(row, Resolver.get(account_id))

        row
        |> serialize()
        |> Map.merge(%{
          elapsed_fraction: pacing.elapsed_fraction,
          used_fraction: pacing.used_fraction,
          gating_reason: pacing.gating_reason,
          pacing: pacing
        })
    end
  end

  @doc """
  The pacing state of a stored `CodexQuota` row (bd-afvsnc), as `quota_get`
  reports it. The session window's `elapsed_fraction` / `used_fraction` lead;
  a paid plan's weekly window is judged independently under `weekly` (`nil`
  when the plan has none, e.g. free).

    * `enabled` — the window's length is known (reported by the API, else the
      plan table, `Arbiter.Quota.CodexPlanWindows`) and `reset_at` is present.
      `false` carries a `disabled_reason`; the gate then falls back to its flat
      ceiling rather than guessing a length.
    * `window_source` — `:reported`, `:plan_table` or `nil`.
    * `paced_mode` — whether the account opted into `threshold_mode: "paced"`;
      the fractions are reported either way, but only a paced account holds
      on them.
    * `gating_reason` — the gate's hold phrase for either window, `nil` when
      dispatch is not held.

  Options: `:now` (default `DateTime.utc_now/0`).
  """
  @spec pacing(CodexQuota.t(), term(), keyword()) :: map()
  def pacing(%CodexQuota{} = row, account, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    snap = Snapshot.normalize(row)

    session =
      window_pacing(
        row.plan,
        :session,
        row.session_window_minutes,
        row.session_used_percent,
        row.session_reset_at,
        snap.window_label,
        account,
        now
      )

    weekly =
      if is_nil(row.weekly_used_percent) or is_nil(row.weekly_reset_at) do
        nil
      else
        window_pacing(
          row.plan,
          :weekly,
          row.weekly_window_minutes,
          row.weekly_used_percent,
          row.weekly_reset_at,
          snap.secondary_window_label,
          account,
          now
        )
      end

    Map.merge(session, %{
      plan: row.plan,
      paced_mode: Gate.account_policy_summary(account) |> paced_mode?(),
      weekly: weekly,
      gating_reason: Gate.hold_phrase(row, {account, nil}, now: now)
    })
  end

  defp paced_mode?(%{threshold_mode: "paced"}), do: true
  defp paced_mode?(_), do: false

  defp window_pacing(plan, window, reported_minutes, used_percent, reset_at, label, account, now) do
    seconds = Gate.window_seconds(label, account)
    elapsed = Pace.elapsed_seconds(reset_at, seconds, now) |> Pace.elapsed_fraction(seconds)

    source =
      cond do
        is_nil(seconds) -> nil
        is_integer(reported_minutes) -> :reported
        CodexPlanWindows.minutes(plan, window) -> :plan_table
        true -> :account_config
      end

    %{
      enabled: not is_nil(elapsed),
      disabled_reason: disabled_reason(elapsed, plan, window, reset_at),
      window_source: source,
      window_seconds: seconds,
      elapsed_fraction: elapsed,
      used_fraction: if(is_number(used_percent), do: used_percent / 100.0)
    }
  end

  defp disabled_reason(elapsed, _plan, _window, _reset_at) when is_float(elapsed), do: nil
  defp disabled_reason(_elapsed, _plan, _window, nil), do: "no reset_at reported; pacing off"

  defp disabled_reason(_elapsed, plan, window, _reset_at),
    do:
      "window length unknown for plan #{inspect(plan)} (#{window}); pacing off, flat ceiling applies"

  @doc """
  Map a stored `CodexQuota` row to the uniform two-window quota view shape the
  topbar / `/usage` page render (bd-ajh7bd). Codex's session window fills the
  primary ("5h") slot. If the row includes weekly data (non-nil `weekly_used_percent`
  and `weekly_reset_at`), the weekly window is shown in the secondary ("7d") slot;
  otherwise the view is single-window with only the session data. The used
  percents (0-100) are rescaled to the 0-1 fraction the view uses.
  """
  @spec view(CodexQuota.t()) :: map()
  def view(%CodexQuota{} = row) do
    weekly_pct = row.weekly_used_percent

    secondary_label =
      if not is_nil(weekly_pct) and not is_nil(row.weekly_reset_at),
        do: Snapshot.codex_window_label(row.weekly_window_minutes, "weekly"),
        else: nil

    Arbiter.Quota.blank_view(row.provider)
    |> Map.merge(%{
      provider_account_id: row.provider_account_id,
      utilization_5h: fraction(row.session_used_percent),
      reset_5h_at: row.session_reset_at,
      utilization_7d: if(secondary_label, do: fraction(weekly_pct), else: nil),
      reset_7d_at: if(secondary_label, do: row.weekly_reset_at, else: nil),
      captured_at: row.captured_at,
      plan: row.plan,
      primary_label: Snapshot.codex_window_label(row.session_window_minutes, "session"),
      secondary_label: secondary_label
    })
  end

  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0

  defp serialize_window(nil, nil), do: nil

  defp serialize_window(used, reset_at) do
    used = to_finite_number(used, 0.0)

    %{
      used: used,
      total: 100,
      remaining: clamp(100.0 - used, 0.0, 100.0),
      reset_at: iso(reset_at),
      unlimited: false
    }
  end

  # ---- credentials -------------------------------------------------------

  @doc """
  Read `access_token` + `account_id` from a `codex` `auth.json`.

  Read-only. `{:ok, %{access_token, account_id}}` on success, `{:error, reason}`
  when the file is absent / unreadable / malformed / lacks an access token.
  """
  @spec read_credentials(keyword()) ::
          {:ok, %{access_token: String.t(), account_id: String.t() | nil}} | {:error, term()}
  def read_credentials(opts \\ []) do
    path = auth_path(opts)

    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw),
         %{"tokens" => %{"access_token" => token}} when is_binary(token) and token != "" <- json do
      {:ok, %{access_token: token, account_id: get_in(json, ["tokens", "account_id"])}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_access_token}
    end
  end

  @doc """
  Probe Codex authentication using the usage API endpoint (`wham/usage`).

  Performs a zero-quota check against the operator's Codex login credentials.
  Returns:
    * `{:ok, 200, body}` when authenticated successfully;
    * `{:ok, 401, body}` when credentials are expired or invalid;
    * `{:ok, status, body}` for other HTTP response statuses;
    * `{:error, reason}` on network errors, missing `auth.json`, or absence of an access token.
  """
  @spec probe_auth(keyword()) :: {:ok, pos_integer(), term()} | {:error, term()}
  def probe_auth(opts \\ []) do
    case resolve_credentials(opts) do
      {:ok, creds} -> request_usage(creds, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_credentials(opts) do
    case Keyword.get(opts, :credentials) do
      %{access_token: token} = creds when is_binary(token) and token != "" ->
        {:ok, creds}

      _ ->
        read_credentials(opts)
    end
  end

  defp auth_path(opts) do
    (Keyword.get(opts, :auth_path) || cfg(:auth_path, default_auth_path()))
    |> Path.expand()
  end

  # ---- HTTP --------------------------------------------------------------

  defp request_usage(creds, opts) do
    url = Keyword.get(opts, :usage_url) || cfg(:usage_url, @default_usage_url)

    headers =
      [
        {"authorization", "Bearer " <> creds.access_token},
        {"accept", "application/json"},
        {"originator", "codex_cli_rs"}
      ] ++ account_header(creds)

    req =
      Req.new(
        url: url,
        method: :get,
        headers: headers,
        receive_timeout: @request_timeout_ms
      )
      |> maybe_stub()

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp account_header(%{account_id: id}) when is_binary(id) and id != "",
    do: [{"chatgpt-account-id", id}]

  defp account_header(_), do: []

  defp maybe_stub(req) do
    if Application.get_env(:arbiter, :codex_quota_http_stub, false) do
      Req.merge(req, plug: {Req.Test, @stub_name})
    else
      req
    end
  end

  # ---- shared helpers ----------------------------------------------------

  defp get_any(nil, _keys), do: nil

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        val -> val
      end
    end)
  end

  defp get_any(_, _), do: nil

  # Mirror of 9router's `toFiniteNumber`: coerce numbers and numeric strings,
  # else the fallback.
  defp to_finite_number(n, _fallback) when is_number(n), do: n * 1.0

  defp to_finite_number(s, fallback) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> fallback
    end
  end

  defp to_finite_number(_, fallback), do: fallback

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp truthy(true), do: true
  defp truthy(_), do: false

  # Mirror of 9router's `parseResetTime`: unix seconds/millis (number or numeric
  # string) or an ISO-8601 string → a second-truncated `DateTime`.
  defp parse_reset_time(nil), do: nil

  defp parse_reset_time(n) when is_integer(n), do: from_epoch(n)

  defp parse_reset_time(n) when is_float(n), do: from_epoch(trunc(n))

  defp parse_reset_time(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {secs, ""} ->
        from_epoch(secs)

      _ ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _} -> DateTime.truncate(dt, :second)
          _ -> nil
        end
    end
  end

  defp parse_reset_time(_), do: nil

  # < 1e12 → seconds, else milliseconds (9router's heuristic).
  defp from_epoch(n) when n < 1_000_000_000_000 do
    case DateTime.from_unix(n) do
      {:ok, dt} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp from_epoch(n) do
    case DateTime.from_unix(n, :millisecond) do
      {:ok, dt} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp cfg(key, default) do
    case Application.get_env(:arbiter, :codex_quota, []) do
      kw when is_list(kw) -> Keyword.get(kw, key, default)
      _ -> default
    end
  end
end
