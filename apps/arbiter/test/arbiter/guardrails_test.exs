defmodule Arbiter.GuardrailsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Profile

  @modes [:bypass, :auto, :strict]
  @egress [:open, :allowlist, :none]
  @tiers [:quarantine, :probation, :trusted, :privileged]

  @rules [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "antigravity", family: "anthropic"}, tier: :probation},
    %{
      match: %{provider: "antigravity", model: "gemini-*-flash-*"},
      tier: :quarantine,
      scope: %{"default" => ["arbiter"]}
    },
    %{match: %{provider: "antigravity"}, tier: :probation},
    %{match: %{provider: "codex"}, tier: :quarantine}
  ]

  defp ws(guardrails \\ nil, extra \\ %{}) do
    config = if guardrails, do: Map.put(extra, "guardrails", guardrails), else: extra
    %{id: "ws-1", name: "default", prefix: "bd", config: config}
  end

  defp effective(provider, model, workspace, repo \\ nil, rules \\ @rules) do
    Guardrails.effective(Guardrails.subject(provider, model), workspace, repo, rules: rules)
  end

  describe "tier bundles" do
    test "tiers are ordered quarantine < probation < trusted < privileged" do
      assert Guardrails.tiers() == @tiers
      assert Guardrails.tier_rank(:quarantine) < Guardrails.tier_rank(:privileged)
    end

    test "the bundles tighten monotonically down the tier ladder" do
      bundles = Enum.map(@tiers, &Guardrails.bundle/1)

      for {lower, higher} <- Enum.zip(bundles, tl(bundles)) do
        assert Guardrails.mode_rank(lower.min_mode) >= Guardrails.mode_rank(higher.min_mode)
        assert Guardrails.egress_rank(lower.egress) >= Guardrails.egress_rank(higher.egress)
        assert lower.max_difficulty <= higher.max_difficulty
      end
    end

    test "quarantine is strict, egress none, D1" do
      assert %Profile{min_mode: :strict, egress: :none, max_difficulty: 1} =
               Guardrails.bundle(:quarantine)
    end

    test "app env overrides a bundle field" do
      Application.put_env(:arbiter, :guardrail_tiers, %{probation: %{max_difficulty: 3}})
      on_exit(fn -> Application.delete_env(:arbiter, :guardrail_tiers) end)

      assert Guardrails.bundle(:probation).max_difficulty == 3
      assert Guardrails.bundle(:quarantine).max_difficulty == 1
    end
  end

  describe "subject matching" do
    test "an unmatched subject is quarantine, the fail-safe default" do
      assert %Profile{tier: :quarantine} = effective("grok", "grok-4", ws())
    end

    test "model glob beats family beats provider" do
      assert %Profile{tier: :quarantine} = effective("antigravity", "gemini-3.8-flash-low", ws())

      assert %Profile{tier: :probation} =
               effective("antigravity", "claude-opus-4-6-thinking", ws())

      assert %Profile{tier: :probation} = effective("antigravity", "gemini-3.1-pro-high", ws())
      assert %Profile{tier: :privileged} = effective("claude", "claude-opus-4-6", ws())
    end

    test "scope keeps a subject to the workspaces and repos its rule lists" do
      assert %Profile{in_scope?: true} =
               effective("antigravity", "gemini-3.8-flash-low", ws(), "arbiter")

      assert %Profile{in_scope?: false} =
               effective("antigravity", "gemini-3.8-flash-low", ws(), "mesaana")

      assert %Profile{in_scope?: false} =
               effective(
                 "antigravity",
                 "gemini-3.8-flash-low",
                 %{ws() | name: "emricare"},
                 "arbiter"
               )
    end
  end

  describe "effective/3 with no guardrails configured" do
    test "is nil, so floor/2 is a no-op" do
      assert Guardrails.effective(Guardrails.subject("claude", "x"), ws(), nil, rules: []) == nil
      assert Guardrails.effective(Guardrails.subject("claude", "x"), nil, nil, rules: []) == nil
    end

    test "a workspace block alone, with no subject rules, stays inert" do
      block = %{"subjects" => [%{"match" => %{"provider" => "claude"}, "max_tier" => "probation"}]}
      assert Guardrails.effective(Guardrails.subject("claude", nil), ws(block), nil, rules: []) == nil
    end
  end

  describe "workspace and repo caps (§3.5)" do
    test "a workspace cap lowers the tier, never raises it" do
      block = %{"subjects" => [%{"match" => %{"provider" => "claude"}, "max_tier" => "probation"}]}
      assert %Profile{tier: :probation} = effective("claude", "m", ws(block))

      raising = %{"subjects" => [%{"match" => %{"provider" => "codex"}, "max_tier" => "privileged"}]}
      assert %Profile{tier: :quarantine} = effective("codex", "m", ws(raising))
    end

    test "caps combine as the most restrictive, field by field" do
      block = %{
        "subjects" => [
          %{
            "match" => %{"provider" => "claude"},
            "min_mode" => "strict",
            "egress" => "none",
            "max_difficulty" => 2
          }
        ],
        "repos" => %{
          "tonic" => %{"subjects" => [%{"match" => %{"provider" => "claude"}, "max_difficulty" => 1}]}
        }
      }

      assert %Profile{min_mode: :strict, egress: :none, max_difficulty: 2, tier: :privileged} =
               effective("claude", "m", ws(block))

      assert %Profile{max_difficulty: 1} = effective("claude", "m", ws(block), "tonic")
    end

    test "a cap that does not match the subject changes nothing" do
      block = %{"subjects" => [%{"match" => %{"provider" => "codex"}, "min_mode" => "strict"}]}
      assert %Profile{min_mode: :bypass} = effective("claude", "m", ws(block))
    end
  end

  describe "floor/2" do
    test "raises mode and lowers egress to the profile, never the other way" do
      policy = SecurityPolicy.base()
      profile = Guardrails.bundle(:quarantine)

      floored = Guardrails.floor(policy, profile)
      assert floored.permissions.mode == :strict
      assert floored.sandbox.egress == :none
    end

    test "leaves a stricter policy alone" do
      policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"mode" => "strict"},
          "sandbox" => %{"egress" => "none"}
        })

      floored = Guardrails.floor(policy, Guardrails.bundle(:privileged))
      assert floored.permissions.mode == :strict
      assert floored.sandbox.egress == :none
    end

    test "a nil profile is the identity" do
      policy = SecurityPolicy.base()
      assert Guardrails.floor(policy, nil) == policy
    end

    test "safe_defaults_exclude is ignored for low tiers and honoured for high ones" do
      policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"safe_defaults_exclude" => ["no_gh_publish"]}
        })

      assert policy.permissions.safe_defaults_exclude == [:no_gh_publish]

      low = Guardrails.floor(policy, Guardrails.bundle(:probation))
      assert low.permissions.safe_defaults_exclude == []
      assert :no_gh_publish in low.permissions.safe_defaults

      high = Guardrails.floor(policy, Guardrails.bundle(:trusted))
      assert high.permissions.safe_defaults_exclude == [:no_gh_publish]
    end

    test "only mode, egress and safe_defaults move; everything else is untouched" do
      policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"allow" => ["Bash(ls:*)"], "deny" => ["Bash(rm:*)"]},
          "sandbox" => %{"writable_paths" => ["/tmp/x"], "allow_hosts" => ["repo.hex.pm:443"]}
        })

      floored = Guardrails.floor(policy, Guardrails.bundle(:quarantine))
      assert floored.permissions.allow == policy.permissions.allow
      assert floored.permissions.deny == policy.permissions.deny
      assert floored.sandbox.writable_paths == policy.sandbox.writable_paths
      assert floored.sandbox.allow_hosts == policy.sandbox.allow_hosts
    end
  end

  describe "a guardrail can only tighten (property)" do
    defp policy_gen do
      gen all(
            mode <- member_of(@modes),
            egress <- member_of(@egress),
            network <- boolean(),
            exclude <- member_of([[], ["no_gh_publish"], ["no_public_upload", "no_gh_publish"]]),
            allow <- member_of([[], ["Bash(ls:*)"]]),
            hosts <- member_of([[], ["repo.hex.pm:443"]])
          ) do
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{
            "mode" => Atom.to_string(mode),
            "safe_defaults_exclude" => exclude,
            "allow" => allow
          },
          "sandbox" => %{
            "egress" => Atom.to_string(egress),
            "network" => network,
            "allow_hosts" => hosts
          }
        })
      end
    end

    defp profile_gen do
      gen all(
            tier <- member_of(@tiers),
            mode <- member_of(@modes),
            egress <- member_of(@egress)
          ) do
        %{Guardrails.bundle(tier) | min_mode: mode, egress: egress}
      end
    end

    property "floor/2 never loosens the resolved policy" do
      check all(policy <- policy_gen(), profile <- profile_gen()) do
        floored = Guardrails.floor(policy, profile)
        assert Guardrails.loosenings(floored, policy) == []
      end
    end

    property "floor/2 is idempotent" do
      check all(policy <- policy_gen(), profile <- profile_gen()) do
        once = Guardrails.floor(policy, profile)
        assert Guardrails.floor(once, profile) == once
      end
    end

    property "floor/2 meets the profile: mode at least min_mode, egress at most egress" do
      check all(policy <- policy_gen(), profile <- profile_gen()) do
        floored = Guardrails.floor(policy, profile)
        assert Guardrails.mode_rank(floored.permissions.mode) >= Guardrails.mode_rank(profile.min_mode)
        assert Guardrails.egress_rank(floored.sandbox.egress) >= Guardrails.egress_rank(profile.egress)
      end
    end

    property "a workspace cap never produces a looser profile than the installation tier" do
      check all(
              tier <- member_of(@tiers),
              cap_tier <- member_of(@tiers),
              mode <- member_of(@modes),
              egress <- member_of(@egress)
            ) do
        rules = [%{match: %{provider: "claude"}, tier: tier}]

        block = %{
          "subjects" => [
            %{
              "match" => %{"provider" => "claude"},
              "max_tier" => Atom.to_string(cap_tier),
              "min_mode" => Atom.to_string(mode),
              "egress" => Atom.to_string(egress)
            }
          ]
        }

        base = effective("claude", "m", ws(), nil, rules)
        capped = effective("claude", "m", ws(block), nil, rules)

        assert Guardrails.tier_rank(capped.tier) <= Guardrails.tier_rank(base.tier)
        assert Guardrails.mode_rank(capped.min_mode) >= Guardrails.mode_rank(base.min_mode)
        assert Guardrails.egress_rank(capped.egress) >= Guardrails.egress_rank(base.egress)
        assert capped.max_difficulty <= base.max_difficulty
      end
    end
  end

  describe "mode_source/3" do
    test "names the guardrail floor when it raised the mode" do
      profile = Guardrails.bundle(:quarantine)
      assert Guardrails.mode_source({:bypass, :workspace}, profile) == {:strict, :guardrail_floor}
      assert Guardrails.mode_source({:strict, :repo}, profile) == {:strict, :repo}
      assert Guardrails.mode_source({:bypass, :workspace}, nil) == {:bypass, :workspace}
    end
  end

  describe "apply_to_policy/4 (the wiring entry point)" do
    test "is the identity when nothing is configured" do
      policy = SecurityPolicy.base()
      assert Guardrails.apply_to_policy(policy, ws(), "claude", "m", rules: []) == policy
    end

    test "floors by the subject's tier when rules exist" do
      policy = SecurityPolicy.base()
      floored = Guardrails.apply_to_policy(policy, ws(), "codex", "gpt-5", rules: @rules)
      assert floored.permissions.mode == :strict
    end
  end

  describe "egress_confinement/1 and enforceable/3 (capability is not trust, §3.4)" do
    alias Arbiter.Agents
    alias Arbiter.Agents.{Claude, Codex, Gemini}

    setup do
      on_exit(fn -> Application.delete_env(:arbiter, :worker_jail_network_available) end)
    end

    test "an adapter that omits the callback confines nothing" do
      assert Agents.egress_confinement(Codex, SecurityPolicy.base()) == :none
    end

    test "claude has no egress confinement under the default bwrap backend" do
      assert Claude.egress_confinement(SecurityPolicy.base()) == :none
      assert Agents.egress_confinement(Claude, SecurityPolicy.base()) == :none
    end

    test "agy cannot confine egress when the host cannot build the network jail" do
      Application.put_env(:arbiter, :worker_jail_network_available, false)
      assert Gemini.egress_confinement(SecurityPolicy.base()) == :none
    end

    test "a quarantine floor makes codex unenforceable (no write confinement)" do
      profile = Guardrails.bundle(:quarantine)
      policy = Guardrails.floor(SecurityPolicy.base(), profile)

      assert Guardrails.enforceable(Codex, policy, profile) == {:error, :write_confinement_none}
    end

    test "an egress ceiling the adapter cannot enforce is egress_unenforceable, not a weaker spawn" do
      profile = %{Guardrails.bundle(:probation) | egress: :allowlist}
      policy = Guardrails.floor(SecurityPolicy.base(), profile)

      assert Guardrails.enforceable(Claude, policy, profile) == {:error, :egress_unenforceable}
    end

    test "an open egress ceiling and a bypass floor need nothing from the adapter" do
      profile = Guardrails.bundle(:privileged)
      policy = Guardrails.floor(SecurityPolicy.base(), profile)

      assert Guardrails.enforceable(Claude, policy, profile) == :ok
      assert Guardrails.enforceable(Codex, policy, profile) == :ok
      assert Guardrails.enforceable(Codex, SecurityPolicy.base(), nil) == :ok
    end
  end
end
