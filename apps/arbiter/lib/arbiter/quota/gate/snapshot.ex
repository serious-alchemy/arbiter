defmodule Arbiter.Quota.Gate.Snapshot do
  @moduledoc """
  Provider-neutral view of a quota snapshot, for `Arbiter.Quota.Gate` (bd-2mpo3f).

  Each provider persists its quota state in its own table with its own field
  names — `AnthropicQuota` has `utilization_5h` / `status_5h` / `reset_5h_at`,
  `CodexQuota` has `session_used_percent` / `limit_reached` / `session_reset_at`,
  `GoogleQuota` has a single representative `used_percent` / `reset_at`. The gate
  needs the same three things from all of them, so `normalize/1` projects each
  row onto this struct and the gate reasons only about:

    * `utilization` — the primary window's usage as a `0.0..1.0` fraction
      (Codex/Google report 0–100 percents; those are rescaled here).
    * `status` — the provider's own verdict. `"allowed"` (or `nil`) means
      plan-allowed; anything else is past-plan and holds. Codex's
      `limit_reached: true` maps to `"limit_reached"`; Google reports no status.
    * `reset_at` / `captured_at` — the staleness inputs (`Gate.stale?/1`),
      alongside `capture_source`, which says which of the two Anthropic
      sources wrote them and therefore which staleness threshold applies
      (bd-b0zody). Codex / Google have a single source each, so it stays
      `nil` for them.
    * `secondary_utilization` / `secondary_status` / `secondary_reset_at` —
      the same three things for the provider's **long** window (Anthropic 7d,
      Codex weekly), named by `secondary_window_label`.
    * `burn_24h` / `burn_24h_at` — the fraction of the long window used over the
      last 24 h and when that was computed (`Arbiter.Quota.Burn`, bd-cklotu).
      Anthropic only; `nil` for the others and for a sparse history.

  ## Both windows are projected (bd-1tuxv8)

  This used to project only the primary window, collapsing `utilization_5h` /
  `status_5h` onto one pair and dropping `utilization_7d` / `status_7d` on the
  floor — so a workspace at `utilization_7d 0.76, status_7d allowed_warning`
  dispatched straight through on a 23% 5h window, and the fleet would only
  discover the weekly budget was gone when every worker started failing at once.
  Both windows are now carried, and `Arbiter.Quota.Gate.gating_window/2` decides
  which (if either) binds. Google's Cloud Code Assist API reports a single
  representative model window, so its secondary fields stay `nil`.

  ## Scoped windows (bd-e0b7so, 5H C6)

  Anthropic reports per-model weekly limits (`limits[]` entries of
  `kind: "weekly_scoped"`, e.g. Fable's). A scoped limit is a **subset** of the
  weekly one — a Fable run draws on both — so it is a window *nested* in the
  account's `claude` pool, not a pool of its own: seats stay on the one pool and
  `scoped` is a list of extra long-class windows, evaluated with the `weekly_*`
  keys and the account's `pace_curve` exactly like the base long window. Each is
  `%{scope, label, utilization, status, reset_at, active?}`, `label` being
  `"7d (Fable)"` so a hold reads "7d (Fable) binds".

  `normalize/2` projects them per model. With no `:model` option the snapshot
  carries none (the account-level view, which the board and `History` read);
  with `model: m`, those whose scope matches `m`; with `model: nil`, every
  matched one (the worst of all — the conservative reading, as for agy);
  `model: :unscoped` is a card on a model no scoped limit covers. A scope that
  matches no known Claude model is never gated on a model match: it rides along
  only when Anthropic marks it `is_active`, and then for every model (the
  conservative account-level treatment). `long_views/1` is how a consumer
  evaluates them: one snapshot per long window.

  `overage_status` is Anthropic-only (there is no paid-overage passthrough for
  Codex or Google); it stays `nil` for those providers, so `Gate.in_overage?/2`
  falls back to the past-plan `status` signal for them.

  `normalize/1` returns `nil` for `nil` and for anything it does not recognize —
  the gate's fail-open contract: an unknown or missing snapshot never blocks a
  dispatch.
  """

  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Extensions

  @type t :: %__MODULE__{
          provider: String.t() | nil,
          utilization: float() | nil,
          status: String.t() | nil,
          reset_at: DateTime.t() | nil,
          captured_at: DateTime.t() | nil,
          capture_source: String.t() | nil,
          overage_status: String.t() | nil,
          window_label: String.t() | nil,
          secondary_utilization: float() | nil,
          secondary_status: String.t() | nil,
          secondary_reset_at: DateTime.t() | nil,
          secondary_window_label: String.t() | nil,
          burn_24h: float() | nil,
          burn_24h_at: DateTime.t() | nil,
          scoped: [scoped()]
        }

  @typedoc "One per-model weekly window nested in the long window (see the moduledoc)."
  @type scoped :: %{
          scope: String.t(),
          label: String.t(),
          utilization: float(),
          status: String.t() | nil,
          reset_at: DateTime.t() | nil,
          active?: boolean()
        }

  defstruct provider: nil,
            utilization: nil,
            status: nil,
            reset_at: nil,
            captured_at: nil,
            capture_source: nil,
            overage_status: nil,
            window_label: "primary",
            secondary_utilization: nil,
            secondary_status: nil,
            secondary_reset_at: nil,
            secondary_window_label: nil,
            burn_24h: nil,
            burn_24h_at: nil,
            scoped: []

  @doc """
  Project a persisted quota row onto the provider-neutral gate shape.

  Accepts an already normalized `#{inspect(__MODULE__)}`, `nil`, or a quota
  row whose struct has a registered `:quota_snapshot` source
  (`Arbiter.Quota.Gate.Snapshot.Source`; in-tree: `AnthropicQuota`,
  `CodexQuota`, `GoogleQuota`). Anything else → `nil` (fail open).

  `opts[:model]` is consulted only for an `"antigravity"` `GoogleQuota` row
  (bd-7qj58o AC4): it picks which of the four Antigravity sub-buckets
  ("Gemini Models" / "Claude and GPT models", each with a `5h` and a
  `weekly` window) the primary/secondary windows are read from — a
  `claude-*` / `gpt-*` model routes to "Claude and GPT models", a
  recognized Gemini model to "Gemini Models". Anything else (including
  `nil`, unresolved) doesn't match either group's exact-id lookup, so it
  falls through to the worst-of-both-groups reading — the conservative
  default when the model can't be identified. See
  `Arbiter.Quota.Gate.Snapshot.Google`.
  """
  @spec normalize(term(), keyword()) :: t() | nil
  def normalize(quota, opts \\ [])

  def normalize(nil, _opts), do: nil

  def normalize(%__MODULE__{} = snapshot, opts) do
    if Keyword.has_key?(opts, :model),
      do: %__MODULE__{
        snapshot
        | scoped: select_scoped(snapshot.scoped, Keyword.get(opts, :model))
      },
      else: snapshot
  end

  def normalize(%{__struct__: struct} = quota, opts) do
    case Extensions.fetch(:quota_snapshot, struct) do
      {:ok, source} -> quota |> source.normalize(opts) |> project_scoped(opts)
      :error -> nil
    end
  end

  def normalize(_other, _opts), do: nil

  # A source reports every scoped window of its row; the caller's `:model`
  # decides which ones the snapshot carries (see the moduledoc).
  defp project_scoped(%__MODULE__{scoped: [_ | _] = all} = snapshot, opts) do
    scoped =
      if Keyword.has_key?(opts, :model),
        do: select_scoped(all, Keyword.get(opts, :model)),
        else: []

    %__MODULE__{snapshot | scoped: scoped}
  end

  defp project_scoped(snapshot, _opts), do: snapshot

  defp select_scoped(scoped, model), do: Enum.filter(scoped, &scoped_applies?(&1, model))

  defp scoped_applies?(%{scope: scope, active?: active?}, model) do
    cond do
      not ModelFamily.known_scope?(scope) -> active?
      model == :unscoped -> false
      is_nil(model) -> true
      is_binary(model) -> ModelFamily.scope_matches?(scope, model)
      true -> false
    end
  end

  @doc """
  Parse a row's stored `scoped_limits` (string-keyed maps, see
  `Arbiter.Quota.OAuthUsage`) into `t:scoped/0` windows. An entry without a
  scope name or a numeric utilization is dropped.
  """
  @spec scoped_windows(term()) :: [scoped()]
  def scoped_windows(limits) when is_list(limits) do
    for %{"scope" => scope, "utilization" => used} = l <- limits,
        is_binary(scope) and scope != "",
        is_number(used) do
      %{
        scope: scope,
        label: "7d (#{scope})",
        utilization: used * 1.0,
        status: l["status"],
        reset_at: parse_datetime(l["reset_at"]),
        active?: l["is_active"] == true
      }
    end
  end

  def scoped_windows(_other), do: []

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  @doc """
  The snapshot as each of its long windows sees it: itself first (the base
  window on the `secondary_*` fields), then one copy per scoped window with
  those fields replaced by the scoped window's own and `scoped` emptied. A
  consumer that runs its long-window rules over every view evaluates a scoped
  window exactly as it does the base one.
  """
  @spec long_views(t()) :: [t()]
  def long_views(%__MODULE__{scoped: scoped} = snapshot) do
    [snapshot | Enum.map(scoped, &scoped_view(snapshot, &1))]
  end

  defp scoped_view(%__MODULE__{} = snapshot, window) do
    %__MODULE__{
      snapshot
      | secondary_utilization: window.utilization,
        secondary_status: window.status,
        secondary_reset_at: window.reset_at,
        secondary_window_label: window.label,
        scoped: []
    }
  end

  # Label a Codex window from its stored length (bd-7lkvb6) so
  # `Gate.window_seconds/2` can resolve it: Plus's 5h and weekly windows and
  # free's single 30-day window get the labels the built-in table knows; any
  # other length becomes "<n>m", which `window_seconds/2` also parses. No
  # stored length (a row captured before the columns existed) keeps `fallback`.
  @doc false
  @spec codex_window_label(integer() | nil, String.t()) :: String.t()
  def codex_window_label(minutes, _fallback) when minutes == 300, do: "5h"
  def codex_window_label(minutes, _fallback) when minutes == 10_080, do: "weekly"
  def codex_window_label(minutes, _fallback) when minutes == 43_200, do: "30d"

  def codex_window_label(minutes, _fallback) when is_integer(minutes) and minutes > 0,
    do: "#{minutes}m"

  def codex_window_label(_minutes, fallback), do: fallback

  # Codex and Google report 0-100 used-percents; the gate threshold is a 0-1
  # fraction (Anthropic's native unit).
  @doc false
  @spec fraction(term()) :: float() | nil
  def fraction(nil), do: nil
  def fraction(pct) when is_number(pct), do: pct / 100.0
  def fraction(_), do: nil
end
