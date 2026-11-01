defmodule Arbiter.Loop.Scarcity do
  @moduledoc """
  The loop's **unit of scarcity** (#1463, epic #1011 Amendment E).

  Stage 1 originally denominated everything it optimises in imputed dollars:
  the corpus joined `usage_events` for a per-run `cost_usd`, proposals carried
  cost-shaped `target_metric`/`baseline`, and cell comparisons ranked tasks by
  spend. Amendment E observed that on a Claude subscription

  > the marginal dollar cost of the next Claude token is zero… what is
  > genuinely finite is the 5-hour and 7-day utilization windows

  so the loop was optimising a unit that does not bind. This module is the
  decision, in code. The full reasoning — including the units considered and
  rejected — is in `docs/loop-scarcity-unit.md`.

  ## The unit: `window_share`

  **A run's draw on the provider's primary utilization window, as a fraction of
  that window's capacity.** The unit is `window_share`; *which* window it is
  denominated in travels beside it as `calibration.window` (`:five_hour` or
  `:seven_day`) and is named in every line of report text. It was
  `window_share_5h` until the 5h window stopped existing for Claude
  (bd-50qt34, C11); `normalize_unit/1` still reads the old atom.

    * **The provider's primary window, not a fixed one.** `primary_window/1`
      asks `Arbiter.Quota.Gate.Snapshot` which window the provider actually
      gates on. A snapshot with a primary (5h) window calibrates on 5h; Claude
      with no primary window (`window_label: nil`, bd-9v8psv) calibrates on 7d,
      the window that binds. A metric denominated in a window that does not gate
      would describe a constraint that never binds. The other window rides along
      as context (`utilization_7d` on the calibration) but is not the objective.
    * **Per-run share, not observed utilization.** `anthropic_quotas` is a
      *latest-only cache* — one upserted row per `{workspace_id, provider}`,
      explicitly "a cache of the latest reading, not a time series". There is
      no historical utilization to join a 7-day corpus against, so utilization
      cannot be read per run retrospectively. What *is* per-run is the token
      ledger: `usage_events` carries `tokens_in` / `tokens_out` /
      `cache_creation_tokens` / `cache_read_tokens` with an `occurred_at`,
      keyed by `worker_run_id`. Window utilization is monotone in weighted
      token consumption, so a run's *share* of a window is attributable even
      though the window's history is not.

  ## Weighting, and why an approximate vector is sound

  Anthropic does not publish the token weighting behind the unified windows, so
  `weights/0` uses the published *pricing* ratios as the proxy (input 1.0,
  cache-write 1.25, cache-read 0.1, output 5.0 — Sonnet's $3 / $3.75 / $0.30 /
  $15 per Mtok).

  This is safe against the obvious objection because capacity is **calibrated
  from the same weighting**: `calibrate/2` divides the observed weighted draw of
  the current window by the observed utilization of that window, so any global scale error
  in the vector appears in numerator and denominator alike and cancels. Only the
  *relative* weights matter, and the relative cost of a cached read versus an
  output token is the one thing pricing does tell us. (There is a test pinning
  exactly this cancellation.)

  ## Fail-soft, never fabricated

  Every function degrades to `nil` rather than to a plausible-looking zero. An
  install with no captured snapshot, a *stale* snapshot, an idle calibration
  window, or a `0.0` utilization reading yields `status: :uncalibrated` with a
  machine-readable `reason`, and `window_share/2` returns `nil`.
  `Arbiter.Loop.Report` renders that absence out loud — a blind window must not
  read as a cheap one, which is the same discipline `Arbiter.Loop.Corpus`
  applies to `transcript_reads`.

  Staleness is the sharpest of those cases, because it is the one that fails
  *plausibly* rather than visibly. `anthropic_quotas` is a latest-only cache, so
  `Arbiter.Quota.latest/2` happily returns a reading from a window that rolled
  yesterday. Its `reset_5h_at` then places the window start a day in the past
  while `utilization_5h` describes a window that has since reset several times
  over, so a draw summed up to `now` would be divided by a utilization figure
  measured over a different — and much shorter — interval, inflating capacity by
  roughly the number of elapsed windows and deflating every share by the same
  factor. `calibrate/3` therefore takes an explicit `:stale` snapshot and
  refuses to calibrate from it (`reason: :stale_snapshot`), reusing
  `Arbiter.Quota.Gate.stale?/1` — the predicate the dispatch gate already fails
  open on for the 5h window — as the single definition of "too old to trust".
  When the calibration window is the 7d, the caller uses the gate's long-window
  predicate, `Arbiter.Quota.Gate.long_window_stale?/1`, instead: it is the one
  that ages the window the utilization figure actually describes.

  ## Coverage: capacity is a lower bound, shares are upper bounds

  Calibration divides *Arbiter's observed weighted draw* by the *account's*
  reported utilization. Those two have different coverage, and the asymmetry is
  one-directional:

    * `usage_events` only records what Arbiter itself dispatched. An interactive
      Claude Code session on the same plan raises `utilization_5h` without
      writing a row — on this installation that is the common case, not an edge
      case.
    * Both sides are read **fleet-wide**: `Arbiter.Loop.Corpus` deliberately does
      not filter its per-run numerator by workspace (some `usage_events` rows
      legitimately carry a `nil` `workspace_id`), so the calibration's observed
      draw must not filter either, or numerator and denominator would describe
      different populations and inflate every share by the ratio between them.

  What remains after scoping both sides identically is non-Arbiter traffic, which
  under-counts `observed`, hence under-estimates `capacity = observed /
  utilization`, hence **over-estimates** every share. So `window_share` is an
  upper bound on a run's true draw, and a share above 100% of a window is a known
  over-estimate rather than a measurement. This is reported out loud on the
  report's calibration line. It does not undermine the *comparisons* the loop
  makes — the bias is a single scale factor shared by every run in the window, so
  the ranking within a `(difficulty, repo)` cell is unaffected — but it does mean
  an absolute share should be read as "at most this much of a window".

  ## Billing mode

  Dollars are still the right unit under metered API billing, so the loop does
  not delete them — it *ranks* them. `billing_mode/2` decides which unit leads,
  and is readable at analysis time rather than assumed:

    1. `loop.billing_mode` in workspace config (`"subscription"` / `"metered"`)
       → `{mode, :configured}`.
    2. Otherwise, a captured `AnthropicQuota` snapshot carrying a unified 5h
       utilization figure is direct evidence of a plan with windows →
       `{:subscription, :inferred}`.
    3. Otherwise `{:metered, :default}` — no window evidence, so dollars remain
       the only unit that is readable at all.

  `primary_metric/1` turns that into the objective the report and proposals
  denominate in; the other metric is retained and reported as secondary.
  """

  alias Arbiter.Loop.Scarcity.Draw
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Overage

  @seven_days_seconds 7 * 24 * 60 * 60

  # Pricing-derived relative weights; see moduledoc for why only ratios matter.
  @weights %{input: 1.0, cache_write: 1.25, cache_read: 0.1, output: 5.0}

  @type window :: :five_hour | :seven_day
  @type unit :: :window_share | :cost_usd

  @type calibration :: %{
          window: window(),
          status: :calibrated | :uncalibrated,
          reason: nil | :no_snapshot | :stale_snapshot | :no_utilization | :no_observed_tokens,
          utilization: float() | nil,
          utilization_7d: float() | nil,
          observed_weighted_tokens: float(),
          capacity_weighted_tokens: float() | nil,
          captured_at: DateTime.t() | nil,
          since: DateTime.t() | nil
        }

  @type billing_mode :: {:subscription | :metered, :configured | :inferred | :default}

  @doc "The relative token-class weights. Ratios are load-bearing; scale is not."
  @spec weights() :: %{input: float(), cache_write: float(), cache_read: float(), output: float()}
  def weights, do: @weights

  @doc """
  Weighted token draw for a map of raw counts. Accepts atom or string keys and
  treats missing/`nil` counts as zero, so it can be fed a `usage_events` row,
  a corpus row, or a SQL result map interchangeably.
  """
  @spec weighted_tokens(map()) :: float()
  def weighted_tokens(counts) when is_map(counts) do
    num(counts, :tokens_in) * @weights.input +
      num(counts, :tokens_out) * @weights.output +
      num(counts, :cache_creation_tokens) * @weights.cache_write +
      num(counts, :cache_read_tokens) * @weights.cache_read
  end

  def weighted_tokens(_), do: 0.0

  @doc """
  Calibrate one window's capacity from the weighted draw observed over that
  window and the utilization the provider reported for it.

  `snapshot` is any map carrying `:utilization_5h` / `:utilization_7d` (an
  `AnthropicQuota` row, an `Arbiter.Quota.view/1` map, or `nil`). `opts` may
  carry:

    * `:window` — `:five_hour` (default) or `:seven_day`: which window the
      draw/utilization pair describes, and therefore which utilization field is
      the divisor. Callers pick it with `primary_window/1`.
    * `:since` — the start of the calibration window, purely so the report can
      cite it.
    * `:stale` — the snapshot the caller *rejected* as too old to calibrate from
      (see `Arbiter.Quota.Gate.stale?/1`). Pass it here rather than as
      `snapshot`: the reading is still worth citing (its `captured_at` says how
      blind the window is, and its existence is still evidence of a windowed
      plan for `billing_mode/2`), but its `utilization` describes a window that
      has already rolled, so capacity must not be derived from it.

  Returns a `t:calibration/0`. `status: :uncalibrated` (with a `reason`) is a
  normal outcome, not an error: it means the window's capacity is unknown and
  every share derived from it must be `nil`.
  """
  @spec calibrate(number(), map() | nil, keyword()) :: calibration()
  def calibrate(observed_weighted_tokens, snapshot, opts \\ []) do
    observed = observed_weighted_tokens / 1
    stale = Keyword.get(opts, :stale)
    window = Keyword.get(opts, :window, :five_hour)
    base = blank_calibration(observed, snapshot, stale, Keyword.get(opts, :since), window)
    util = base.utilization

    cond do
      not is_nil(stale) -> %{base | reason: :stale_snapshot}
      is_nil(snapshot) -> %{base | reason: :no_snapshot}
      not is_number(util) or util <= 0.0 -> %{base | reason: :no_utilization}
      observed <= 0.0 -> %{base | reason: :no_observed_tokens}
      true -> %{base | status: :calibrated, capacity_weighted_tokens: observed / util}
    end
  end

  # The uncalibrated frame every outcome starts from. A rejected `stale` reading
  # still supplies `captured_at` — the report needs to say *how* blind the window
  # is — but never `utilization`, which is the field that would imply a capacity.
  defp blank_calibration(observed, snapshot, stale, since, window) do
    cited = snapshot || stale

    %{
      window: window,
      status: :uncalibrated,
      reason: nil,
      utilization: snapshot && fetch(snapshot, utilization_key(window)),
      utilization_7d: snapshot && fetch(snapshot, :utilization_7d),
      observed_weighted_tokens: observed,
      capacity_weighted_tokens: nil,
      captured_at: cited && fetch(cited, :captured_at),
      since: since
    }
  end

  defp utilization_key(:seven_day), do: :utilization_7d
  defp utilization_key(_five_hour), do: :utilization_5h

  @doc """
  The window the loop denominates its unit in: the provider's **primary** one.

  A snapshot that carries a primary window (Anthropic's 5h, `window_label`
  non-nil on `Arbiter.Quota.Gate.Snapshot`) calibrates on it. Claude with no
  primary window — Anthropic retired the 5h (bd-9v8psv) — calibrates on the 7d,
  as does the absence of any snapshot (7d is the window that remains, and the
  uncalibrated frame should name it).
  """
  @spec primary_window(map() | nil) :: window()
  def primary_window(snapshot) do
    case Snapshot.normalize(snapshot) do
      %Snapshot{window_label: label} when not is_nil(label) -> :five_hour
      _ -> :seven_day
    end
  end

  @doc """
  The start of the window `snapshot` describes, as of `now`.

  The 5h window delegates to `Arbiter.Quota.Overage.window_start/2`. The 7d
  window is the same shape: seven days before its (future) reset, else the
  trailing seven days when the reset is absent or already elapsed.
  """
  @spec window_start(map() | nil, window(), DateTime.t()) :: DateTime.t()
  def window_start(snapshot, window, now \\ DateTime.utc_now())

  def window_start(snapshot, :seven_day, now) do
    case seven_day_reset(snapshot) do
      %DateTime{} = reset ->
        if DateTime.after?(reset, now),
          do: DateTime.add(reset, -@seven_days_seconds, :second),
          else: DateTime.add(now, -@seven_days_seconds, :second)

      _ ->
        DateTime.add(now, -@seven_days_seconds, :second)
    end
  end

  def window_start(snapshot, _five_hour, now), do: Overage.window_start(snapshot, now)

  defp seven_day_reset(%Snapshot{secondary_reset_at: reset}), do: reset
  defp seven_day_reset(%{} = snapshot), do: fetch(snapshot, :reset_7d_at)
  defp seven_day_reset(_), do: nil

  @doc "The short label a window goes by in report text."
  @spec window_label(window()) :: String.t()
  def window_label(:seven_day), do: "7d"
  def window_label(_five_hour), do: "5h"

  @doc """
  Read a persisted unit atom (or its string form) back into the current
  vocabulary. `:window_share_5h` — the name before the rename (bd-c2v31s) — is
  an alias for `:window_share`; unrecognised values are `nil`, never guessed
  into an atom.
  """
  @spec normalize_unit(term()) :: unit() | nil
  def normalize_unit(:window_share_5h), do: :window_share
  def normalize_unit(:window_share), do: :window_share
  def normalize_unit(:cost_usd), do: :cost_usd

  def normalize_unit("window_share_5h"), do: :window_share
  def normalize_unit("window_share"), do: :window_share
  def normalize_unit("cost_usd"), do: :cost_usd
  def normalize_unit(_), do: nil

  @doc """
  A run's share of the calibrated window: its weighted draw over the calibrated
  capacity. `nil` when the window is uncalibrated — never a fabricated `0.0`.
  """
  @spec window_share(number() | nil, calibration() | nil) :: float() | nil
  def window_share(weighted, %{status: :calibrated, capacity_weighted_tokens: cap})
      when is_number(weighted) and is_number(cap) and cap > 0.0,
      do: weighted / cap

  def window_share(_weighted, _calibration), do: nil

  @doc """
  A run's share of one window of any pool, from the draw calibration
  (`Arbiter.Loop.Scarcity.Draw`, bd-3is1nz R3): `weighted` tokens times the
  calibrated share per weighted token for `model` on (`pool`, `window`).

  `results` is `Draw.calibrate/1`'s output. `nil` — never a fabricated `0.0` —
  when the weighted draw is unknown or the history doesn't support a
  coefficient for that model. This is shadow output: nothing routes on it.
  """
  @spec draw_share(number() | nil, [map()], String.t(), String.t(), String.t()) ::
          float() | nil
  def draw_share(weighted, results, pool, window, model) when is_number(weighted) do
    case Draw.lookup(results, pool, window, model) do
      nil -> nil
      share_per_token -> weighted * share_per_token
    end
  end

  def draw_share(_weighted, _results, _pool, _window, _model), do: nil

  @doc """
  Render a share for an operator, or say plainly that it is unavailable. Names
  the window the share is of (`window` defaults to `:five_hour`; pass the
  calibration's `window` so the text never claims a window it did not use).
  """
  @spec format_share(float() | nil, window()) :: String.t()
  def format_share(share, window \\ :five_hour)

  def format_share(share, window) when is_number(share) do
    "#{:erlang.float_to_binary(share * 100, decimals: 1)}% of one #{window_label(window)} window"
  end

  def format_share(_, window), do: "unavailable (#{window_label(window)} window uncalibrated)"

  @doc """
  Which unit binds at this installation, and how we know. See the moduledoc for
  the three-step resolution order.

  `config` is a workspace `config` map (string-keyed, as persisted); `snapshot`
  is a quota snapshot map or `nil`.
  """
  @spec billing_mode(map() | nil, map() | nil) :: billing_mode()
  def billing_mode(config, snapshot) do
    case configured_mode(config) do
      nil -> inferred_mode(snapshot)
      mode -> {mode, :configured}
    end
  end

  @doc """
  The metric the report and proposals denominate in, given a `billing_mode/2`
  verdict. The other metric is retained as secondary rather than dropped.
  """
  @spec primary_metric(billing_mode()) :: unit()
  def primary_metric({:subscription, _source}), do: :window_share
  def primary_metric({:metered, _source}), do: :cost_usd

  @doc "The metric kept alongside the primary one."
  @spec secondary_metric(billing_mode()) :: unit()
  def secondary_metric(mode) do
    case primary_metric(mode) do
      :window_share -> :cost_usd
      :cost_usd -> :window_share
    end
  end

  # ---- internals ----------------------------------------------------------

  defp configured_mode(%{} = config) do
    with %{} = loop <- Map.get(config, "loop") || Map.get(config, :loop),
         mode when is_binary(mode) <-
           Map.get(loop, "billing_mode") || Map.get(loop, :billing_mode) do
      case String.downcase(String.trim(mode)) do
        "subscription" -> :subscription
        "metered" -> :metered
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp configured_mode(_), do: nil

  # A unified 5h utilization figure — even `0.0` — is direct evidence of a
  # windowed plan. Only its total absence leaves dollars as the readable unit.
  defp inferred_mode(snapshot) when is_map(snapshot) do
    if is_number(fetch(snapshot, :utilization_5h)) or
         is_number(fetch(snapshot, :utilization_7d)),
       do: {:subscription, :inferred},
       else: {:metered, :default}
  end

  defp inferred_mode(_), do: {:metered, :default}

  defp fetch(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp num(map, key) do
    case fetch(map, key) do
      n when is_number(n) -> n / 1
      _ -> 0.0
    end
  end
end
