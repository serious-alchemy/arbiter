defmodule Arbiter.Guardrails do
  @moduledoc """
  Per-subject guardrail profiles: trust tiers, their bundles, and the
  tighten-only floor over a resolved `SecurityPolicy`
  (`docs/design/guardrail-profiles.md` §3 and §7, G11).

  A **subject** is the `(provider, model)` pair a worker actually runs. A rule
  (`Arbiter.Guardrails.Rules`) assigns it one of four tiers, ordered
  `quarantine < probation < trusted < privileged`; each tier is a bundle
  (`bundle/1`): a `min_mode` floor, an `egress` ceiling, a `max_difficulty`,
  review and spend knobs.

  ## Composition (§7.2)

      policy  = SecurityPolicy.resolve(ws, dispatch_override, repo)  # unchanged
      profile = Guardrails.effective(subject, ws, repo)              # tier ⊓ rule overrides ⊓ ws cap ⊓ repo cap
      policy  = Guardrails.floor(policy, profile)                    # LAST, tighten-only

  `apply_to_policy/5` is that pipeline from the resolved policy on. The floor
  is last, so no layer — the per-dispatch override included — can go below it.

  ## Nothing configured, nothing changes

  `effective/4` is `nil` when no subject rule is configured, and `floor/2` of
  `nil` is the identity. The workspace `guardrails` block only ever **caps**
  what a rule assigned (§3.5), so a block with no rules behind it is inert (the
  doctor flags it). An install that never configures a rule behaves exactly as
  before this module existed. That is also why a subject matching no rule is
  `:quarantine` *only once rules exist*: the fail-safe default is for a
  guarded install, not a switch that flips an unconfigured one.

  ## Tier bundles (§3.2)

  The defaults are in `bundles/0`; `config :arbiter, :guardrail_tiers` overrides
  fields per tier (operator-owned, like `:worker_security_policy`):

      config :arbiter, :guardrail_tiers, %{probation: %{max_difficulty: 3}}

  `trusted` and `privileged` ship with `egress: :open`: the design has them at
  `allowlist`, but only "until the workspace opts in" (§9, G20), so the bundle
  does not force the allowlist before the operator has done a learn-mode week.

  ## Capability is not trust (§3.4)

  A tier says what must hold; `Arbiter.Agents.egress_confinement/2` and
  `Arbiter.Agents.write_confinement/2` say whether it *can* hold on this host.
  `enforceable/3` joins the two: a profile the adapter cannot meet is a
  recorded drop reason, never a weaker spawn.
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Profile
  alias Arbiter.Guardrails.Rules

  @tiers [:quarantine, :probation, :trusted, :privileged]
  @modes [:bypass, :auto, :strict]
  # Loosest first, like `SecurityPolicy.valid_egress_levels/0`.
  @egress_levels [:open, :allowlist, :none]
  @fallback_rank %{workspace: 0, record: 1, hold: 2}
  @cross_family_rank %{workspace: 0, required: 1}
  @reviewer_tier_rank %{economy: 0, standard: 1, premium: 2}

  @type tier :: Profile.tier()
  @type subject :: Rules.subject()

  @bundles %{
    quarantine: %Profile{
      tier: :quarantine,
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
      honour_safe_defaults_exclude: false
    },
    probation: %Profile{
      tier: :probation,
      min_mode: :bypass,
      egress: :allowlist,
      max_difficulty: 2,
      max_review_difficulty: 2,
      permissions: ["network:"],
      data_classes: [],
      review: %{
        cross_family: :required,
        same_family_fallback: :record,
        min_reviewer_tier: :economy
      },
      spend: %{action: :park, tokens: nil, wall_clock_s: nil},
      honour_safe_defaults_exclude: false
    },
    trusted: %Profile{
      tier: :trusted,
      min_mode: :bypass,
      egress: :open,
      max_difficulty: 4,
      max_review_difficulty: 5,
      permissions: ["network:", "tracker_write", "secrets:"],
      data_classes: ["phi_data"],
      review: %{
        cross_family: :workspace,
        same_family_fallback: :workspace,
        min_reviewer_tier: :economy
      },
      spend: %{action: :page, tokens: nil, wall_clock_s: nil},
      honour_safe_defaults_exclude: true
    },
    privileged: %Profile{
      tier: :privileged,
      min_mode: :bypass,
      egress: :open,
      max_difficulty: 5,
      max_review_difficulty: 5,
      permissions: ["network:", "tracker_write", "secrets:", "prod_read", "prod_ssh"],
      data_classes: ["phi_data"],
      review: %{
        cross_family: :workspace,
        same_family_fallback: :workspace,
        min_reviewer_tier: :economy
      },
      spend: %{action: :page, tokens: nil, wall_clock_s: nil},
      honour_safe_defaults_exclude: true
    }
  }

  # ---- vocabulary -----------------------------------------------------------

  @doc "The tiers, loosest-trust last: `quarantine < probation < trusted < privileged`."
  @spec tiers() :: [tier()]
  def tiers, do: @tiers

  @doc "A tier's position in `tiers/0` (higher is more trusted)."
  @spec tier_rank(tier()) :: non_neg_integer()
  def tier_rank(tier), do: Enum.find_index(@tiers, &(&1 == tier))

  @doc "Tightness of a security mode: `bypass` 0 < `auto` 1 < `strict` 2."
  @spec mode_rank(:bypass | :auto | :strict) :: non_neg_integer()
  def mode_rank(mode), do: Enum.find_index(@modes, &(&1 == mode))

  @doc "Tightness of an egress level: `open` 0 < `allowlist` 1 < `none` 2."
  @spec egress_rank(:open | :allowlist | :none) :: non_neg_integer()
  def egress_rank(egress), do: Enum.find_index(@egress_levels, &(&1 == egress))

  @doc "The code defaults for every tier, before `:guardrail_tiers` overrides."
  @spec bundles() :: %{tier() => Profile.t()}
  def bundles, do: @bundles

  @doc "The bundle for `tier`: the code default with the app-env override applied."
  @spec bundle(tier()) :: Profile.t()
  def bundle(tier) when tier in @tiers do
    overrides =
      :arbiter
      |> Application.get_env(:guardrail_tiers, %{})
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.get(Atom.to_string(tier), %{})

    override_bundle(Map.fetch!(@bundles, tier), overrides)
  end

  defp override_bundle(profile, overrides) when is_map(overrides) and map_size(overrides) > 0 do
    raw = Config.stringify(overrides)
    caps = Config.parse_caps(raw)

    profile
    |> put_if(:min_mode, caps[:min_mode])
    |> put_if(:egress, caps[:egress])
    |> put_if(:max_difficulty, caps[:max_difficulty])
    |> put_if(:max_review_difficulty, review_difficulty(Map.get(raw, "max_review_difficulty")))
    |> put_if(:permissions, string_list(Map.get(raw, "permissions")))
    |> put_if(:data_classes, string_list(Map.get(raw, "data_classes")))
    |> put_if(:honour_safe_defaults_exclude, bool(Map.get(raw, "honour_safe_defaults_exclude")))
    |> merge_map(:spend, caps[:spend])
    |> merge_map(:review, caps[:review])
  end

  defp override_bundle(profile, _), do: profile

  defp put_if(profile, _key, nil), do: profile
  defp put_if(profile, key, value), do: Map.put(profile, key, value)

  defp merge_map(profile, _key, nil), do: profile
  defp merge_map(profile, key, map), do: Map.update!(profile, key, &Map.merge(&1, map))

  defp review_difficulty(n) when is_integer(n) and n in 0..5, do: n
  defp review_difficulty(_), do: nil

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: nil

  defp bool(b) when is_boolean(b), do: b
  defp bool(_), do: nil

  @doc """
  True when any subject rule is configured: guardrails are on for this install
  (`effective/4` is non-`nil` for every subject). Dispatch-time withholding
  (G14, `Arbiter.Guardrails.Projection`) only applies to a guarded install.
  """
  @spec guarded?() :: boolean()
  def guarded?, do: Rules.all() != []

  # ---- subjects and effective profile --------------------------------------

  @doc """
  The subject for a `provider` and `model` (either may be `nil` for the model).
  `family` comes from `ModelFamily.classify/2`.

  `provider` is the harness, as the rules name it. The `gemini` *adapter* runs
  agy when that is the CLI installed here (`Arbiter.Quota.provider_code/1`), and
  agy's rules say `antigravity`: a dispatch that only knows the adapter type
  must be judged as the harness it actually spawns, not fall through to the
  `quarantine` default (G13 asks this question on every dispatch path).
  """
  @spec subject(atom() | String.t(), String.t() | nil) :: subject()
  def subject(provider, model) do
    provider = provider |> to_string() |> harness()
    family = ModelFamily.classify(provider, model).family

    %{
      provider: provider,
      model: model,
      family: if(family, do: Atom.to_string(family))
    }
  end

  defp harness("gemini"), do: Arbiter.Quota.provider_code("gemini") || "gemini"
  defp harness(provider), do: provider

  @doc """
  The effective profile for `subject` in `workspace` (and `repo`):
  `tier bundle ⊓ rule overrides ⊓ workspace cap ⊓ repo cap` (§3.5).

  `nil` when no subject rule is configured: guardrails are off and `floor/2`
  is the identity. Options: `:rules` (default `Arbiter.Guardrails.Rules.all/0`).
  """
  @spec effective(subject(), map() | nil, String.t() | nil, keyword()) :: Profile.t() | nil
  def effective(subject, workspace, repo \\ nil, opts \\ []) do
    case Keyword.get_lazy(opts, :rules, &Rules.all/0) do
      [] -> nil
      rules -> build(subject, workspace, repo, rules)
    end
  end

  defp build(subject, workspace, repo, rules) do
    rule =
      case Rules.match(rules, subject) do
        nil -> nil
        rule -> Map.merge(%{overrides: %{}, scope: nil, pinned: false}, rule)
      end

    tier = if rule, do: rule.tier, else: :quarantine
    base = bundle(tier)

    caps =
      workspace
      |> Config.block()
      |> Config.cap_entries(repo)
      |> Enum.map(&Config.parse_cap/1)
      |> Enum.filter(&Rules.matches?(&1.match, subject))

    {profile, capped_by} =
      Enum.reduce(caps, {apply_caps(base, rule_overrides(rule)), rule_layer(rule)}, fn cap,
                                                                                       {p, by} ->
        capped = apply_caps(p, cap.caps)
        {capped, if(capped == p, do: by, else: by ++ [:workspace])}
      end)

    scope = rule && rule.scope

    %{
      profile
      | scope: scope,
        in_scope?: Rules.in_scope?(scope, workspace, repo),
        capped_by: Enum.uniq(capped_by)
    }
  end

  defp rule_overrides(nil), do: %{}
  defp rule_overrides(rule), do: rule.overrides

  defp rule_layer(%{overrides: o}) when map_size(o) > 0, do: [:rule]
  defp rule_layer(_), do: []

  # Fold one cap map into a profile, most restrictive field by field (§3.5).
  # A `max_tier` below the profile's tier lowers the tier and tightens the
  # profile to that tier's bundle too; a higher one changes nothing.
  defp apply_caps(profile, caps) when map_size(caps) == 0, do: profile

  defp apply_caps(profile, caps) do
    profile
    |> cap_tier(caps[:max_tier])
    |> cap_mode(caps[:min_mode])
    |> cap_egress(caps[:egress])
    |> cap_difficulty(caps[:max_difficulty])
    |> cap_spend(caps[:spend])
    |> cap_review(caps[:review])
  end

  defp cap_tier(profile, nil), do: profile

  defp cap_tier(profile, max_tier) do
    if tier_rank(max_tier) < tier_rank(profile.tier),
      do: %{tighten(profile, bundle(max_tier)) | tier: max_tier},
      else: profile
  end

  defp cap_mode(profile, nil), do: profile
  defp cap_mode(p, mode), do: %{p | min_mode: tighter_mode(p.min_mode, mode)}

  defp cap_egress(profile, nil), do: profile
  defp cap_egress(p, egress), do: %{p | egress: tighter_egress(p.egress, egress)}

  defp cap_difficulty(profile, nil), do: profile
  defp cap_difficulty(p, d), do: %{p | max_difficulty: min(p.max_difficulty, d)}

  defp cap_spend(profile, nil), do: profile
  defp cap_spend(p, spend), do: %{p | spend: tighter_spend(p.spend, spend)}

  defp cap_review(profile, nil), do: profile
  defp cap_review(p, review), do: %{p | review: tighter_review(p.review, review)}

  # `a ⊓ b` over two whole profiles (a tier lowered by a cap).
  defp tighten(%Profile{} = a, %Profile{} = b) do
    %{
      a
      | min_mode: tighter_mode(a.min_mode, b.min_mode),
        egress: tighter_egress(a.egress, b.egress),
        max_difficulty: min(a.max_difficulty, b.max_difficulty),
        max_review_difficulty: min(a.max_review_difficulty, b.max_review_difficulty),
        permissions: Enum.filter(a.permissions, &(&1 in b.permissions)),
        data_classes: Enum.filter(a.data_classes, &(&1 in b.data_classes)),
        review: tighter_review(a.review, b.review),
        spend: tighter_spend(a.spend, b.spend),
        honour_safe_defaults_exclude:
          a.honour_safe_defaults_exclude and b.honour_safe_defaults_exclude
    }
  end

  defp tighter_mode(a, b), do: Enum.max_by([a, b], &mode_rank/1)
  defp tighter_egress(a, b), do: Enum.max_by([a, b], &egress_rank/1)

  defp tighter_spend(a, b) do
    %{
      action: if(:park in [a[:action], b[:action]], do: :park, else: b[:action] || a[:action]),
      tokens: min_present(a[:tokens], b[:tokens]),
      wall_clock_s: min_present(a[:wall_clock_s], b[:wall_clock_s])
    }
  end

  defp min_present(nil, b), do: b
  defp min_present(a, nil), do: a
  defp min_present(a, b), do: min(a, b)

  defp tighter_review(a, b) do
    %{
      cross_family: strictest(a[:cross_family], b[:cross_family], @cross_family_rank),
      same_family_fallback:
        strictest(a[:same_family_fallback], b[:same_family_fallback], @fallback_rank),
      min_reviewer_tier:
        strictest(a[:min_reviewer_tier], b[:min_reviewer_tier], @reviewer_tier_rank)
    }
  end

  defp strictest(nil, b, _rank), do: b
  defp strictest(a, nil, _rank), do: a
  defp strictest(a, b, rank), do: Enum.max_by([a, b], &Map.fetch!(rank, &1))

  # ---- the floor -------------------------------------------------------------

  @doc """
  The tighten-only floor over a resolved `policy` (§7.2). `mode` becomes the
  higher of the policy's and `profile.min_mode`; `sandbox.egress` the tighter of
  the policy's and `profile.egress`; `safe_defaults_exclude` is emptied unless
  the tier honours it. Everything else is untouched. `nil` profile: identity.

  It never loosens: `loosenings(floor(policy, profile), policy) == []` for
  every policy and profile (property-tested).
  """
  @spec floor(SecurityPolicy.t(), Profile.t() | nil) :: SecurityPolicy.t()
  def floor(%SecurityPolicy{} = policy, nil), do: policy

  def floor(%SecurityPolicy{permissions: perms, sandbox: sandbox} = policy, %Profile{} = profile) do
    perms =
      if profile.honour_safe_defaults_exclude do
        perms
      else
        %{
          perms
          | safe_defaults_exclude: [],
            safe_defaults: SecurityPolicy.safe_default_categories()
        }
      end

    %SecurityPolicy{
      policy
      | permissions: %{perms | mode: tighter_mode(perms.mode, profile.min_mode)},
        sandbox: %{
          sandbox
          | egress: tighter_egress(Map.get(sandbox, :egress, :open), profile.egress)
        }
    }
  end

  @doc """
  `floor/2` of `effective/4`, for a spawn: the resolved `policy` for `provider`
  running `model` in `workspace`. Options: `:repo`, `:rules`.
  """
  @spec apply_to_policy(
          SecurityPolicy.t(),
          map() | nil,
          atom() | String.t(),
          String.t() | nil,
          keyword()
        ) ::
          SecurityPolicy.t()
  def apply_to_policy(%SecurityPolicy{} = policy, workspace, provider, model, opts \\ []) do
    profile =
      effective(
        subject(provider, model),
        workspace,
        Keyword.get(opts, :repo),
        Keyword.take(opts, [:rules])
      )

    floor(policy, profile)
  end

  @doc """
  Where the effective mode came from, given `SecurityPolicy.mode_source/3`'s
  answer: `:guardrail_floor` when the profile raised it (§7.2).
  """
  @spec mode_source({atom(), atom()}, Profile.t() | nil) :: {atom(), atom()}
  def mode_source(source, nil), do: source

  def mode_source({mode, _layer} = source, %Profile{min_mode: floor_mode}) do
    if mode_rank(floor_mode) > mode_rank(mode), do: {floor_mode, :guardrail_floor}, else: source
  end

  # ---- loosening ---------------------------------------------------------------

  @doc """
  What `new` loosens relative to `old`, as human-readable reasons; `[]` when
  `new` is at least as tight on every axis. Used by `floor/2`'s property test
  and by `Arbiter.Guardrails.Authority` to decide whether a config edit is a
  loosening (operator-only) or a tightening (the coordinator may do it).
  """
  @spec loosenings(SecurityPolicy.t(), SecurityPolicy.t()) :: [String.t()]
  def loosenings(%SecurityPolicy{} = new, %SecurityPolicy{} = old) do
    sb_new = new.sandbox
    sb_old = old.sandbox

    [
      lower(mode_rank(new.permissions.mode), mode_rank(old.permissions.mode), "permissions.mode"),
      lower(
        egress_rank(Map.get(sb_new, :egress, :open)),
        egress_rank(Map.get(sb_old, :egress, :open)),
        "sandbox.egress"
      ),
      flipped(sb_old.enabled, sb_new.enabled, "sandbox.enabled", true),
      flipped(old.sandbox.network, new.sandbox.network, "sandbox.network", false),
      filesystem(sb_old.filesystem, sb_new.filesystem),
      lower(backend_rank(sb_new), backend_rank(sb_old), "sandbox.backend"),
      removed(old.permissions.deny, new.permissions.deny, "permissions.deny"),
      added(old.permissions.allow, new.permissions.allow, "permissions.allow"),
      added(
        old.permissions.safe_defaults_exclude,
        new.permissions.safe_defaults_exclude,
        "permissions.safe_defaults_exclude"
      ),
      added(
        Map.get(sb_old, :writable_paths, []),
        Map.get(sb_new, :writable_paths, []),
        "sandbox.writable_paths"
      ),
      added(
        Map.get(sb_old, :allow_hosts, []),
        Map.get(sb_new, :allow_hosts, []),
        "sandbox.allow_hosts"
      ),
      added(
        Map.get(sb_old, :egress_tunnels, []),
        Map.get(sb_new, :egress_tunnels, []),
        "sandbox.egress_tunnels"
      )
    ]
    |> List.flatten()
  end

  defp backend_rank(sandbox) do
    Enum.find_index(
      SecurityPolicy.valid_sandbox_backends(),
      &(&1 == Map.get(sandbox, :backend, :bwrap))
    )
  end

  defp lower(new_rank, old_rank, field) when new_rank < old_rank,
    do: ["#{field} is looser"]

  defp lower(_, _, _), do: []

  # `tight` is the value that is tighter; a move away from it is a loosening.
  defp flipped(old, new, field, tight) when old == tight and new != tight,
    do: ["#{field} is looser"]

  defp flipped(_, _, _, _), do: []

  defp filesystem(:worktree, :none), do: ["sandbox.filesystem is looser"]
  defp filesystem(_, _), do: []

  defp removed(old, new, field) do
    case old -- new do
      [] -> []
      gone -> ["#{field} drops #{Enum.map_join(gone, ", ", &inspect/1)}"]
    end
  end

  defp added(old, new, field) do
    case new -- old do
      [] -> []
      extra -> ["#{field} adds #{Enum.map_join(extra, ", ", &inspect/1)}"]
    end
  end

  # ---- capability ----------------------------------------------------------------

  @doc """
  Whether `adapter` can meet `profile` under `policy` on this host (§3.4):
  `:ok`, or `{:error, reason}` with the drop reason the routing layer records:

    * `:write_confinement_none` — the (floored) mode is `:strict` and the
      adapter cannot confine writes;
    * `:egress_unenforceable` — the (floored) egress is not `:open` and the
      adapter has no egress confinement here.

  Pass the already-floored `policy`. A `nil` profile is always `:ok`.
  """
  @spec enforceable(module(), SecurityPolicy.t(), Profile.t() | nil) ::
          :ok | {:error, :write_confinement_none | :egress_unenforceable}
  def enforceable(_adapter, _policy, nil), do: :ok

  def enforceable(adapter, %SecurityPolicy{} = policy, %Profile{}) do
    cond do
      policy.permissions.mode == :strict and Agents.write_confinement(adapter, policy) == :none ->
        {:error, :write_confinement_none}

      SecurityPolicy.egress(policy) != :open and
          Agents.egress_confinement(adapter, policy) == :none ->
        {:error, :egress_unenforceable}

      true ->
        :ok
    end
  end
end
