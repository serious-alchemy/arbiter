defmodule Arbiter.Quota.CloudCode do
  @moduledoc """
  On-demand quota snapshots for **Antigravity** (agy), the Google Cloud Code
  Assist family's one supported surface (bd-57ukgb, part of bd-5qe3qs).

  The upstream Gemini CLI provider (`gemini_cli`) and its quota probe — a
  stored-token `loadCodeAssist` / `retrieveUserQuota` call, the source of the
  recurring "Gemini CLI project id not available; reconnect the CLI …" line
  in `arb quota` — were dropped in bd-ac53wz in favour of agy.

  Unlike the Anthropic quota — which is updated via explicit polling of
  `Arbiter.Quota.OAuthUsage` and header capture from worker responses
  (`Arbiter.Quota.AnthropicQuota`) — Antigravity emits no usage on ordinary
  traffic, so we query it directly.

  ## Credentials: none held (bd-d7hmqn)

  Antigravity used to read a stored token (the IDE's `state.vscdb` sqlite DB,
  falling back to the Gemini CLI creds file) and call the Cloud Code API with
  it, with `agy models` as a pure liveness check. In practice that stack of
  fallbacks degraded to a message telling the *operator* to go refresh the
  token by hand — not useful when nothing was actually wrong with the
  account, just with Arbiter's own copy of its token.

  `agy` (Antigravity's own CLI, `~/.local/bin/agy`) can report the real
  quota directly — `agy --output-format json --print "/usage"` — using
  whatever credential it holds in its own keyring/ADC/WIF chain, without us
  ever reading or holding a token ourselves. So Antigravity shells out to
  that command instead: see `antigravity/1` below. There is nothing left in
  Arbiter's control to go stale.

  ## Flow — Antigravity (bd-d7hmqn)

  Shell out to `agy --output-format json --print "/usage"` (the `agy` CLI's
  own binary, resolved via `System.find_executable/1`) and parse
  `.command.data.groups[].buckets[]` — each bucket a `{window, remaining_fraction,
  reset_time}` triple, grouped by model family (`"Gemini Models"`, `"Claude and
  GPT models"` at last check; the CLI's JSON may add more). Each `{group,
  window}` pair is normalized into a `model_quota()` entry via
  `normalize_model/4`, so the existing `arb quota` / REST / MCP rendering
  (which walks `snapshot.models`) needs no special-casing for the
  multi-group, multi-window shape — it just sees more "model" rows, one per
  group/window combination. `remaining_fraction` is already a *remaining*
  fraction (unlike the Anthropic/Codex snapshots, which store *utilization*),
  so no inversion is applied — setting `remaining_percentage: fraction * 100`
  directly.

  `antigravity/1` **always returns a snapshot, never `nil`** — the whole point
  of this CLI-only design is that `agy` alone can tell us whether the account
  is live, so every outcome (not installed, not authenticated, timed out,
  unparseable JSON, or a real reading) surfaces as a snapshot with either
  `models` or a plain-English `message`, never a silent omission. Never
  raises. See `run_agy_usage/1` for the subprocess mechanics and the
  process-hygiene notes carried over from the old liveness probe (backgrounded
  language-server, output-capture deadlock, hard subprocess timeout). No
  token material is ever logged — only the parsed `remaining_fraction` /
  `window` / `reset_time` fields are kept, and JSON decode failures log
  nothing about the raw body.

  ## Persistence (bd-ajh7bd)

  `refresh/3` wraps a live fetch with an upsert into `Arbiter.Quota.GoogleQuota`
  and a `{:quota_updated, ws, view}` PubSub broadcast, so `Arbiter.Quota.CloudProbe`
  can keep the snapshot fresh on a timer and the web dashboard picks it up live —
  exactly like the Anthropic header-capture path. `latest/2` / `serialize_latest/2`
  read the persisted row back so the REST + MCP quota surface never fetches live
  at request time.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Quota.GoogleQuota
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.SpawnEnv

  # Normalized base — the provider only hands us a fraction, not raw units, so
  # we mirror 9router's arbitrary 1000-unit base for used/total. Percentage is
  # carried alongside for callers that prefer a plain 0–100 figure.
  @total 1000

  # Antigravity's `/usage` groups slug (see `agy_bucket_id/2`) to these
  # prefixes: "Gemini Models" -> "gemini_models", "Claude and GPT models" ->
  # "claude_and_gpt_models", each combined with a `_5h` / `_weekly` window
  # suffix into the model id persisted in `GoogleQuota.snapshot["models"]`.
  @antigravity_gemini_group "gemini_models"

  # `agy --output-format json --print "/usage"` — reports real per-window
  # remaining quota directly from whatever credential `agy` itself holds
  # (bd-d7hmqn), replacing the old stored-token HTTP call entirely.
  @agy_usage_args ["--output-format", "json", "--print", "/usage"]
  # Matches `Quota.await_snapshot/1`'s 20s wait on the on-demand path
  # (`quota.ex:~659`) — bd-au2xhz raised this from 8s after measuring p99
  # real `/usage` latency at 7.7s, which left ~8% of probe runs racing the
  # old deadline.
  @default_agy_usage_timeout_ms 20_000

  # Same rationale as the old liveness-probe cache this replaces: the `agy`
  # binary is large (~199 MB) and backgrounds its own language server, so
  # `CloudProbe`'s periodic fan-out across every workspace must not re-exec it
  # on every cycle. A short TTL keeps the data reasonably fresh while still
  # collapsing the near-simultaneous per-workspace calls within one probe
  # cycle into a single subprocess.
  @agy_usage_cache_key {__MODULE__, :agy_usage_cache}
  @agy_usage_cache_ttl_ms 60_000

  @type model_quota :: %{
          model_id: String.t(),
          used: non_neg_integer(),
          total: non_neg_integer(),
          remaining_percentage: float(),
          reset_at: String.t() | nil,
          unlimited: boolean()
        }

  @type snapshot :: %{
          provider: String.t(),
          plan: String.t(),
          models: [model_quota()],
          message: String.t() | nil,
          captured_at: String.t(),
          auth_expired: boolean()
        }

  # ---- Antigravity (bd-d7hmqn) -------------------------------------------

  @doc """
  Antigravity quota snapshot, sourced directly from
  `agy --output-format json --print "/usage"` — **never `nil`**, see the
  moduledoc's "Flow — Antigravity" section for why every outcome (not
  installed, not authenticated, timed out, malformed JSON, or a real reading)
  is a snapshot with either `models` or a `message`, never a silent omission.

  Options:

    * `:agy_cmd` — override the `agy` executable name/path (default `"agy"`, resolved via `System.find_executable/1`)
    * `:agy_usage_probe` — override the subprocess call with a 0-arity fun returning `{:ok, decoded_json} | {:error, reason}` (tests)
    * `:agy_probe_timeout` — max time to wait on the `agy` subprocess, ms (default 20000)
    * `:agy_usage_cache_ttl_ms` — override the memoization TTL (tests; default 60000)
  """
  @spec antigravity(keyword()) :: snapshot()
  def antigravity(opts \\ []) do
    case run_agy_usage(opts) do
      {:ok, body} ->
        case usage_models_from_agy(body) do
          [] -> snapshot("antigravity", "Unknown", [], agy_malformed_message())
          models -> snapshot("antigravity", "Unknown", models, nil)
        end

      {:error, :not_installed} ->
        snapshot("antigravity", "Unknown", [], agy_not_installed_message())

      {:error, :timeout} ->
        snapshot("antigravity", "Unknown", [], "Antigravity CLI (agy) did not respond in time.")

      {:error, {:exit, status}} ->
        snapshot(
          "antigravity",
          "Unknown",
          [],
          "Antigravity CLI (agy) is not authenticated (exit #{status}); run `agy` to sign in.",
          true
        )

      {:error, :malformed} ->
        snapshot("antigravity", "Unknown", [], agy_malformed_message())
    end
  rescue
    e ->
      Logger.debug("Arbiter.Quota.CloudCode.antigravity raised: #{Exception.message(e)}")
      snapshot("antigravity", "Unknown", [], "Antigravity quota unavailable")
  end

  defp agy_not_installed_message do
    "Antigravity CLI (agy) is not installed on this host (or not on PATH); install it and " <>
      "run it once to authenticate before checking quota."
  end

  defp agy_malformed_message do
    "Antigravity CLI (agy) returned unexpected data; its JSON output may have changed shape."
  end

  # `.command.data.groups[].buckets[]` — each bucket a `{window,
  # remaining_fraction, reset_time}` triple, grouped by model family (e.g.
  # "Gemini Models", "Claude and GPT models"). Flattened into one
  # `model_quota()` per {group, window} pair so the existing per-model
  # rendering needs no special-casing.
  defp usage_models_from_agy(%{"command" => %{"data" => %{"groups" => groups}}})
       when is_list(groups) do
    for group <- groups,
        is_map(group),
        is_binary(group["name"]),
        is_list(group["buckets"]),
        bucket <- group["buckets"],
        is_map(bucket),
        is_binary(bucket["window"]),
        not is_nil(bucket["remaining_fraction"]) do
      normalize_model(
        agy_bucket_id(group["name"], bucket["window"]),
        bucket["remaining_fraction"],
        bucket["reset_time"],
        "#{group["name"]} (#{bucket["window"]})"
      )
    end
  end

  defp usage_models_from_agy(_), do: []

  defp agy_bucket_id(group_name, window) do
    slug =
      group_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    slug <> "_" <> window
  end

  # ---- persistence (bd-ajh7bd) -------------------------------------------

  @doc """
  Fetch Antigravity's live quota and upsert it into `GoogleQuota`.

  `which` is `:antigravity` — the only Google provider left since bd-ac53wz
  dropped the upstream Gemini CLI (`:gemini`, which this no longer accepts).
  Returns the serialized snapshot map (persisting a row + broadcasting
  `{:quota_updated, ws, view}`), or `nil` if the refresh itself raised.

  The fetch never returns `nil` (bd-d7hmqn) — `agy` itself determines whether
  it's installed/authenticated, so every call writes a row. When that
  snapshot has no model data (agy missing / not authenticated / timed out /
  malformed output), the write preserves the previous row's `used_percent` /
  `reset_at` / `snapshot` figures rather than nulling them out, so a
  transient error updates the status `message` without wiping the last good
  quota reading. `opts` are forwarded to `antigravity/1`.
  """
  @spec refresh(String.t(), :antigravity, keyword()) :: snapshot() | nil
  def refresh(workspace_id, which, opts \\ [])
      when is_binary(workspace_id) and which == :antigravity do
    snapshot = antigravity(opts)
    provider = "antigravity"

    # P5 (§6): the row is keyed by the provider account this workspace
    # meters under, resolved here so the probe's call site is unchanged.
    with {:ok, account_id} <- Arbiter.Quota.ensure_account_id(workspace_id, provider),
         {:ok, row} <- upsert(account_id, provider, snapshot) do
      Arbiter.Quota.History.record(account_id, row)
      broadcast(account_id, row)
      snapshot
    else
      {:error, reason} ->
        Logger.debug("Arbiter.Quota.CloudCode: #{provider} upsert failed: #{inspect(reason)}")
        snapshot
    end
  rescue
    e ->
      Logger.debug("Arbiter.Quota.CloudCode.refresh raised: #{Exception.message(e)}")
      nil
  end

  defp upsert(account_id, provider, snapshot) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {used_percent, reset_at, stored_snapshot, captured_at} =
      case representative(snapshot) do
        {nil, nil} -> preserve_last_good(account_id, provider, snapshot, now)
        {used_percent, reset_at} -> {used_percent, reset_at, stringify(snapshot), now}
      end

    attrs = %{
      provider_account_id: account_id,
      provider: provider,
      plan: snapshot[:plan],
      message: snapshot[:message],
      used_percent: used_percent,
      reset_at: reset_at,
      snapshot: stored_snapshot,
      captured_at: captured_at
    }

    GoogleQuota
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create()
  end

  # A snapshot with no model data (a transient API error, or the "agy is live
  # but we hold no readable token" liveness-only status) must not clobber the
  # last good reading's figures — but its `message`/`plan` (the JSON
  # `snapshot` column's own copy) must still land in the stored `snapshot`
  # column, since that's what `serialize_latest/2` (and therefore `arb
  # quota`/the MCP quota tool) reads back verbatim. `captured_at` (both the
  # row **column** and its copy inside the `snapshot` JSON, bd-au2xhz) must
  # stay the *previous* row's value rather than stamping `now` over it —
  # otherwise a transient timeout makes stale figures look freshly captured,
  # and `arb quota --json`/`GET /api/quota` disagree with the row column
  # they're read alongside. The failed attempt's own timestamp is kept under
  # `checked_at` instead, for anyone who wants it. Falls back to writing the
  # empty snapshot as-is (with `now`) when there is no previous row to
  # preserve.
  defp preserve_last_good(account_id, provider, snapshot, now) do
    case latest(account_id, provider) do
      %GoogleQuota{used_percent: used_percent, reset_at: reset_at, snapshot: prior} = row
      when not is_nil(prior) ->
        merged =
          Map.merge(
            prior,
            stringify(%{
              message: snapshot[:message],
              plan: snapshot[:plan],
              checked_at: snapshot[:captured_at]
            })
          )

        {used_percent, reset_at, merged, row.captured_at}

      _ ->
        {nil, nil, stringify(snapshot), now}
    end
  end

  # The representative bar figure: the worst (most-used) important model, i.e.
  # the smallest `remaining_percentage`. `{used_percent :: float | nil,
  # reset_at :: DateTime | nil}` — nil/nil when the snapshot carries no models.
  defp representative(%{models: [_ | _] = models}) do
    worst = Enum.min_by(models, & &1.remaining_percentage)
    used = Float.round(100.0 - (worst.remaining_percentage || 0.0), 2)
    {clamp(used, 0.0, 100.0), parse_datetime(worst[:reset_at])}
  end

  defp representative(_), do: {nil, nil}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # JSON-normalize the snapshot to string keys so the read-back shape is stable
  # regardless of the `:map` data-layer's round-trip.
  defp stringify(term) do
    term |> Jason.encode!() |> Jason.decode!()
  end

  defp broadcast(account_id, %GoogleQuota{} = row) do
    Arbiter.Quota.Broadcast.quota_updated(account_id, view(row))
  rescue
    _ -> :error
  end

  @doc "Latest stored Google snapshot row for `provider_account_id` + `provider`, or `nil`."
  @spec latest(String.t(), String.t()) :: GoogleQuota.t() | nil
  def latest(account_id, provider) when is_binary(account_id) and is_binary(provider) do
    GoogleQuota
    |> Ash.Query.filter(provider_account_id == ^account_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %GoogleQuota{} = row} -> row
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A workspace with no Google account yet reads as "nothing captured".
  def latest(_account_id, _provider), do: nil

  @doc "Serialize the latest stored snapshot for `provider_account_id` + `provider`, or `nil`."
  @spec serialize_latest(String.t(), String.t()) :: map() | nil
  def serialize_latest(account_id, provider) do
    case latest(account_id, provider) do
      nil -> nil
      %GoogleQuota{snapshot: snapshot} -> snapshot
    end
  end

  @doc """
  Map a stored `GoogleQuota` row to the uniform two-window quota view shape the
  topbar / `/usage` page render. Antigravity has explicit `5h`/`weekly`
  windows, per group — this reads the `"gemini_models"` group's buckets
  (bd-7mro0t) via `antigravity_bucket/3` (the same reader
  `Gate.Snapshot.bucket_reading/3` uses for dispatch gating) into the
  primary/secondary slots, falling back to `representative/1`'s single
  collapsed figure when the stored snapshot carries no parseable buckets
  (stale schema, a `preserve_last_good/3` write, etc).
  """
  @spec view(GoogleQuota.t()) :: map()
  def view(%GoogleQuota{} = row) do
    models = models_from(row.snapshot)

    Arbiter.Quota.blank_view(row.provider)
    |> Map.merge(%{
      provider_account_id: row.provider_account_id,
      captured_at: row.captured_at,
      plan: row.plan,
      message: row.message,
      models: models
    })
    |> Map.merge(antigravity_view_windows(row, models))
  end

  defp antigravity_view_windows(%GoogleQuota{provider: "antigravity"} = row, models) do
    with %{} = primary <- antigravity_bucket(models, @antigravity_gemini_group, "5h"),
         %{} = secondary <- antigravity_bucket(models, @antigravity_gemini_group, "weekly") do
      %{
        utilization_5h: primary.utilization,
        reset_5h_at: primary.reset_at,
        utilization_7d: secondary.utilization,
        reset_7d_at: secondary.reset_at,
        primary_label: "5h",
        secondary_label: "weekly"
      }
    else
      _ -> collapsed_view_windows(row)
    end
  end

  defp antigravity_view_windows(%GoogleQuota{} = row, _models), do: collapsed_view_windows(row)

  defp collapsed_view_windows(%GoogleQuota{} = row) do
    %{
      utilization_5h: fraction(row.used_percent),
      reset_5h_at: row.reset_at,
      utilization_7d: nil,
      reset_7d_at: nil,
      primary_label: "used",
      secondary_label: nil
    }
  end

  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0

  defp models_from(%{"models" => models}) when is_list(models), do: models
  defp models_from(_), do: []

  # ---- shared Antigravity bucket reader (bd-7mro0t) -----------------------

  @doc """
  Resolve one `{group, window}` Antigravity bucket — e.g. `"gemini_models"`,
  `"5h"` — from a `models` list as stored in `GoogleQuota.snapshot["models"]`
  (matching `model_id == "\#{group}_\#{window}"`). Returns
  `%{utilization: float | nil, reset_at: DateTime.t() | nil}`, or `nil` when
  no bucket for that pair exists.

  The single implementation of Antigravity bucket-reading semantics — shared
  by `view/1` (UI display, this module) and `Gate.Snapshot.bucket_reading/3`
  (dispatch gating), which also falls back to `antigravity_bucket_reading/1`
  directly for its worst-of-both-groups fallback when no group is known.
  """
  @spec antigravity_bucket([map()], String.t(), String.t()) ::
          %{utilization: float() | nil, reset_at: DateTime.t() | nil} | nil
  def antigravity_bucket(models, group, window) when is_list(models) do
    models
    |> Enum.filter(&(Map.get(&1, "model_id") == "#{group}_#{window}"))
    |> antigravity_bucket_reading()
  end

  @doc """
  The worst (most-used) reading among a list of Antigravity bucket maps
  (string-keyed `"remaining_percentage"` / `"reset_at"`), or `nil` for an
  empty list.
  """
  @spec antigravity_bucket_reading([map()]) ::
          %{utilization: float() | nil, reset_at: DateTime.t() | nil} | nil
  def antigravity_bucket_reading([]), do: nil

  def antigravity_bucket_reading(buckets) when is_list(buckets) do
    worst = Enum.max_by(buckets, &antigravity_used_percent/1)

    %{
      utilization: fraction(antigravity_used_percent(worst)),
      reset_at: parse_datetime(worst["reset_at"])
    }
  end

  defp antigravity_used_percent(%{"remaining_percentage" => rp}) when is_number(rp),
    do: 100.0 - rp

  defp antigravity_used_percent(_), do: 100.0

  # ---- normalization -----------------------------------------------------

  defp normalize_model(model_id, fraction, reset, display_name) do
    frac = to_fraction(fraction)
    remaining = round(@total * frac)
    used = max(0, @total - remaining)

    base = %{
      model_id: model_id,
      used: used,
      total: @total,
      remaining_percentage: frac * 100,
      reset_at: parse_reset(reset),
      unlimited: false
    }

    if is_binary(display_name), do: Map.put(base, :display_name, display_name), else: base
  end

  defp snapshot(provider, plan, models, message, auth_expired \\ false) do
    %{
      provider: provider,
      plan: plan,
      models: models,
      message: message,
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      auth_expired: auth_expired
    }
  end

  defp to_fraction(f) when is_number(f), do: f * 1.0

  defp to_fraction(f) when is_binary(f) do
    case Float.parse(f) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  defp to_fraction(_), do: 0.0

  # Provider reset times arrive as unix seconds, unix millis, a numeric string,
  # or an ISO-8601 string. Normalize all to ISO-8601 (mirrors 9router's
  # parseResetTime); anything unparseable degrades to nil.
  defp parse_reset(nil), do: nil

  defp parse_reset(n) when is_integer(n) do
    ms = if n < 1_000_000_000_000, do: n * 1000, else: n

    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp parse_reset(v) when is_binary(v) do
    if Regex.match?(~r/^\d+$/, v) do
      parse_reset(String.to_integer(v))
    else
      case DateTime.from_iso8601(v) do
        {:ok, dt, _offset} -> DateTime.to_iso8601(dt)
        _ -> nil
      end
    end
  end

  defp parse_reset(_), do: nil

  # Run `agy --output-format json --print "/usage"` off-process — see
  # moduledoc's "Flow — Antigravity". `{:ok, decoded_json}` on a clean `0`
  # exit with parseable JSON, else `{:error, :not_installed | :timeout |
  # {:exit, status} | :malformed}`. Never raises. Injectable via
  # `opts[:agy_usage_probe]` (a 0-arity fun) so tests never shell out.
  defp run_agy_usage(opts) do
    case opts[:agy_usage_probe] do
      fun when is_function(fun, 0) -> fun.()
      _ -> agy_usage_default(opts)
    end
  end

  # Same memoization rationale as the liveness probe this replaces: `agy` is a
  # large binary that backgrounds its own language server, and `CloudProbe`
  # fans this call out across every workspace on each probe cycle. Cache the
  # outcome briefly so those near-simultaneous per-workspace calls collapse
  # into one subprocess, without holding stale quota figures too long.
  defp agy_usage_default(opts) do
    cmd = opts[:agy_cmd] || Application.get_env(:arbiter, :agy_cmd) || "agy"
    ttl = Keyword.get(opts, :agy_usage_cache_ttl_ms, @agy_usage_cache_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@agy_usage_cache_key, nil) do
      {^cmd, result, cached_at} when now - cached_at < ttl ->
        result

      _ ->
        result =
          case System.find_executable(cmd) do
            nil -> {:error, :not_installed}
            path -> shell_out_agy_usage(path, opts)
          end

        :persistent_term.put(@agy_usage_cache_key, {cmd, result, now})
        result
    end
  rescue
    _ -> {:error, :not_installed}
  end

  # Run the subprocess with a hard timeout — a hung/prompting CLI must never
  # block `arb quota`. `Task.shutdown/2` on timeout only stops Erlang
  # *waiting* on the OS process, so we wrap the invocation in the `timeout`
  # coreutil to get an actual OS-side kill independent of whether Erlang is
  # still watching (mirrors the old liveness probe's `run_agy_probe/2`).
  #
  # `agy` backgrounds its own language-server process, which inherits whatever
  # file descriptor its stdout points at. Capturing output via a plain
  # `System.cmd/3` pipe would make Erlang's port driver block waiting for that
  # pipe's write end to close — the backgrounded grandchild keeps it open
  # indefinitely, so the port never sees EOF even though `agy` itself exits
  # immediately. Redirecting stdout to a real file at the shell level (not a
  # pipe `System.cmd` itself reads) sidesteps this entirely, so we can capture
  # the JSON body without hitting the deadlock the liveness probe worked
  # around by discarding output altogether.
  defp shell_out_agy_usage(path, opts) do
    timeout = Keyword.get(opts, :agy_probe_timeout, @default_agy_usage_timeout_ms)
    timeout_s = max(1, ceil(timeout / 1000))
    tmp = agy_usage_tmp_path()
    started_at = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        try do
          ReleaseEnv.cmd(
            "/bin/sh",
            [
              "-c",
              ~s(exec timeout -k 1 #{timeout_s} "$0" #{Enum.join(@agy_usage_args, " ")} >"$1" 2>/dev/null </dev/null),
              path,
              tmp
            ],
            env: SpawnEnv.cmd_env([], "gemini")
          )
        rescue
          _ -> {"", 1}
        catch
          :exit, _ -> {"", 1}
        end
      end)

    outcome =
      try do
        case Task.yield(task, timeout + 3_000) do
          {:ok, {_out, 0}} ->
            read_agy_usage_output(tmp)

          # `timeout -k 1` kills with SIGTERM at the deadline and SIGKILL a
          # second later; either way the shell reports 124/137 for a
          # subprocess that overran, not an auth failure. Most of these
          # (bd-au2xhz measured 53/117) are `agy` finishing `/usage` and then
          # lingering — the temp file already holds a real, parseable
          # reading, so read it before treating this as a timeout.
          {:ok, {_out, status}} when status in [124, 137] ->
            agy_killed_outcome(tmp, started_at)

          {:ok, {_out, status}} ->
            {:error, {:exit, status}}

          {:exit, _reason} ->
            {:error, :malformed}

          nil ->
            Task.shutdown(task, :brutal_kill)
            log_agy_timeout(started_at)
        end
      after
        File.rm_rf(agy_usage_tmp_dir(tmp))
      end

    outcome
  end

  defp agy_killed_outcome(tmp, started_at) do
    case read_agy_usage_output(tmp) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, :malformed} -> log_agy_timeout(started_at)
    end
  end

  defp log_agy_timeout(started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    Logger.warning("Arbiter.Quota.CloudCode: agy usage probe timed out after #{elapsed_ms}ms")
    {:error, :timeout}
  end

  # A private, unpredictably-named directory (not just a file) so the shell's
  # `>"$1"` redirect can't be steered onto an attacker-planted symlink in the
  # world-writable /tmp, and so `agy`'s raw JSON (whatever it may contain)
  # isn't world-readable for the subprocess's lifetime the way a bare 0644
  # temp file would be.
  defp agy_usage_tmp_path do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arbiter-agy-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    Path.join(dir, "usage.json")
  end

  defp agy_usage_tmp_dir(tmp), do: Path.dirname(tmp)

  # No token material ever passes through here — only the decoded JSON body,
  # which callers parse down to `remaining_fraction` / `window` / `reset_time`.
  defp read_agy_usage_output(tmp) do
    with {:ok, raw} <- File.read(tmp),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok, decoded}
    else
      _ -> {:error, :malformed}
    end
  end
end
