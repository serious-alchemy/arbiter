defmodule Arbiter.Guardrails.AuthorityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.Authority
  alias Arbiter.MCP.Scope

  defp sec(block), do: %{"agent" => %{"security" => block}}
  defp loosenings(old, new), do: Authority.config_loosenings(old, new)

  describe "agent.security, judged on the resolved policy" do
    test "a tightening is not a loosening" do
      assert loosenings(%{}, sec(%{"permissions" => %{"mode" => "strict"}})) == []
      assert loosenings(%{}, sec(%{"sandbox" => %{"egress" => "none"}})) == []
      assert loosenings(%{}, sec(%{"permissions" => %{"deny" => ["Bash(rm:*)"]}})) == []
      assert loosenings(%{}, sec(%{"sandbox" => %{"network" => false}})) == []
    end

    test "no change, and unrelated config, is not a loosening" do
      assert loosenings(sec(%{"permissions" => %{"mode" => "strict"}}), sec(%{"permissions" => %{"mode" => "strict"}})) == []
      assert loosenings(%{}, %{"merge" => %{"auto_merge" => true}}) == []
      assert loosenings(nil, nil) == []
    end

    test "lowering the mode is a loosening" do
      strict = sec(%{"permissions" => %{"mode" => "strict"}})
      assert [msg] = loosenings(strict, sec(%{"permissions" => %{"mode" => "bypass"}}))
      assert msg =~ "permissions.mode"
      assert [_] = loosenings(strict, %{})
    end

    test "loosening egress, the sandbox or the deny set is a loosening" do
      egress = sec(%{"sandbox" => %{"egress" => "none"}})
      assert [_] = loosenings(egress, sec(%{"sandbox" => %{"egress" => "open"}}))
      assert [_] = loosenings(egress, %{})

      deny = sec(%{"permissions" => %{"deny" => ["Bash(rm:*)"]}})
      assert [msg] = loosenings(deny, %{})
      assert msg =~ "permissions.deny"

      assert [_] = loosenings(%{}, sec(%{"permissions" => %{"allow" => ["Bash(curl:*)"]}}))
      assert [_] = loosenings(%{}, sec(%{"permissions" => %{"safe_defaults_exclude" => ["no_gh_publish"]}}))
      assert [_] = loosenings(%{}, sec(%{"sandbox" => %{"enabled" => false}}))
      assert [_] = loosenings(%{}, sec(%{"sandbox" => %{"writable_paths" => ["/tmp/x"]}}))
      assert [_] = loosenings(%{}, sec(%{"sandbox" => %{"allow_hosts" => ["example.com:443"]}}))
    end

    test "a per-repo layer is judged too" do
      old = sec(%{"permissions" => %{"mode" => "strict"}, "repos" => %{"tonic" => %{}}})
      new = sec(%{"permissions" => %{"mode" => "strict"}, "repos" => %{"tonic" => %{"permissions" => %{"mode" => "bypass"}}}})
      # mode is replaced by the repo layer, so the repo resolves looser
      assert [msg] = loosenings(old, new)
      assert msg =~ "tonic"
    end

    test "the deprecated alias paths cannot sneak a loosening past" do
      strict = sec(%{"permissions" => %{"mode" => "strict"}})
      assert [_] = loosenings(strict, %{"security" => %{"mode" => "bypass"}})
    end
  end

  describe "guardrails block" do
    @cap %{"match" => %{"provider" => "antigravity"}, "max_tier" => "probation", "max_difficulty" => 2}

    defp gr(block), do: %{"guardrails" => block}

    test "adding or tightening a cap is not a loosening" do
      assert loosenings(%{}, gr(%{"subjects" => [@cap]})) == []

      assert loosenings(
               gr(%{"subjects" => [@cap]}),
               gr(%{"subjects" => [%{@cap | "max_tier" => "quarantine"} |> Map.put("egress", "none")]})
             ) == []
    end

    test "removing or loosening a cap is a loosening" do
      assert [msg] = loosenings(gr(%{"subjects" => [@cap]}), gr(%{"subjects" => []}))
      assert msg =~ "removed"

      assert [_] = loosenings(gr(%{"subjects" => [@cap]}), gr(%{"subjects" => [%{@cap | "max_tier" => "trusted"}]}))
      assert [_] = loosenings(gr(%{"subjects" => [@cap]}), gr(%{"subjects" => [%{@cap | "max_difficulty" => 4}]}))
      assert [_] = loosenings(gr(%{"subjects" => [@cap]}), gr(%{"subjects" => [Map.delete(@cap, "max_difficulty")]}))
      assert [_] = loosenings(gr(%{"subjects" => [@cap]}), %{})
    end

    test "repo caps are judged per repo" do
      with_repo = fn tier -> gr(%{"repos" => %{"r" => %{"subjects" => [%{@cap | "max_tier" => tier}]}}}) end
      assert loosenings(with_repo.("probation"), with_repo.("quarantine")) == []
      assert [msg] = loosenings(with_repo.("probation"), with_repo.("trusted"))
      assert msg =~ "guardrails.repos.r"
    end

    test "a new binding, a lowered grant_by or min_tier, or more reach is a loosening" do
      old = gr(%{"bindings" => %{"prod_read" => %{"grant_by" => "operator", "min_tier" => "privileged", "hosts" => ["a.internal:22"]}}})

      assert [_] = loosenings(%{}, gr(%{"bindings" => %{"prod_read" => %{}}}))
      assert [_] = loosenings(old, gr(%{"bindings" => %{"prod_read" => %{"grant_by" => "coordinator", "min_tier" => "privileged", "hosts" => ["a.internal:22"]}}}))
      assert [_] = loosenings(old, gr(%{"bindings" => %{"prod_read" => %{"grant_by" => "operator", "min_tier" => "trusted", "hosts" => ["a.internal:22"]}}}))
      assert [_] = loosenings(old, gr(%{"bindings" => %{"prod_read" => %{"grant_by" => "operator", "min_tier" => "privileged", "hosts" => ["a.internal:22", "b.internal:22"]}}}))
    end

    test "dropping a binding or tightening one is not a loosening" do
      old = gr(%{"bindings" => %{"prod_read" => %{"grant_by" => "coordinator", "min_tier" => "trusted"}}})
      assert loosenings(old, gr(%{"bindings" => %{}})) == []
      assert loosenings(old, gr(%{"bindings" => %{"prod_read" => %{"grant_by" => "operator", "min_tier" => "privileged"}}})) == []
    end

    test "default permissions: adding is a loosening, removing is not" do
      assert [_] = loosenings(%{}, gr(%{"defaults" => %{"permissions" => ["prod_read"]}}))
      assert loosenings(gr(%{"defaults" => %{"permissions" => ["prod_read"]}}), gr(%{"defaults" => %{"permissions" => []}})) == []
      assert [_] = loosenings(%{}, gr(%{"repos" => %{"r" => %{"defaults" => %{"permissions" => ["phi_data"]}}}}))
    end
  end

  describe "subject rules" do
    @rule %{tier: :probation, scope: %{"default" => ["arbiter"]}, overrides: %{max_difficulty: 2}, pinned: false}

    test "demoting, narrowing and tightening an override are not loosenings" do
      assert Authority.rule_loosenings(@rule, %{@rule | tier: :quarantine}) == []
      assert Authority.rule_loosenings(@rule, %{@rule | scope: %{"default" => ["arbiter"]}}) == []
      assert Authority.rule_loosenings(@rule, %{@rule | overrides: %{max_difficulty: 1, egress: :none}}) == []
      assert Authority.rule_loosenings(@rule, %{@rule | pinned: true}) == []
    end

    test "raising the tier, widening the scope, loosening an override or unpinning are loosenings" do
      assert [_] = Authority.rule_loosenings(@rule, %{@rule | tier: :trusted})
      assert [_] = Authority.rule_loosenings(@rule, %{@rule | scope: nil})
      assert [_] = Authority.rule_loosenings(@rule, %{@rule | scope: %{"default" => ["arbiter", "other"]}})
      assert [_] = Authority.rule_loosenings(@rule, %{@rule | scope: %{"default" => ["arbiter"], "emricare" => []}})
      assert [_] = Authority.rule_loosenings(@rule, %{@rule | overrides: %{max_difficulty: 4}})
      assert [_] = Authority.rule_loosenings(@rule, %{@rule | overrides: %{}})
      assert [_] = Authority.rule_loosenings(%{@rule | pinned: true}, @rule)
    end

    test "a new rule is measured against the quarantine default" do
      assert Authority.rule_loosenings(nil, %{tier: :quarantine, scope: nil, overrides: %{}, pinned: false}) == []
      assert [_] = Authority.rule_loosenings(nil, %{tier: :probation, scope: nil, overrides: %{}, pinned: false})
    end

    test "deleting a rule is a loosening unless it was already quarantine" do
      assert [_] = Authority.rule_loosenings(@rule, nil)
      assert Authority.rule_loosenings(%{@rule | tier: :quarantine}, nil) == []
    end
  end

  describe "authorize/2" do
    test "an empty list passes for every authority" do
      for a <- [:operator, :coordinator, :restricted], do: assert(Authority.authorize([], a) == :ok)
    end

    test "only the operator may loosen" do
      assert Authority.authorize(["x is looser"], :operator) == :ok
      assert {:error, msg} = Authority.authorize(["x is looser"], :coordinator)
      assert msg =~ "operator-only"
      assert {:error, _} = Authority.authorize(["x is looser"], :restricted)
    end
  end

  describe "from_scope/1, for every token tier" do
    test "only a coordinator token with operator proof is the operator" do
      ws = Ecto.UUID.generate()
      from = fn token -> token |> Scope.from_token() |> elem(1) |> Authority.from_scope() end

      assert from.(Scope.mint_coordinator(nil, operator: true)) == :operator
      assert from.(Scope.mint_coordinator(nil)) == :coordinator
      assert from.(Scope.mint_coordinator(nil, operator: false)) == :coordinator

      assert from.(Scope.mint_worker(%{id: "bd-1", workspace_id: ws})) == :restricted
      assert from.(Scope.mint_refine("sess", ws, "bd-1")) == :restricted
      assert Authority.from_scope(nil) == :restricted
    end
  end
end
