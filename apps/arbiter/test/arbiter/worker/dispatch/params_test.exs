defmodule Arbiter.Worker.Dispatch.ParamsTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Scope
  alias Arbiter.Worker.Dispatch.Params

  @coordinator %Scope{tier: :coordinator, can_dispatch: true, depth: 0}

  defp norm(params, verb \\ :dispatch, extra \\ []) do
    Params.normalize(
      params,
      Keyword.merge([verb: verb, scope: @coordinator, surface: :rest], extra)
    )
  end

  describe "provider selection" do
    test "no selector leaves the workspace default (start_claude, no agent_type)" do
      assert {:ok, opts} = norm(%{"task_id" => "bd-1"})
      assert opts[:start_claude] == true
      refute Keyword.has_key?(opts, :agent_type)
      refute Keyword.has_key?(opts, :start_driver)
    end

    test "every provider in Agents.valid_agent_types/0 is accepted, grok included" do
      assert "grok" in Arbiter.Agents.valid_agent_types()

      for p <- Arbiter.Agents.valid_agent_types() do
        assert {:ok, opts} = norm(%{"provider" => p})
        assert opts[:agent_type] == String.to_existing_atom(p)
        assert opts[:start_claude] == true
      end
    end

    test "an unknown provider is a loud :invalid listing the valid ones" do
      assert {:error, {:invalid, msg}} = norm(%{"provider" => "llama"})
      assert msg =~ "unknown provider"
      assert msg =~ "grok"
    end

    test "a blank provider is the workspace default" do
      assert {:ok, opts} = norm(%{"provider" => "  "})
      refute Keyword.has_key?(opts, :agent_type)
    end

    test "with_claude / with_gemini are aliases on every surface" do
      assert {:ok, c} = norm(%{"with_claude" => true}, :dispatch, surface: :mcp)
      assert c[:agent_type] == :claude
      assert {:ok, g} = norm(%{"with_gemini" => "true"}, :dispatch, surface: :mcp)
      assert g[:agent_type] == :gemini
      assert {:ok, f} = norm(%{"with_gemini" => false})
      refute Keyword.has_key?(f, :agent_type)
    end

    test "no_agent parks: no driver, no agent" do
      assert {:ok, opts} = norm(%{"no_agent" => true})
      assert opts[:start_driver] == false
      refute Keyword.has_key?(opts, :start_claude)
      refute Keyword.has_key?(opts, :agent_type)
    end

    test "no_agent together with any provider selector is refused, never half-honoured" do
      for extra <- [
            %{"provider" => "claude"},
            %{"with_claude" => true},
            %{"with_gemini" => true}
          ] do
        assert {:error, {:invalid, msg}} = norm(Map.put(extra, "no_agent", true))
        assert msg =~ "no_agent"
      end
    end

    test "two different selectors conflict; the same one twice does not" do
      assert {:error, {:invalid, _}} = norm(%{"provider" => "claude", "with_gemini" => true})
      assert {:error, {:invalid, _}} = norm(%{"with_claude" => true, "with_gemini" => true})
      assert {:ok, opts} = norm(%{"provider" => "gemini", "with_gemini" => true})
      assert opts[:agent_type] == :gemini
    end
  end

  describe "flags, model, repo" do
    test "force / over_cap map to the dispatch opts, actor from the token" do
      assert {:ok, opts} = norm(%{"force" => true, "over_cap" => "true"})
      assert opts[:force] == true
      assert opts[:force_slot] == true
      assert opts[:slot_override_actor] == "coordinator"
      assert opts[:dispatched_by] == "http_api"
    end

    test "dispatched_by names the surface" do
      assert {:ok, opts} = norm(%{}, :dispatch, surface: :mcp)
      assert opts[:dispatched_by] == "mcp"
    end

    test "a junk boolean is :invalid, on every flag" do
      for key <- ~w(force over_cap force_quota no_agent with_claude with_gemini) do
        assert {:error, {:invalid, msg}} = norm(%{key => "yes"})
        assert msg =~ key
      end
    end

    test "model and repo are passed through; blank is absent; non-string is invalid" do
      assert {:ok, opts} = norm(%{"model" => "opus", "repo" => "org/repo"})
      assert opts[:model] == "opus"
      assert opts[:repo] == "org/repo"
      assert {:ok, opts} = norm(%{"model" => "", "repo" => " "})
      refute Keyword.has_key?(opts, :model)
      refute Keyword.has_key?(opts, :repo)
      assert {:error, {:invalid, _}} = norm(%{"model" => 3})
    end

    test "an unknown argument is a loud error naming it" do
      assert {:error, {:invalid, msg}} = norm(%{"task_id" => "bd-1", "acceptance" => "x"})
      assert msg =~ "acceptance"
    end

    test "task_id is accepted; `workspace` only over MCP" do
      assert {:ok, _} = norm(%{"task_id" => "bd-1"})
      assert {:ok, _} = norm(%{"workspace" => "w"}, :dispatch, surface: :mcp)
      assert {:error, {:invalid, _}} = norm(%{"workspace" => "w"})
    end
  end

  describe "quota bypass attribution" do
    test "force_quota stamps the token's actor and the reason, on every surface and verb" do
      for surface <- [:mcp, :rest], verb <- [:dispatch, :resume, :review] do
        assert {:ok, opts} =
                 norm(
                   %{"force_quota" => true, "force_quota_reason" => " burn "},
                   verb,
                   surface: surface
                 )

        assert opts[:skip_quota_gate] == true
        assert opts[:quota_bypass_actor] == "coordinator"
        assert opts[:quota_bypass_reason] == "burn"
      end
    end

    test "no force_quota, no bypass opts" do
      assert {:ok, opts} = norm(%{})
      refute Keyword.has_key?(opts, :skip_quota_gate)
      refute Keyword.has_key?(opts, :quota_bypass_actor)
    end

    test "a reason without force_quota is refused rather than dropped" do
      assert {:error, {:invalid, msg}} = norm(%{"force_quota_reason" => "why"})
      assert msg =~ "force_quota"
    end

    test "an operator token is attributed as the operator" do
      scope = %{@coordinator | operator: true}
      assert {:ok, opts} = norm(%{"force_quota" => true}, :dispatch, scope: scope)
      assert opts[:quota_bypass_actor] == "operator:cli"
    end
  end

  describe "recursion depth" do
    test "the child scope depth is depth + 1" do
      assert {:ok, opts} = norm(%{}, :dispatch, scope: %{@coordinator | depth: 1})
      assert opts[:depth] == 2
    end

    test "a scope at the limit is refused as :unauthorized, on every verb" do
      at_limit = %{@coordinator | depth: Arbiter.MCP.max_depth()}

      for verb <- [:dispatch, :resume, :review] do
        assert {:error, {:unauthorized, msg}} = norm(%{}, verb, scope: at_limit)
        assert msg =~ "dispatch depth limit"
      end
    end
  end

  describe "resume" do
    test "is a human resume; force becomes force_slot; mode defaults to session" do
      assert {:ok, opts} = norm(%{"force" => true}, :resume)
      assert opts[:resume_origin] == :human
      assert opts[:force_slot] == true
      assert opts[:slot_override_actor] == "coordinator"
      assert opts[:resume_mode] == :session
      refute Keyword.has_key?(opts, :start_claude)
    end

    test "mode: briefing is the explicit opt-in; anything else is invalid" do
      assert {:ok, opts} = norm(%{"mode" => "briefing"}, :resume)
      assert opts[:resume_mode] == :briefing
      assert {:error, {:invalid, msg}} = norm(%{"mode" => "fresh"}, :resume)
      assert msg =~ "mode"
    end

    test "provider selectors and dispatch-only flags are not resume arguments" do
      for key <- ~w(provider with_claude no_agent over_cap) do
        assert {:error, {:invalid, _}} = norm(%{key => true}, :resume)
      end
    end
  end

  describe "review" do
    test "claude-driven by default, review: true, no :force passed to Dispatch" do
      assert {:ok, opts} = norm(%{"force" => true, "automation" => "off"}, :review)
      assert opts[:review] == true
      assert opts[:start_claude] == true
      refute Keyword.has_key?(opts, :force)
    end

    test "with_claude: false dispatches without an agent or driver" do
      assert {:ok, opts} = norm(%{"with_claude" => false}, :review)
      assert opts[:start_claude] == false
      assert opts[:start_driver] == false
    end

    test "dispatch-only arguments are refused on a review" do
      assert {:error, {:invalid, _}} = norm(%{"provider" => "claude"}, :review)
      assert {:error, {:invalid, _}} = norm(%{"no_agent" => true}, :review)
    end
  end
end
