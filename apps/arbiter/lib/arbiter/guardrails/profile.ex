defmodule Arbiter.Guardrails.Profile do
  @moduledoc """
  A subject's effective guardrail profile (`docs/design/guardrail-profiles.md`
  §3.2, §3.3): a tier bundle after the subject rule, the workspace cap and the
  repo cap have been folded in.

    * `tier` — `:quarantine | :probation | :trusted | :privileged`.
    * `min_mode` — the floor over the resolved `SecurityPolicy` mode
      (`:bypass < :auto < :strict`).
    * `egress` — the ceiling over `sandbox.egress` (`:none < :allowlist < :open`).
    * `max_difficulty` — hard ceiling on the ticket difficulty for implementer
      roles (1..5).
    * `max_review_difficulty` — the same for reviewer roles; `0` means the
      subject may not review.
    * `permissions` — the ticket-permission vocabulary it may ever hold
      (`"network:"` is a prefix). Consumed by G12/G13.
    * `data_classes` — data classes it may see, subject to an account agreement.
    * `review` — inputs to `ReviewerRouting` (§3.3), not a selector.
    * `spend` — the caps G19 enforces: `action` is `:park | :page`,
      `tokens` / `wall_clock_s` are `nil` until calibrated.
    * `honour_safe_defaults_exclude` — whether `safe_defaults_exclude` is
      honoured; low tiers always get the full deny set.
    * `scope` — `nil` (any attached workspace) or `%{workspace => [repo]}`
      (an empty repo list means every repo of that workspace).
    * `in_scope?` — whether the workspace and repo this profile was resolved
      for are inside `scope`.
    * `capped_by` — which layers lowered it (`:rule`, `:workspace`, `:repo`).
  """

  @enforce_keys [:tier]
  defstruct tier: :quarantine,
            min_mode: :strict,
            egress: :none,
            max_difficulty: 1,
            max_review_difficulty: 0,
            permissions: [],
            data_classes: [],
            review: %{
              cross_family: :required,
              same_family_fallback: :hold,
              min_reviewer_tier: :premium
            },
            spend: %{action: :park, tokens: nil, wall_clock_s: nil},
            honour_safe_defaults_exclude: false,
            scope: nil,
            in_scope?: true,
            capped_by: []

  @type tier :: :quarantine | :probation | :trusted | :privileged

  @type t :: %__MODULE__{
          tier: tier(),
          min_mode: :bypass | :auto | :strict,
          egress: :open | :allowlist | :none,
          max_difficulty: 1..5,
          max_review_difficulty: 0..5,
          permissions: [String.t()],
          data_classes: [String.t()],
          review: map(),
          spend: map(),
          honour_safe_defaults_exclude: boolean(),
          scope: nil | %{String.t() => [String.t()]},
          in_scope?: boolean(),
          capped_by: [atom()]
        }
end
