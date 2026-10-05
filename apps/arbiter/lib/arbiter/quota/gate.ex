defmodule Arbiter.Quota.Gate do
  @moduledoc """
  Behaviour for the quota-aware dispatch gate (bd-7cd38f).

  The gate is the single choke point the fleet dispatcher
  (`Arbiter.Worker.Dispatch.dispatch/2`) consults before mutating any task
  state, so a near-cap decision covers every dispatch path at once. It reads the
  latest quota snapshot for the account whose credential this dispatch will
  authenticate with, **and the provider this dispatch will actually run on** (bd-2mpo3f)
  and decides what to do when that provider nears / crosses its primary window cap:

    * `:allow` — dispatch proceeds normally (there is headroom, or we are
      failing open because no snapshot exists).
    * `{:hold, reason}` — HOLD the dispatch. The dispatcher enqueues the intent
      in the per-workspace `Arbiter.Workflows.DispatchQueue` and does NOT
      transition the task to `:active`; the queue drains it later in
      priority order as headroom frees.
    * `{:overage, spend_usd}` — dispatch proceeds past the cap (paid overage);
      `spend_usd` is the windowed overage spend the caller records + alerts on.

  ## Implementations

    * `Arbiter.Quota.Gate.Throttle` (default) — returns `{:hold, _}` near the cap.
    * `Arbiter.Quota.Gate.Continue` — always `:allow`, tagging `{:overage, _}`
      when the snapshot shows past-plan usage.

  The concrete module is resolved per-workspace by
  `Arbiter.Quota.gate_for_workspace/1`, which honours the config precedence
  (per-workspace > global > `:throttle`) and the `:arbiter, :quota` `:gate`
  app-env override (the kill switch / test injection seam).

  ## Providers (bd-2mpo3f)

  Every helper here takes a *snapshot* rather than an `AnthropicQuota` row:
  `Arbiter.Quota.Gate.Snapshot.normalize/1` projects `AnthropicQuota` (Claude),
  `CodexQuota` (Codex) and `GoogleQuota` (Antigravity) onto one
  provider-neutral shape — primary-window `utilization`, past-plan `status`,
  `reset_at` / `captured_at` — so the same near-cap semantics apply to all four
  providers without the gate knowing any provider's field names. The caller
  (`Arbiter.Worker.Dispatch`) resolves which provider the dispatch will run on
  and reads that provider's row via `Arbiter.Quota.latest_for_provider/2`.

  A `nil` quota snapshot (probe disabled, or nothing captured yet) MUST
  fail open — every implementation returns `:allow` so dispatch never
  deadlocks on missing quota data.

  ## Threshold modes (bd-2daof2)

  `threshold_mode` picks how each window's utilization ceiling is set. The two
  modes are mutually exclusive; the default is `"flat"`.

    * `"flat"` — a fixed ceiling: `throttle_threshold` (5h / session,
      default `0.85`) and `weekly_threshold`
      (7d / weekly, default `0.90`). The paced floors
      are ignored.
    * `"paced"` — the ceiling tracks time through the window:

          elapsed   = clamp(1 - (reset_at - now) / window_seconds, 0.0, 1.0)
          threshold = max(floor, elapsed)

      so at any moment the window may be about as used as it is elapsed, plus
      a head start after a reset: `paced_floor` (primary, default
      `0.35`) and `weekly_paced_floor` (long, default
      `0.20`). `throttle_threshold` /
      `weekly_threshold` are ignored and there is no hard ceiling: the
      threshold reaches 1.0 as the window ends, so its last quota can be spent
      just before the reset.

  A paced window falls back to its **flat** threshold when
  `window_seconds/2` cannot resolve its length (Codex `"session"`, Antigravity's
  collapsed `"used"`, by default) or its `reset_at` is `nil`.

  The account's `quota_config` and the workspace's `config["quota"]` each
  carry their own `threshold_mode` and floors. Composition is P7's
  `min(account, workspace)` rule, evaluated **at the moment of the check**:
  each side turns its own mode into a number for now (a flat value, or
  `max(floor, elapsed)`) and the smaller one binds, so a workspace can only
  ever be stricter than its account. `window_seconds` is account-only.

  Everything else is the same in both modes: the primary past-plan status
  and long-window `rejected` rules, `weekly_warning_policy/1`, and the
  staleness semantics of `stale?/1` / `long_window_stale?/1`. The gate is
  consulted only when a worker is about to *start*, so a running worker is
  never interrupted by a paced line it has pushed utilization past.

  ## Staleness, and when a stale 7d hold lifts (bd-b7umwj, bd-2wnkoq)

  The two windows age differently (`stale?/1`, `long_window_stale?/1`):

    * the **primary** (5h) window fails open once its snapshot is older than
      `staleness_threshold_seconds/1` for its source (1200 s for a polled
      row), or once its `reset_at` has passed — a held fleet makes no traffic,
      and this is how it gets a fresh reading (bd-y0yup0);
    * a **long-window** (7d) hold does not fail open on age: the provider
      still accepts requests at `allowed_warning`, so a let-through dispatch
      would run for hours against the very budget the hold protects
      (bd-b7umwj).

  That made it look as if "a 7d hold cannot lift without a fresh polled
  snapshot" — a trap, since the poll is the thing that is broken when the
  snapshot goes stale. The chosen answer is that a 7d hold on a snapshot
  nobody refreshes is **sticky but bounded**. It lifts at the first of:

    1. a fresh poll showing the long window cleared;
    2. the long window's own reset — the snapshot's `secondary_reset_at`
       (Anthropic `reset_7d_at`, Codex `weekly_reset_at`) passing, never more
       than seven days after the reading — after which the reading describes
       a closed window and no longer binds, fresh poll or not;
    3. with no reset time reported, the reading turning seven days old.

  So the worst case is bounded by `secondary_reset_at`, and it is not
  silent: once the snapshot is older than its alert threshold,
  `Arbiter.Quota.StalenessWatch` raises an operator alert that says whether a
  7d hold is in force and when it lifts.

  Escape hatches, for an operator who cannot wait for the reset:

    * **Restore the poll** — the real fix. The `quota_poll_failing` alert, or
      the `operator_login_lapsed` / `quota_grant_failing` escalation, names
      the credential and the command that logs it in again; the next poll
      lifts a hold its fresh reading no longer supports.
    * **Dispatch past it** — `arb config set quota.on_exhaustion continue
      --workspace <ws>` puts that workspace on `Arbiter.Quota.Gate.Continue`,
      which never holds: past-plan dispatch runs as paid overage, recorded and
      alerted, not stopped. Set it back to `throttle` once the poll is healthy.
    * **Raise the ceiling** — for a utilization hold, a higher
      `weekly_threshold`; for an `allowed_warning` hold,
      `weekly_warning_policy: ignore`. The account's `quota_config` is a floor
      a workspace may only tighten, so the account side may need it too
      (`arb account set <ref> --weekly-threshold F`, and `arb config set
      quota.weekly_threshold F` for the workspace). A 7d `rejected` is the
      provider refusing requests; no ceiling lifts that.

  ## The pace verdict (bd-clzkvp)

  Both utilization rules are decided by `Arbiter.Quota.Pace.evaluate/4`,
  through `pace/6`: the window holds exactly when its verdict is `:holding`.
  The same verdict — `:ok`, `:approaching`, `:holding` or `:sampling` —
  colours the web quota bars, evaluated under `paced_policy/1` so an account
  that has not opted into pacing still sees where the paced ceiling is. There
  is no second definition of "ahead of pace" for the UI to drift from.
  """

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Pace
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @default_throttle_threshold 0.85
  @default_weekly_threshold 0.90

  # Paced mode (bd-2daof2): the head start each window gets right after a
  # reset, before `elapsed` overtakes it. The 5h floor is deliberately low so
  # a 5h window tracks pace early rather than being burnable in two hours.
  @default_paced_floor 0.35
  @default_weekly_paced_floor 0.20
  @threshold_modes ~w[flat paced]

  # Built-in window lengths by snapshot window label — the second step of
  # `window_seconds/2`. Codex "session" (a session reset, not a fixed-length
  # window) and Antigravity's collapsed "used" (no time window) are absent.
  @builtin_window_seconds %{
    "5h" => 18_000,
    # grok's free-tier rolling window (bd-cwq8b0, `Arbiter.Quota.GrokLedger`).
    "24h" => 86_400,
    "7d" => 604_800,
    "weekly" => 604_800,
    "30d" => 2_592_000
  }

  # Staleness thresholds, per `capture_source` — see
  # `staleness_threshold_seconds/1` for why the polled source gets four times
  # the margin of the header capture.
  @default_staleness_threshold_seconds 300
  @default_polled_staleness_threshold_seconds 1_200
  # Mirrors `Arbiter.Quota.oauth_poll_source/0`. Inlined rather than called
  # because it is matched in a function head, and a compile-time reference to
  # the domain module from here would be a compile dependency in the wrong
  # direction (`Arbiter.Quota` calls this module).
  @oauth_poll_source "oauth_poll"
  @weekly_warning_policies ~w[ignore hold]

  # Both long windows this gate sees — Anthropic's 7d and Codex's weekly — are
  # seven days long. Used only as the bounded fallback in `long_window_stale?/1`
  # for a snapshot that carries no long-window `reset_at`.
  @long_window_seconds 7 * 24 * 60 * 60

  @type decision :: :allow | {:hold, term()} | {:overage, float()}

  @typedoc """
  Why the gate is holding: which window bound, what signal in it bound, and the
  numbers behind that call. `nil` when nothing binds. Returned by
  `gating_window/2` and carried verbatim as the `Throttle` hold reason.

  `threshold` is the effective value at the moment of the check. When a paced
  threshold is the one that bound (bd-2daof2), the map also carries
  `mode: :paced` and the window's `elapsed` fraction; a flat binding carries
  neither key, so its shape is exactly what it was before paced mode existed.
  """
  @type binding_window :: %{
          optional(:mode) => :paced,
          optional(:elapsed) => float(),
          provider: String.t() | nil,
          window: String.t(),
          signal: :status | :utilization | :warning,
          status: String.t() | nil,
          utilization: float() | nil,
          threshold: float() | nil
        }

  @typedoc """
  Any persisted provider quota row (`AnthropicQuota` / `CodexQuota` /
  `GoogleQuota`), an already-normalized `Snapshot`, or `nil`.
  """
  @type quota_source :: struct() | nil

  @typedoc """
  Whose gate settings a threshold resolves against (P7, `§4.2`).

  Since the quota snapshot is the *account's*, so is the default threshold:
  `{account, workspace}` resolves each setting `min(account, workspace)` —
  the account's number is a floor nobody can raise, and a workspace may only
  tighten it. This is how an operator expresses priority between workspaces
  sharing one budget ("`vstim` stops at 70% so `default` can run to 90%").

  A bare `Workspace` (or `nil`) is still accepted and resolves workspace-only,
  which is exactly pre-P7 behaviour for the surfaces whose own re-key is a
  later phase.
  """
  @type policy ::
          Workspace.t()
          | ProviderAccount.t()
          | {ProviderAccount.t() | nil, Workspace.t() | nil}
          | nil

  @callback check(
              task :: Issue.t() | nil,
              quota :: quota_source(),
              workspace :: Workspace.t() | nil,
              opts :: keyword()
            ) :: decision()

  @doc """
  The configured `utilization_5h` at/above which the throttle gate holds.

  Resolved `min(account, workspace)` (P7, §4.2) — see `t:policy/0`. The
  account's `quota_config["throttle_threshold"]` is the default and a hard
  floor; a workspace's `config["quota"]["throttle_threshold"]` may only
  tighten it. With no account setting, the historical chain applies:
  workspace override, then the global `:arbiter, :quota`
  `:throttle_threshold` app-env, then `0.85` (Ryan's hand-enforced ceiling,
  between the dashboard's 0.7/0.9 bands).

  This is the **flat** ceiling. Under `threshold_mode: "paced"` (bd-2daof2)
  the side that asked for pacing ignores its `throttle_threshold` and holds
  at `max(paced_floor, elapsed)` instead (floor default
  `#{@default_paced_floor}`), which only `gating_window/3` can evaluate
  because it depends on the window's `reset_at` and the time of the check. A
  paced window whose length `window_seconds/2` cannot resolve, or whose
  `reset_at` is `nil`, falls back to this flat value. See the moduledoc's
  "Threshold modes" section for how the two sides compose.
  """
  @spec threshold(policy()) :: float()
  def threshold(policy \\ nil) do
    {account, workspace} = split_policy(policy)

    strictest(
      account_fraction(account, "throttle_threshold"),
      ws_fraction(workspace, "throttle_threshold")
    ) || global_fraction(:throttle_threshold) || @default_throttle_threshold
  end

  @doc """
  The configured long-window (`utilization_7d` / Codex weekly) utilization at or
  above which the throttle gate holds (bd-1tuxv8).

  Resolved `min(account, workspace)` exactly as `threshold/1` (P7, §4.2):
  the account's `quota_config["weekly_threshold"]` is the floor, the
  workspace's `config["quota"]["weekly_threshold"]` may only tighten it, and
  with neither set the global `:arbiter, :quota` `:weekly_threshold` app-env
  applies, defaulting to `#{@default_weekly_threshold}`.

  The default sits **above** the 5h ceiling (`0.85`) on purpose: the weekly
  window resets at most once a week, so holding early parks the whole fleet for
  days, which is a worse failure than running the budget down. `0.90` leaves a
  10% reserve for whatever the operator most wants to spend it on while still
  stopping Autopilot from burning the tail of the week in an afternoon.

  Like `threshold/1`, this is the **flat** ceiling. A side in
  `threshold_mode: "paced"` ignores its `weekly_threshold` and holds at
  `max(weekly_paced_floor, elapsed)` (floor default
  `#{@default_weekly_paced_floor}`) — evaluated by `gating_window/3`, with the
  same flat fallback for a window of unknown length or with no `reset_at`.
  """
  @spec weekly_threshold(policy()) :: float()
  def weekly_threshold(policy \\ nil) do
    {account, workspace} = split_policy(policy)

    strictest(
      account_fraction(account, "weekly_threshold"),
      ws_fraction(workspace, "weekly_threshold")
    ) || global_fraction(:weekly_threshold) || @default_weekly_threshold
  end

  @doc """
  What an `allowed_warning` on the long window does (bd-1tuxv8).

    * `:ignore` (default) — no effect. The `weekly_threshold` utilization rule is
      the control; the warning tier is advisory only.
    * `:hold` — treat the warning like a reject and hold every dispatch.

  `:ignore` is the default deliberately. Anthropic raises `allowed_warning` on
  the 7d window well before the budget is actually gone (it was already set at
  0.76 utilization when this was filed), so defaulting to `:hold` would park the
  entire fleet for the rest of the week the first time the warning appeared —
  the exact "fleet stops for days" failure the ticket warns against. Installs
  that would rather stop early can opt in.

  Reads the account's `quota_config["weekly_warning_policy"]` and the
  workspace's `config["quota"]["weekly_warning_policy"]`, then the global
  `:arbiter, :quota` `:weekly_warning_policy` app-env. Same "never looser"
  rule as the thresholds (P7, §4.2): `:hold` is the stricter value, so if
  *either* side asks for it, it wins — a workspace can tighten the account's
  `:ignore` to `:hold`, but cannot relax the account's `:hold`.
  """
  @spec weekly_warning_policy(policy()) :: :ignore | :hold
  def weekly_warning_policy(policy \\ nil) do
    {account, workspace} = split_policy(policy)
    account_p = account_policy(account)
    ws_p = ws_policy(workspace)

    if :hold in [account_p, ws_p] do
      :hold
    else
      account_p || ws_p || global_policy() || :ignore
    end
  end

  @doc "Valid `quota.weekly_warning_policy` value strings."
  @spec weekly_warning_policies() :: [String.t()]
  def weekly_warning_policies, do: @weekly_warning_policies

  @doc "Valid `quota.threshold_mode` value strings (bd-2daof2)."
  @spec threshold_modes() :: [String.t()]
  def threshold_modes, do: @threshold_modes

  @quota_config_settable_keys ~w(threshold_mode weekly_threshold paced_floor weekly_paced_floor)

  @doc """
  Validate a partial `quota_config` update (bd-c7ll4t) — the fields `arb
  account set --threshold-mode ...` / `PATCH /api/accounts/:ref` may write.
  `threshold_mode` must be one of `threshold_modes/0`; `weekly_threshold`,
  `paced_floor` and `weekly_paced_floor` must be a number (or its string
  form) in `0..1`, the same fraction shape every other `quota_config` reader
  in this module expects. An unknown key is rejected outright rather than
  silently accepted and then never read by anything here — the failure mode
  that let `bd-5ps98m` set an account's `quota_config` only via `bin/arbiter
  eval`.

  Returns the validated map with numbers coerced to floats, ready to
  `Map.merge/2` into an account's existing `quota_config` (a partial update
  must not clobber sibling keys like `throttle_threshold` it does not
  mention).
  """
  @spec validate_quota_config(map()) ::
          {:ok, map()} | {:error, {:invalid_quota_config, String.t()}}
  def validate_quota_config(updates) when is_map(updates) do
    case Map.keys(updates) -- @quota_config_settable_keys do
      [] ->
        validate_quota_config_values(updates)

      unknown ->
        {:error,
         {:invalid_quota_config, "unknown quota_config key(s): #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp validate_quota_config_values(updates) do
    Enum.reduce_while(updates, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case validate_quota_config_field(key, value) do
        {:ok, validated} -> {:cont, {:ok, Map.put(acc, key, validated)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_quota_config_field("threshold_mode", mode) when mode in @threshold_modes,
    do: {:ok, mode}

  defp validate_quota_config_field("threshold_mode", mode) do
    {:error,
     {:invalid_quota_config,
      "threshold_mode must be one of #{Enum.join(@threshold_modes, ", ")} (got #{inspect(mode)})"}}
  end

  defp validate_quota_config_field(key, value)
       when key in ~w(weekly_threshold paced_floor weekly_paced_floor) do
    case strict_fraction(value) do
      {:ok, f} ->
        {:ok, f}

      :error ->
        {:error,
         {:invalid_quota_config, "#{key} must be a number in 0..1 (got #{inspect(value)})"}}
    end
  end

  defp strict_fraction(n) when is_number(n) and n > 0 and n <= 1, do: {:ok, n * 1.0}

  defp strict_fraction(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} when f > 0 and f <= 1 -> {:ok, f}
      _ -> :error
    end
  end

  defp strict_fraction(_), do: :error

  @doc """
  Which side of `min(account, workspace)` is currently binding `key`
  (bd-c7ll4t) — `threshold/1` / `weekly_threshold/1` collapse this into one
  number, which is exactly how a workspace set to `paced`/no-ceiling reading
  as capped at the account's flat `0.90` went unnoticed in `bd-5ps98m`. `arb
  quota --workspace` needs to say whose number is in force.

  Compares each side the same way `Pace.evaluate/4` does (`side/2` +
  `Pace.side_ceiling/2`), not by reading `throttle_threshold` /
  `weekly_threshold` directly — a side in `threshold_mode: "paced"` ignores
  its own flat key, so comparing the raw keys can name the wrong side, or
  keep comparing a stale flat value a paced account no longer uses.

  `opts[:elapsed]` is the window's elapsed fraction (`0.0..1.0`, from
  `Pace.elapsed_seconds/3` + `Pace.elapsed_fraction/2`) at the moment being
  described — pass it when a real reset time is known so a paced side
  resolves to its true `max(floor, elapsed)` ceiling. With no `elapsed`
  (unknown window length or `reset_at`), a paced side falls back to its own
  flat setting if it has one, exactly like the gate's own dispatch-time
  fallback, or drops out if it does not.

  Returns `:account`, `:workspace`, or `:default` (neither side resolved to
  a number for `key`, so the global app-env / built-in default applies).
  """
  @spec binding_side(policy(), :throttle_threshold | :weekly_threshold, keyword()) ::
          :account | :workspace | :default
  def binding_side(policy, key, opts \\ [])
      when key in [:throttle_threshold, :weekly_threshold] do
    case ranked_sides(policy, key, opts) do
      [] -> :default
      sides -> sides |> Enum.min_by(fn {_who, ceiling} -> ceiling end) |> elem(0)
    end
  end

  @doc """
  The `min(account, workspace)` ceiling for `key` actually in force right now
  (bd-c7ll4t) — the paced-aware companion to `binding_side/3`. Unlike
  `threshold/1` / `weekly_threshold/1`, which read the flat keys only, this
  resolves a `threshold_mode: "paced"` side to `max(floor, elapsed)` when
  `opts[:elapsed]` is known, so `arb quota --workspace` can print the number
  that binds instead of a flat figure a paced side has already stopped using.
  """
  @spec effective_threshold(policy(), :throttle_threshold | :weekly_threshold, keyword()) ::
          float()
  def effective_threshold(policy, key, opts \\ [])
      when key in [:throttle_threshold, :weekly_threshold] do
    case ranked_sides(policy, key, opts) do
      [] -> flat_default(threshold_window(key))
      sides -> sides |> Enum.min_by(fn {_who, ceiling} -> ceiling end) |> elem(1)
    end
  end

  # One `{who, ceiling}` pair per side that resolves to a number right now,
  # in `[account, workspace]` order so a tie (`Enum.min_by/2` keeps the first
  # match) reads as the account binding — same "account is the floor" call as
  # the old flat-key comparison made.
  defp ranked_sides(policy, key, opts) do
    {account, workspace} = split_policy(policy)
    window = threshold_window(key)
    elapsed = Keyword.get(opts, :elapsed)

    [account: account_config(account), workspace: ws_quota(workspace)]
    |> Enum.map(fn {who, config} -> {who, side(config, window)} end)
    |> Enum.map(fn {who, s} -> {who, s && Pace.side_ceiling(s, elapsed)} end)
    |> Enum.flat_map(fn
      {who, {ceiling, _mode}} -> [{who, ceiling}]
      {_who, nil} -> []
    end)
  end

  defp threshold_window(:throttle_threshold), do: :primary
  defp threshold_window(:weekly_threshold), do: :long

  @doc """
  The account's own quota policy, independent of any workspace (bd-c7ll4t) —
  `arb quota --account` shows this so the ceiling a bare account carries is
  visible on its own, ahead of any workspace's override.

  Under `threshold_mode: "paced"` the flat `throttle_threshold` /
  `weekly_threshold` keys are ignored by the gate (the paced floors bind
  instead), so they report `nil` rather than a number nothing is actually
  enforcing — showing the global default there read as though it still
  applied.
  """
  @spec account_policy_summary(ProviderAccount.t() | nil) :: map()
  def account_policy_summary(account) do
    config = account_config(account)
    mode = parse_mode(Map.get(config, "threshold_mode"))

    %{
      threshold_mode: Atom.to_string(mode),
      throttle_threshold: if(mode == :flat, do: threshold(account)),
      weekly_threshold: if(mode == :flat, do: weekly_threshold(account)),
      paced_floor: paced_floor(config, :primary),
      weekly_paced_floor: paced_floor(config, :long)
    }
  end

  @doc """
  The length in seconds of the quota window a snapshot labels `label`, or `nil`
  when it has no fixed length (bd-2daof2). First match wins:

    1. the account's `quota_config["window_seconds"][label]` — custom
       contracts and non-standard tiers;
    2. the built-in table: `"5h"` → 18_000, `"7d"` / `"weekly"` → 604_800,
       `"30d"` → 2_592_000 (Codex free); a `"<n>m"` label is n minutes;
    3. `nil` — Codex `"session"` (a session reset, not a fixed-length window)
       and Antigravity's collapsed `"used"` (no time window) by default.

  There is deliberately no workspace step: window length is a property of the
  account's plan, not of who is spending it.

  This is the one source of window lengths for both the paced gate and the
  web usage bars' pace math (`ArbiterWeb.QuotaHelpers`), so a bar can never
  read "on pace" against a different window than the gate holds against. An
  account value that is not a positive integer (or its string form) is
  ignored, falling through to the built-in table.
  """
  @spec window_seconds(String.t() | nil, ProviderAccount.t() | nil) :: pos_integer() | nil
  def window_seconds(label, account \\ nil) do
    account_window_seconds(account, label) || Map.get(@builtin_window_seconds, label) ||
      minutes_label_seconds(label)
  end

  # A `"<n>m"` label (a Codex window of a length with no named label, derived
  # from the stored `window_minutes` — bd-7lkvb6) is n minutes long.
  defp minutes_label_seconds(label) when is_binary(label) do
    case Regex.run(~r/\A(\d+)m\z/, label) do
      [_, n] -> n |> String.to_integer() |> Kernel.*(60) |> positive_or_nil()
      _ -> nil
    end
  end

  defp minutes_label_seconds(_), do: nil

  defp positive_or_nil(n) when n > 0, do: n
  defp positive_or_nil(_), do: nil

  defp account_window_seconds(account, label) do
    case account |> account_config() |> Map.get("window_seconds") do
      %{} = lengths -> lengths |> Map.get(label) |> parse_seconds()
      _ -> nil
    end
  end

  defp parse_seconds(n) when is_integer(n) and n > 0, do: n

  defp parse_seconds(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_seconds(_), do: nil

  # ---- the threshold in force at the moment of the check (bd-2daof2) -------

  @doc """
  The pace verdict for one window under `policy` (bd-clzkvp): the gate's own
  thresholds for that window, evaluated by `Arbiter.Quota.Pace.evaluate/4`.

  `window` is `:primary` (5h / session) or `:long` (7d / weekly) and picks
  which settings apply; `label` is the snapshot's window label, which
  `window_seconds/2` turns into the window's length. The gate's utilization
  rules hold exactly when this returns `verdict: :holding` — they are decided
  through it — so a quota bar coloured from this can never read red while the
  gate dispatches at the same inputs, or the other way round.

  Only the utilization rule is evaluated here; the past-plan `status`,
  long-window `rejected` and `weekly_warning_policy` rules are the gate's own
  and are not a pace question.

  Options: `:now` (default `DateTime.utc_now/0`) and `:account`, as in
  `gating_window/3`. To colour by the paced thresholds for an account that
  has not opted into them, pass `paced_policy/1`.
  """
  @spec pace(
          policy(),
          :primary | :long,
          String.t() | nil,
          number() | nil,
          DateTime.t() | nil,
          keyword()
        ) :: Pace.t()
  def pace(policy, window, label, utilization, reset_at, opts \\ []) do
    {account, _workspace} =
      policy = policy |> merge_account(Keyword.get(opts, :account)) |> split_policy()

    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    seconds = window_seconds(label, account)

    Pace.evaluate(
      utilization,
      Pace.elapsed_seconds(reset_at, seconds, now),
      seconds,
      pace_thresholds(policy, window)
    )
  end

  @doc """
  `policy` with its account switched into `threshold_mode: "paced"` — the
  thresholds the gate *would* hold at had the account opted into pacing
  (bd-clzkvp). The account keeps its own floors and window lengths, and the
  workspace side is left alone, so a workspace can still tighten. A policy
  with no account gets one carrying nothing but the mode, so the built-in
  floors apply.

  The quota bars colour by this whatever the account's real mode is, and
  compare it with `pace/6` under the real policy to tell "would hold" from
  "is holding".
  """
  @spec paced_policy(policy()) :: {ProviderAccount.t(), Workspace.t() | nil}
  def paced_policy(policy) do
    {account, workspace} = split_policy(policy)
    {force_paced(account), workspace}
  end

  defp force_paced(%ProviderAccount{} = account),
    do: %{account | quota_config: Map.put(account_config(account), "threshold_mode", "paced")}

  defp force_paced(_account),
    do: %ProviderAccount{quota_config: %{"threshold_mode" => "paced"}}

  # One `Pace` side per policy side that configured anything for this window.
  # A paced side carries its own flat setting as the fallback for a window
  # whose elapsed fraction is unknown (no length, no `reset_at`). Neither side
  # configured anything → no sides, and the flat global / built-in default
  # applies, exactly as `threshold/1` / `weekly_threshold/1` resolve it.
  defp pace_thresholds({account, workspace}, window) do
    %{
      sides:
        Enum.reject(
          [side(account_config(account), window), side(ws_quota(workspace), window)],
          &is_nil/1
        ),
      default: flat_default(window)
    }
  end

  defp side(config, window) do
    flat = config |> Map.get(flat_key(window)) |> parse_fraction()

    cond do
      parse_mode(Map.get(config, "threshold_mode")) == :paced ->
        {:paced, paced_floor(config, window), flat}

      flat ->
        {:flat, flat}

      true ->
        nil
    end
  end

  defp paced_floor(config, :primary),
    do: parse_fraction(Map.get(config, "paced_floor")) || @default_paced_floor

  defp paced_floor(config, :long),
    do: parse_fraction(Map.get(config, "weekly_paced_floor")) || @default_weekly_paced_floor

  defp flat_key(:primary), do: "throttle_threshold"
  defp flat_key(:long), do: "weekly_threshold"

  defp flat_default(:primary),
    do: global_fraction(:throttle_threshold) || @default_throttle_threshold

  defp flat_default(:long), do: global_fraction(:weekly_threshold) || @default_weekly_threshold

  # Anything but a valid mode string — including a typo in an account's
  # `quota_config`, which is not validated on write — reads as the default
  # `:flat`, the same fall-back-don't-raise contract as `parse_fraction/1`.
  defp parse_mode("paced"), do: :paced
  defp parse_mode(_), do: :flat

  defp ws_quota(%{config: %{"quota" => %{} = quota}}), do: quota
  defp ws_quota(_), do: %{}

  # ---- policy resolution: min(account, workspace) (P7, §4.2) -------------

  # The account is the floor and the workspace may only tighten it, so the
  # effective value is whichever of the two is present and smaller. `nil` when
  # neither side configured anything — the caller then falls through to the
  # global app-env and the built-in default, which is what a pre-P7 install
  # (no accounts, no `quota_config`) keeps getting.
  defp strictest(nil, nil), do: nil
  defp strictest(nil, ws), do: ws
  defp strictest(account, nil), do: account
  defp strictest(account, ws), do: min(account, ws)

  # `{account, workspace}` is the P7 shape. A bare workspace (or anything
  # else that is not a `ProviderAccount`) still resolves workspace-only, so
  # every pre-P7 call site — the board, `arb quota`, the `Gate` callbacks —
  # keeps working unchanged while their own re-key lands.
  defp split_policy({account, workspace}), do: {account, workspace}
  defp split_policy(%ProviderAccount{} = account), do: {account, nil}
  defp split_policy(workspace), do: {nil, workspace}

  # The account's gate settings live flat in `quota_config` (§3.1), not
  # nested under a "quota" key the way the workspace's do.
  defp account_fraction(account, key) do
    account |> account_config() |> Map.get(key) |> parse_fraction()
  end

  defp account_policy(account) do
    account |> account_config() |> Map.get("weekly_warning_policy") |> parse_policy()
  end

  defp account_config(%{quota_config: config}) when is_map(config), do: config
  defp account_config(_), do: %{}

  # Both thresholds are 0..1 fractions and may arrive as a number or its JSON
  # string form (the workspace config UI posts strings).
  defp ws_fraction(workspace, key) do
    get_in((workspace && workspace.config) || %{}, ["quota", key]) |> parse_fraction()
  end

  defp global_fraction(key) do
    Application.get_env(:arbiter, :quota, [])[key] |> parse_fraction()
  end

  defp parse_fraction(n) when is_number(n) and n > 0 and n <= 1, do: n * 1.0

  defp parse_fraction(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} when f > 0 and f <= 1 -> f
      _ -> nil
    end
  end

  defp parse_fraction(_), do: nil

  defp ws_policy(workspace) do
    get_in((workspace && workspace.config) || %{}, ["quota", "weekly_warning_policy"])
    |> parse_policy()
  end

  defp global_policy do
    Application.get_env(:arbiter, :quota, [])[:weekly_warning_policy] |> parse_policy()
  end

  defp parse_policy(p) when p in [:ignore, :hold], do: p
  defp parse_policy(s) when is_binary(s), do: parse_policy_string(s)
  defp parse_policy(_), do: nil

  defp parse_policy_string(s) when s in @weekly_warning_policies, do: String.to_existing_atom(s)
  defp parse_policy_string(_), do: nil

  @doc """
  Whether the snapshot's **primary** window has already elapsed and can no
  longer be trusted for gate decisions. Returns `false` for `nil` (nil is
  handled as fail-open by both `over_cap?/2` and `in_overage?/2`).

  A snapshot is stale when either:
    * `reset_at` is set and lies in the past — the window has rolled (Anthropic
      5h, Codex session, Google representative model), so `utilization` /
      `status` no longer reflect the current window.
    * `captured_at` is older than the staleness threshold for the snapshot's
      own `capture_source` (300 s for proxy header capture, 1200 s for a
      `/api/oauth/usage` poll — see `staleness_threshold_seconds/1`) — the
      snapshot is too old to trust for dispatch decisions even if the window
      hasn't rolled yet. After `/limit-reset` or other API state changes, the
      snapshot won't reflect the new state until a request is made, and if the
      gate holds all requests, the stale snapshot never updates (bd-y0yup0).

  This is the *primary-window* predicate, and it is what callers outside the
  gate mean by "too old to trust" — `Arbiter.Loop.Scarcity` uses it to refuse
  to calibrate, and `arb quota` prints it as `STALE`.

  Staleness fails open **for the primary window only**: `over_cap?/2` /
  `gating_window/2` drop the primary rules of a stale snapshot. If the
  workspace is still genuinely exhausted, at most one dispatch attempt per
  staleness window (default 5 min) will be let through before the gate
  re-captures the real `rejected` status and starts holding again (the clock
  resets on the captured_at timestamp). `in_overage?/2` is deliberately
  narrower: an age-stale reading that shows the cap reached keeps counting
  as overage until its window resets (see its doc).

  The **long** window does not fail open on age — see `long_window_stale?/1`.
  """
  @spec stale?(quota_source()) :: boolean()
  def stale?(quota), do: quota |> Snapshot.normalize() |> snapshot_stale?()

  # `now` is a parameter so `gating_window/3`'s `opts[:now]` moves the
  # staleness checks and the paced math together — a pinned clock must not
  # quietly age the snapshot against the real one.
  defp snapshot_stale?(snapshot, now \\ DateTime.utc_now())

  defp snapshot_stale?(nil, _now), do: false

  defp snapshot_stale?(%Snapshot{} = snapshot, now) do
    reset_elapsed?(snapshot.reset_at, now) or
      captured_older_than?(
        snapshot.captured_at,
        staleness_threshold_seconds(snapshot.capture_source),
        now
      )
  end

  @doc """
  Whether the snapshot's **long** window (Anthropic 7d, Codex weekly) can no
  longer be trusted. Returns `false` for `nil` and for providers that report no
  long window at all (Google), whose long-window rules never bind anyway.

  Deliberately *not* the same predicate as `stale?/1` (bd-b7umwj). Age alone
  never invalidates a long-window reading, because the fail-open recovery
  `stale?/1` exists for does not work on this window:

    * On the primary window a hold means the provider is *refusing* requests.
      The one attempt per staleness window that fail-open lets through is
      rejected in milliseconds and re-captures a real `rejected` — cheap, and
      the only way out of the deadlock bd-y0yup0 describes.
    * On the long window a hold happens at `allowed_warning` — the provider
      still **accepts** the request. The let-through dispatch therefore
      succeeds and runs a worker for hours against the very budget the hold
      exists to protect, and because a held fleet makes no traffic, the
      snapshot is stale again five minutes later. That is not a recovery
      valve, it is a loop that burns the week (observed 2026-09-11: the 7d
      window walked 94% → 96% *after* the stop went live).

  So a long-window hold is sticky. It lifts when a **fresh** snapshot shows it
  cleared, or when the long window's own `reset_at` rolls — never on age alone.
  Refreshing the snapshot does not need a worker dispatch: `Arbiter.Quota.CloudProbe`
  polls Anthropic's `/api/oauth/usage` on a timer (bd-atyrrq) and writes the
  primary + long-window columns straight from that poll, independent of any
  worker traffic — the fleet being idle no longer stalls the refresh.

  The one age-based exception is a bounded safety valve: when the provider
  reports no long-window `reset_at` there is no rollover to key on, so a
  reading older than the long window's own length (#{@long_window_seconds}s /
  7 days — both Anthropic's 7d and Codex's weekly window) stops binding,
  since by then the window must have rolled at least once.

  When the poll itself is what broke, the hold still lifts at the window's
  reset — see "Staleness, and when a stale 7d hold lifts" in the moduledoc,
  which also lists the operator's escape hatches (bd-2wnkoq).
  """
  @spec long_window_stale?(quota_source()) :: boolean()
  def long_window_stale?(quota), do: quota |> Snapshot.normalize() |> snapshot_long_stale?()

  defp snapshot_long_stale?(snapshot, now \\ DateTime.utc_now())

  defp snapshot_long_stale?(nil, _now), do: false

  defp snapshot_long_stale?(%Snapshot{secondary_window_label: nil}, _now), do: false

  defp snapshot_long_stale?(%Snapshot{secondary_reset_at: %DateTime{} = reset_at}, now),
    do: reset_elapsed?(reset_at, now)

  defp snapshot_long_stale?(%Snapshot{} = snapshot, now),
    do: captured_older_than?(snapshot.captured_at, @long_window_seconds, now)

  defp reset_elapsed?(%DateTime{} = reset_at, now),
    do: DateTime.compare(reset_at, now) == :lt

  defp reset_elapsed?(_, _now), do: false

  defp captured_older_than?(captured_at, seconds, now \\ DateTime.utc_now())

  defp captured_older_than?(%DateTime{} = captured_at, seconds, now),
    do: DateTime.diff(now, captured_at, :second) >= seconds

  defp captured_older_than?(_, _, _now), do: false

  @doc """
  Whether the `/api/oauth/usage` poll itself has succeeded recently — Anthropic
  only, keyed on `oauth_captured_at` rather than `capture_source` /
  `captured_at` (bd-4fbpto).

  `oauth_captured_at` advances on **every** successful poll
  (`Arbiter.Quota.record_oauth_usage/3`'s `secondary` write), even a thin body
  with no aggregate 5h figure that never touches the primary columns
  `stale?/1` looks at. So a row can have `stale?/1 == true` (the primary
  snapshot hasn't moved) while this returns `true` too (the poll is fine, it
  just isn't the primary source right now) — that distinction is exactly what
  `arb quota` needs to tell "no fresh data from any source" apart from
  "polling is working, just not feeding the gate columns this cycle" (see the
  PR #1607: silence here read as a total outage for 2.8 hours because
  nothing separated those two cases).
  """
  @spec oauth_poll_fresh?(Arbiter.Quota.AnthropicQuota.t() | nil) :: boolean()
  def oauth_poll_fresh?(nil), do: false
  def oauth_poll_fresh?(%{oauth_captured_at: nil}), do: false

  def oauth_poll_fresh?(%{oauth_captured_at: %DateTime{} = at}),
    do: not captured_older_than?(at, staleness_threshold_seconds(@oauth_poll_source))

  @doc """
  The staleness threshold in seconds. A snapshot older than this is treated as
  stale and fails open (no longer trusted for gate decisions).

  Reads the `:arbiter, :quota` `:staleness_threshold_seconds` app-env,
  defaulting to 300 seconds (5 minutes). This ensures that quota snapshots are
  refreshed frequently enough to catch state changes like a `/limit-reset`
  clearing the rate-limit cap. Without this threshold, a rejected snapshot held
  indefinitely without being updated (since the gate prevents requests) would
  deadlock recovery (bd-y0yup0).
  """
  @spec staleness_threshold_seconds() :: integer()
  def staleness_threshold_seconds do
    case Application.get_env(:arbiter, :quota, [])[:staleness_threshold_seconds] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_staleness_threshold_seconds
    end
  end

  @doc """
  The staleness threshold for a snapshot written by `capture_source`
  (bd-b0zody).

  Header capture rides on traffic the fleet is making anyway, so a gap in it
  means the fleet went quiet — 300 s is a fine trip-wire. The
  `/api/oauth/usage` poll is different: that endpoint's account-wide budget is
  roughly **one request per 5 minutes**, which is exactly
  `Arbiter.Quota.CloudProbe`'s 300 s cadence, and it 429s readily. A 429 costs
  **two** polls: the rejected one, and the next scheduled one, which
  `Arbiter.Quota.OAuthUsage`'s cooldown (one cycle plus 30 s, or a longer
  `Retry-After`) suppresses on purpose so a rate-limited poll backs off instead
  of hammering the endpoint (#1876). The next successful poll then lands about
  three cycles — ~900 s — after the last one. With any threshold under that, a
  single 429 would age the row past it and fail the primary window **open**:
  the fleet would dispatch straight into a cap it had just measured.

  A polled row therefore gets #{@default_polled_staleness_threshold_seconds} s
  (`:polled_staleness_threshold_seconds` app-env): four poll cycles, which
  covers the rejected poll, the suppressed one and the poll that lands, plus a
  whole cycle of slack for scheduling drift and request latency. It takes a
  sustained outage (a second 429 in a row, or a lapsed credential) rather than
  one 429 to lose the gate. Trusting a polled row for longer only ever keeps
  the primary rules — holds and past-plan detection — in force for longer; a
  stale row fails open, so a longer threshold can never let through a dispatch
  a shorter one would have held. Raising the threshold was chosen over polling
  faster (e.g. every 240 s) because polling faster *spends* more of the same
  scarce budget to buy the margin — and makes a 429, and the poll it costs,
  more likely. A blackout longer than this margin is what
  `Arbiter.Quota.StalenessWatch` alerts on.

  Anything other than the poll marker — the proxy's `"headers"`, `nil` on
  legacy rows, and every non-Anthropic provider (Codex / Google, which carry
  no `capture_source`) — keeps `staleness_threshold_seconds/0`.
  """
  @spec staleness_threshold_seconds(String.t() | nil) :: integer()
  def staleness_threshold_seconds(@oauth_poll_source) do
    case Application.get_env(:arbiter, :quota, [])[:polled_staleness_threshold_seconds] do
      n when is_integer(n) and n > 0 -> n
      _ -> max(@default_polled_staleness_threshold_seconds, staleness_threshold_seconds())
    end
  end

  def staleness_threshold_seconds(_source), do: staleness_threshold_seconds()

  @doc """
  Whether the snapshot indicates the provider is at/over a cap in **either** of
  its windows. Sugar for `gating_window/2 != nil`.

  A `nil` snapshot is never "over cap" (fail open). Staleness is scoped to the
  window it actually describes (bd-b7umwj): a stale **primary** window fails
  open, a stale **long** window stays held. Shared by both gate
  implementations.
  """
  @spec over_cap?(quota_source(), policy()) :: boolean()
  def over_cap?(quota, policy), do: gating_window(quota, policy) != nil

  @doc """
  Which window, if any, is currently gating dispatch — and why (bd-1tuxv8).

  Returns `nil` when dispatch is free to proceed, or a `t:binding_window/0`
  describing the binding constraint. Checked in severity order, so the reported
  reason is the most urgent one when several apply at once:

    1. primary status past-plan (Anthropic `status_5h`, Codex `limit_reached`) —
       the provider is refusing requests right now;
    2. long-window status *rejected* — the provider is refusing on the weekly
       budget (anything other than `nil` / `"allowed"` / `"allowed_warning"`);
    3. primary `utilization >= threshold/1` — our own 5h ceiling (or, in
       paced mode, `max(paced_floor, elapsed)`; see "Threshold modes" in the
       moduledoc);
    4. long-window `utilization >= weekly_threshold/1` — our own weekly ceiling
       (or its paced equivalent, `max(weekly_paced_floor, elapsed)`);
    5. long-window `"allowed_warning"`, when `weekly_warning_policy/1` is
       `:hold`.

  Each window's rules are skipped when *that* window's reading can no longer be
  trusted — `stale?/1` drops rules 1 and 3, `long_window_stale?/1` drops rules
  2, 4 and 5 (bd-b7umwj). The severity order above is preserved across whatever
  survives, so a fail-open 5h window still reports the 7d hold underneath it
  rather than reporting nothing.

  Note the asymmetry in how `status` is treated between the two windows, and
  that it is deliberate. On the primary window *any* non-`"allowed"` status
  holds, including `"allowed_warning"` — that window resets in hours, so
  stopping early is cheap. On the long window `"allowed_warning"` is routed
  through `weekly_warning_policy/1` instead (default `:ignore`): Anthropic sets
  it far from exhaustion, and treating it like a reject would hold the fleet for
  the remainder of the week. A genuine long-window reject always holds (rule 2).
  """
  @spec gating_window(quota_source(), policy()) :: binding_window() | nil
  def gating_window(quota, policy), do: gating_window(quota, policy, [])

  @doc """
  Same as `gating_window/2`, but forwards `opts` to `Snapshot.normalize/2` —
  in particular `opts[:model]`, which picks the correct Antigravity sub-bucket
  (bd-7qj58o AC4) when `quota` is an `"antigravity"` `GoogleQuota` row.

  Other options:

    * `:account` — the `ProviderAccount` half of the policy, for a caller
      that passes a bare workspace.
    * `:now` — the `DateTime` the check is evaluated at (default
      `DateTime.utc_now/0`). Drives both the paced thresholds' `elapsed` and
      the staleness checks, so a pinned clock gives a deterministic answer.
  """
  @spec gating_window(quota_source(), policy(), keyword()) :: binding_window() | nil
  def gating_window(quota, policy, opts) do
    case Snapshot.normalize(quota, opts) do
      nil ->
        nil

      %Snapshot{} = snapshot ->
        binding(
          snapshot,
          merge_account(policy, Keyword.get(opts, :account)),
          Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        )
    end
  end

  # `opts[:account]` is how a caller that still passes a bare workspace — the
  # `Arbiter.Quota.Gate` `check/4` implementations, whose own signature is
  # untouched — supplies the account half of the policy.
  defp merge_account(policy, nil), do: policy
  defp merge_account({_account, workspace}, account), do: {account, workspace}
  defp merge_account(%ProviderAccount{}, account), do: {account, nil}
  defp merge_account(workspace, account), do: {account, workspace}

  defp binding(%Snapshot{} = s, policy, now) do
    primary? = not snapshot_stale?(s, now)
    long? = not snapshot_long_stale?(s, now)

    [
      {primary?, &primary_status_binding/3},
      {long?, &secondary_status_binding/3},
      {primary?, &primary_utilization_binding/3},
      {long?, &secondary_utilization_binding/3},
      {long?, &secondary_warning_binding/3}
    ]
    |> Enum.filter(fn {trusted?, _rule} -> trusted? end)
    |> Enum.find_value(fn {_trusted?, rule} -> rule.(s, policy, now) end)
  end

  defp primary_status_binding(%Snapshot{} = s, _policy, _now) do
    if status_not_allowed?(s.status) do
      %{
        provider: s.provider,
        window: s.window_label,
        signal: :status,
        status: s.status,
        utilization: s.utilization,
        threshold: nil
      }
    end
  end

  defp secondary_status_binding(%Snapshot{} = s, _policy, _now) do
    if secondary_rejected?(s.secondary_status) do
      %{
        provider: s.provider,
        window: s.secondary_window_label,
        signal: :status,
        status: s.secondary_status,
        utilization: s.secondary_utilization,
        threshold: nil
      }
    end
  end

  defp primary_utilization_binding(%Snapshot{} = s, policy, now) do
    case pace(policy, :primary, s.window_label, s.utilization, s.reset_at, now: now) do
      %{verdict: :holding} = pace ->
        %{
          provider: s.provider,
          window: s.window_label,
          signal: :utilization,
          status: s.status,
          utilization: s.utilization,
          threshold: pace.ceiling
        }
        |> put_pace(pace)

      _ ->
        nil
    end
  end

  defp secondary_utilization_binding(%Snapshot{secondary_window_label: nil}, _policy, _now),
    do: nil

  defp secondary_utilization_binding(%Snapshot{} = s, policy, now) do
    case long_pace(s, policy, now) do
      %{verdict: :holding} = pace ->
        %{
          provider: s.provider,
          window: s.secondary_window_label,
          signal: :utilization,
          status: s.secondary_status,
          utilization: s.secondary_utilization,
          threshold: pace.ceiling
        }
        |> put_pace(pace)

      _ ->
        nil
    end
  end

  defp secondary_warning_binding(%Snapshot{} = s, policy, now) do
    if s.secondary_status == "allowed_warning" and weekly_warning_policy(policy) == :hold do
      %{
        provider: s.provider,
        window: s.secondary_window_label,
        signal: :warning,
        status: s.secondary_status,
        utilization: s.secondary_utilization,
        threshold: long_pace(s, policy, now).ceiling
      }
    end
  end

  defp long_pace(%Snapshot{} = s, policy, now) do
    pace(
      policy,
      :long,
      s.secondary_window_label,
      s.secondary_utilization,
      s.secondary_reset_at,
      now: now
    )
  end

  defp put_pace(binding, %{mode: :paced, elapsed: elapsed}),
    do: Map.merge(binding, %{mode: :paced, elapsed: elapsed})

  defp put_pace(binding, %{mode: :flat}), do: binding

  # Long-window statuses: nil / "allowed" are fine, "allowed_warning" is the
  # policy-governed warning tier, everything else ("rejected", …) is a hard stop.
  defp secondary_rejected?(status)
       when is_binary(status) and status not in ["allowed", "allowed_warning"],
       do: true

  defp secondary_rejected?(_), do: false

  @doc """
  A short human phrase for the current hold, or `nil` when nothing is gating.

  The 5h phrasing is unchanged (`"quota exhausted"` / `"quota near
  exhaustion (…)"`), so existing board copy and operator muscle memory still
  read the same. A long-window hold is deliberately worded differently — it
  leads with the window label, because "wait ~3 hours" and "wait until Sunday"
  are very different operator instructions:

      blocked — 7d quota 91% ≥ 90%
      blocked — 7d quota exhausted (status=rejected)
      blocked — 7d quota allowed_warning (weekly_warning_policy: hold)

  A paced hold (bd-2daof2) says it is pace-driven, so the moving ceiling does
  not read as one that changed at random:

      blocked — quota ahead of pace (40% of window used, paced ceiling 35%, 30% elapsed)
      blocked — 7d quota 0.62 ≥ paced 0.55 (55% elapsed)
  """
  @spec hold_phrase(quota_source(), policy()) :: String.t() | nil
  def hold_phrase(quota, policy), do: hold_phrase(quota, policy, [])

  @doc "Same as `hold_phrase/2`, but forwards `opts` to `gating_window/3` (bd-7qj58o)."
  @spec hold_phrase(quota_source(), policy(), keyword()) :: String.t() | nil
  def hold_phrase(quota, policy, opts) do
    case gating_window(quota, policy, opts) do
      nil -> nil
      binding -> phrase(binding, account_label(policy, opts))
    end
  end

  # `provider:slug` of the account being held (`claude:default`), so a hold
  # says which account's quota it is. `nil` when no persisted account is known.
  defp account_label(policy, opts) do
    case Keyword.get(opts, :account) || policy_account(policy) do
      %{provider: provider, slug: slug} when not is_nil(provider) and is_binary(slug) ->
        "#{provider}:#{slug}"

      _ ->
        nil
    end
  end

  defp policy_account({account, _workspace}), do: account
  defp policy_account(account), do: account

  defp phrase(binding, label) do
    window = binding.window

    case {binding, primary_window?(window), label} do
      {%{signal: :status}, true, _} ->
        prefix(label, "quota exhausted")

      {%{signal: :status, status: s}, false, nil} ->
        "#{window} quota exhausted (status=#{s})"

      {%{signal: :status, status: s}, false, l} ->
        "#{l} #{window} exhausted (status=#{s})"

      {%{signal: :warning, status: s}, _, nil} ->
        "#{window} quota #{s} (weekly_warning_policy: hold)"

      {%{signal: :warning, status: s}, _, l} ->
        "#{l} #{window} #{s} (weekly_warning_policy: hold)"

      {%{signal: :utilization}, true, _} ->
        prefix(label, primary_utilization(binding))

      {%{signal: :utilization}, false, _} ->
        "#{long_head(label, window)} #{long_utilization(binding)}"
    end
  end

  defp prefix(nil, text), do: text
  defp prefix(label, text), do: "#{label} #{text}"

  defp long_head(nil, window), do: "#{window} quota"
  defp long_head(label, window), do: "#{label} #{window}"

  defp primary_utilization(%{mode: :paced, utilization: u, threshold: t, elapsed: e}) do
    "quota ahead of pace (#{percent(u)} of window used, paced ceiling #{percent(t)}, " <>
      "#{percent(e)} elapsed)"
  end

  defp primary_utilization(%{utilization: u, threshold: t}),
    do: "quota near exhaustion (#{percent(u)} of window used, ceiling #{percent(t)})"

  defp long_utilization(%{mode: :paced, utilization: u, threshold: t, elapsed: e}),
    do: "#{percent(u)} ≥ paced #{percent(t)} (#{percent(e)} elapsed)"

  defp long_utilization(%{utilization: u, threshold: t}), do: "#{percent(u)} ≥ #{percent(t)}"

  # The long windows are the ones the secondary mapping names; everything else
  # ("5h", "session", "used", "primary") is the short/primary window.
  defp primary_window?(window), do: window not in ["7d", "weekly", "30d"]

  defp percent(n) when is_number(n), do: "#{round(n * 100)}%"
  defp percent(_), do: "—"

  @doc """
  Whether the snapshot indicates *genuine past-plan usage* — Anthropic's
  `overage_status == "in_overage"`, or the primary window is past-plan
  (`status != "allowed"`; for Codex that is `limit_reached`). Used by `Continue`
  to decide when to tag overage spend.

  Deliberately does NOT key on the throttle threshold (`over_cap?/2`): crossing
  `utilization >= throttle_threshold` while still `"allowed"` means we are near
  the cap, not past the plan. Tagging overage there would record overage spend —
  and fire the overage alert — before the account is actually paying overage
  (reviewer round 1, finding 2). For the same reason a long-window
  `"allowed_warning"` is not overage either; only an outright long-window
  reject is (bd-1tuxv8).

  ## Staleness: detection does not fail open like the gate (bd-2wnkoq)

  A long-window reject keeps counting until `long_window_stale?/1` says
  otherwise, exactly as in `gating_window/2` (bd-b7umwj). The primary window
  is **not** scoped like the gate's, by decision:

    * A past-plan primary reading counts while the snapshot is fresh, as
      before.
    * On a snapshot that is stale only by **age**, a reading that shows the
      cap *reached* — `overage_status == "in_overage"`, or a past-plan
      `status` other than the `allowed_warning` tier (`"rejected"`, Codex
      `"limit_reached"`) — keeps counting **until that window's `reset_at`
      passes**.
    * Everything else fails open as the gate does: the window has rolled
      (`reset_at` passed — the reading describes a closed window), there is
      no `reset_at` to bound the reading, or the reading is `allowed_warning`
      (a burn-rate warning that clears by itself as the window elapses).

  Why not simply mirror the gate: the gate fails open on age so a held fleet,
  which makes no traffic, gets one dispatch through to re-capture a real
  reading (bd-y0yup0). This function holds nothing, so there is nothing to
  recover from, and usage inside one window only accumulates — a cap reached
  at 14:00 is still reached at 14:30 unless the window reset in between.
  Dropping the signal on age was not a neutral fail-open, either: `Continue`
  then answered `:allow`, and `Arbiter.Worker.Dispatch` reads an `:allow`
  over a snapshot as "not past the cap" and **clears the overage alert** —
  so a lapsed poll silently cleared the alert and stopped the overage
  accounting mid-window, while the fleet kept paying overage.

  What stays undetected is a cap crossed **after** the snapshot went stale:
  a stale `"allowed"` reading cannot show it, nor can one whose window has
  rolled. That blind spot is accepted because it cannot be closed without a
  fresh reading, and it is covered by `Arbiter.Quota.StalenessWatch` — the
  compensating control: once the snapshot's `captured_at` is older than its
  alert threshold, it raises an operator alert (whether or not anything
  reports a poll failure) saying quota accounting is blind and for how long.
  """
  @spec in_overage?(quota_source(), policy()) :: boolean()
  def in_overage?(quota, _policy) do
    case Snapshot.normalize(quota) do
      nil ->
        false

      %Snapshot{} = snapshot ->
        now = DateTime.utc_now()
        primary_overage?(snapshot, now) or long_window_overage?(snapshot, now)
    end
  end

  @doc """
  The primary-window half of `in_overage?/2` on its own: whether the
  snapshot's primary window shows past-plan usage that `in_overage?/2`
  counts, staleness rules included. `Arbiter.Quota.StalenessWatch` uses it to
  say whether a stale snapshot's last 5h reading is still being counted.
  """
  @spec primary_in_overage?(quota_source()) :: boolean()
  def primary_in_overage?(quota) do
    case Snapshot.normalize(quota) do
      nil -> false
      %Snapshot{} = snapshot -> primary_overage?(snapshot, DateTime.utc_now())
    end
  end

  defp primary_overage?(%Snapshot{} = s, now) do
    past_plan?(s) and (not snapshot_stale?(s, now) or cap_reached_this_window?(s, now))
  end

  defp past_plan?(%Snapshot{} = s),
    do: s.overage_status == "in_overage" or status_not_allowed?(s.status)

  # A cap that was *reached* stays reached until the window it was reached in
  # resets — usage inside one window only accumulates. Not the
  # `allowed_warning` tier, a burn-rate warning that clears by itself as the
  # window elapses; and not a reading with no `reset_at` to bound it.
  defp cap_reached_this_window?(%Snapshot{reset_at: %DateTime{} = reset_at} = s, now) do
    DateTime.after?(reset_at, now) and
      (s.overage_status == "in_overage" or
         (status_not_allowed?(s.status) and s.status != "allowed_warning"))
  end

  defp cap_reached_this_window?(%Snapshot{}, _now), do: false

  defp long_window_overage?(%Snapshot{} = s, now) do
    not snapshot_long_stale?(s, now) and secondary_rejected?(s.secondary_status)
  end

  defp status_not_allowed?(status) when is_binary(status), do: status != "allowed"
  defp status_not_allowed?(_), do: false
end
