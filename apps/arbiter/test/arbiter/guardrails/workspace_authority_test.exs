defmodule Arbiter.Guardrails.WorkspaceAuthorityTest do
  @moduledoc """
  Loosening `guardrails.*` and `agent.security` is operator-only (G11, AC3):
  the workspace write refuses a loosening from anyone but the operator, for
  every token tier, and always allows a tightening. `ValidateConfig` validates
  the `guardrails` block (AC1).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Authority
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Workspace

  @cap %{"match" => %{"provider" => "antigravity"}, "max_tier" => "probation"}

  defp workspace!(config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ga-#{System.unique_integer([:positive])}", prefix: "ga#{:rand.uniform(99_999)}", config: config})

    ws
  end

  defp patch(ws, patch, authority, unset \\ []) do
    ctx = if authority, do: %{guardrail_authority: authority}, else: %{}
    Ash.update(ws, %{patch: patch, unset_paths: unset}, action: :patch_config, context: ctx)
  end

  defp refused?({:error, err}), do: Exception.message(err) =~ "operator-only"
  defp refused?(_), do: false

  describe "ValidateConfig" do
    test "accepts a valid guardrails block" do
      ws = workspace!()

      assert {:ok, updated} =
               patch(ws, %{"guardrails" => %{"subjects" => [@cap], "bindings" => %{"prod_read" => %{"grant_by" => "operator"}}}}, :operator)

      assert get_in(updated.config, ["guardrails", "subjects"]) == [@cap]
    end

    test "refuses an invalid block, whoever writes it" do
      ws = workspace!()

      for authority <- [:operator, :coordinator] do
        assert {:error, err} = patch(ws, %{"guardrails" => %{"subjects" => [%{"match" => %{"provider" => "x"}, "max_tier" => "godmode"}]}}, authority)
        assert Exception.message(err) =~ "max_tier"
      end

      assert {:error, err} = patch(ws, %{"guardrails" => %{"nonsense" => 1}}, :operator)
      assert Exception.message(err) =~ "unknown key"
    end
  end

  describe "the authority rule, per authority" do
    test "the operator may loosen and tighten" do
      ws = workspace!(%{"guardrails" => %{"subjects" => [@cap]}})

      assert {:ok, _} = patch(ws, %{"guardrails" => %{"subjects" => [%{@cap | "max_tier" => "trusted"}]}}, :operator)
      assert {:ok, _} = patch(ws, %{"agent" => %{"security" => %{"permissions" => %{"allow" => ["Bash(ls:*)"]}}}}, :operator)
    end

    test "no authority given is the in-process operator (the dashboard, the Loop's gated apply)" do
      ws = workspace!(%{"guardrails" => %{"subjects" => [@cap]}})
      assert {:ok, _} = patch(ws, %{"guardrails" => %{"subjects" => []}}, nil)
    end

    for authority <- [:coordinator, :restricted] do
      test "#{authority} may tighten" do
        ws = workspace!(%{"guardrails" => %{"subjects" => [@cap]}})

        assert {:ok, ws2} = patch(ws, %{"guardrails" => %{"subjects" => [%{@cap | "max_tier" => "quarantine"}]}}, unquote(authority))
        assert {:ok, ws3} = patch(ws2, %{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}}, unquote(authority))
        assert {:ok, _} = patch(ws3, %{"agent" => %{"security" => %{"sandbox" => %{"egress" => "none"}}}}, unquote(authority))
      end

      test "#{authority} may not loosen guardrails.*" do
        ws = workspace!(%{"guardrails" => %{"subjects" => [@cap], "bindings" => %{"prod_read" => %{"grant_by" => "operator"}}}})

        assert refused?(patch(ws, %{"guardrails" => %{"subjects" => [%{@cap | "max_tier" => "trusted"}]}}, unquote(authority)))
        assert refused?(patch(ws, %{"guardrails" => %{"subjects" => []}}, unquote(authority)))
        assert refused?(patch(ws, %{}, unquote(authority), ["guardrails.subjects"]))
        assert refused?(patch(ws, %{"guardrails" => %{"bindings" => %{"prod_read" => %{"grant_by" => "coordinator"}}}}, unquote(authority)))
        assert refused?(patch(ws, %{"guardrails" => %{"defaults" => %{"permissions" => ["prod_read"]}}}, unquote(authority)))

        # and the config is untouched
        assert get_in(Ash.get!(Workspace, ws.id).config, ["guardrails", "subjects"]) == [@cap]
      end

      test "#{authority} may not loosen agent.security" do
        ws = workspace!(%{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict", "deny" => ["Bash(rm:*)"]}, "sandbox" => %{"egress" => "none"}}}})

        assert refused?(patch(ws, %{"agent" => %{"security" => %{"permissions" => %{"mode" => "bypass"}}}}, unquote(authority)))
        assert refused?(patch(ws, %{"agent" => %{"security" => %{"sandbox" => %{"egress" => "open"}}}}, unquote(authority)))
        assert refused?(patch(ws, %{}, unquote(authority), ["agent.security.permissions.deny"]))
        assert refused?(patch(ws, %{}, unquote(authority), ["agent.security"]))
        assert refused?(patch(ws, %{"agent" => %{"security" => %{"permissions" => %{"allow" => ["Bash(curl:*)"]}}}}, unquote(authority)))
      end

      test "#{authority} may still edit unrelated config" do
        ws = workspace!(%{"guardrails" => %{"subjects" => [@cap]}})
        assert {:ok, _} = patch(ws, %{"merge" => %{"auto_merge" => true}}, unquote(authority))
      end
    end

    test "the whole-config :update path is guarded too" do
      ws = workspace!(%{"agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}})

      assert refused?(Ash.update(ws, %{config: %{}}, context: %{guardrail_authority: :coordinator}))
      assert {:ok, _} = Ash.update(ws, %{config: %{}}, context: %{guardrail_authority: :operator})
    end

    test "creating a workspace with a loose guardrails block is guarded" do
      attrs = %{name: "ga-create", prefix: "gac", config: %{"guardrails" => %{"bindings" => %{"prod_read" => %{}}}}}
      assert refused?(Ash.create(Workspace, attrs, context: %{guardrail_authority: :coordinator}))
      assert {:ok, _} = Ash.create(Workspace, attrs, context: %{guardrail_authority: :operator})
    end
  end

  describe "MCP workspace_config_set / unset, per token tier" do
    setup do
      ws = workspace!(%{"guardrails" => %{"subjects" => [@cap]}, "agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}})
      %{ws: ws}
    end

    defp scope!(token), do: elem(Scope.from_token(token), 1)

    test "a coordinator token may tighten and may not loosen", %{ws: ws} do
      coordinator = scope!(Scope.mint_coordinator(nil))

      assert {:ok, _} = Tools.workspace_config_set(coordinator, %{"workspace" => ws.id, "key" => "guardrails.subjects", "value" => [%{@cap | "max_tier" => "quarantine"}]})
      assert {:ok, _} = Tools.workspace_config_set(coordinator, %{"workspace" => ws.id, "key" => "agent.security.sandbox.egress", "value" => "none"})

      assert {:error, {:invalid, msg}} = Tools.workspace_config_set(coordinator, %{"workspace" => ws.id, "key" => "agent.security.permissions.mode", "value" => "bypass"})
      assert msg =~ "operator-only"

      assert {:error, {:invalid, msg}} = Tools.workspace_config_unset(coordinator, %{"workspace" => ws.id, "key" => "guardrails.subjects"})
      assert msg =~ "operator-only"
    end

    test "a coordinator token with operator proof may loosen", %{ws: ws} do
      operator = scope!(Scope.mint_coordinator(nil, operator: true))

      assert {:ok, _} = Tools.workspace_config_set(operator, %{"workspace" => ws.id, "key" => "agent.security.permissions.mode", "value" => "bypass"})
      assert {:ok, _} = Tools.workspace_config_unset(operator, %{"workspace" => ws.id, "key" => "guardrails.subjects"})
    end

    test "worker and refine tokens carry no authority at all" do
      assert Authority.from_scope(scope!(Scope.mint_worker(%{id: "bd-1", workspace_id: "w"}))) == :restricted
      assert Authority.from_scope(scope!(Scope.mint_refine("s", "w", "bd-1"))) == :restricted
    end
  end
end
