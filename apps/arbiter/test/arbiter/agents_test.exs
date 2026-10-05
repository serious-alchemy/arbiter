defmodule Arbiter.AgentsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents
  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Codex
  alias Arbiter.Agents.Gemini
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  defp policy(mode),
    do: %{SecurityPolicy.base() | permissions: %{SecurityPolicy.base().permissions | mode: mode}}

  describe "for_workspace/1 and for_type/1" do
    test "returns Claude for the default workspace (no `agent` key)" do
      ws = %Workspace{config: %{}}
      assert Agents.for_workspace(ws) == Claude
    end

    test "returns Claude when `agent.type` is `claude`" do
      ws = %Workspace{config: %{"agent" => %{"type" => "claude"}}}
      assert Agents.for_workspace(ws) == Claude
    end

    test "returns Claude for nil workspace (back-compat path)" do
      assert Agents.for_workspace(nil) == Claude
    end

    test "for_type/:claude resolves to the Claude adapter" do
      assert Agents.for_type(:claude) == Claude
    end

    test "for_type/:codex resolves to the Codex adapter" do
      assert Agents.for_type(:codex) == Arbiter.Agents.Codex
    end

    test "for_type/1 raises for unregistered types (aider not shipped)" do
      assert_raise ArgumentError, ~r/no agent adapter registered for :aider/, fn ->
        Agents.for_type(:aider)
      end
    end
  end

  describe "for_task/2" do
    test "falls back to the workspace adapter when task has no per-task override" do
      task = %Issue{}
      ws = %Workspace{config: %{}}
      assert Agents.for_task(task, ws) == Claude
    end
  end

  describe "reviewer_for_workspace/1" do
    test "falls back to the worker adapter when `review_agent` is absent" do
      ws = %Workspace{config: %{"agent" => %{"type" => "claude"}}}
      assert Agents.reviewer_for_workspace(ws) == Claude
    end

    test "uses `review_agent.type` when set" do
      ws = %Workspace{config: %{"review_agent" => %{"type" => "claude"}}}
      assert Agents.reviewer_for_workspace(ws) == Claude
    end
  end

  describe "write_confinement/2 + write_confined?/2 (bd-1abj7u)" do
    test "Claude answers :permission_layer under :strict" do
      assert Agents.write_confinement(Claude, policy(:strict)) == :permission_layer
      assert Agents.write_confined?(Claude, policy(:strict))
    end

    test "Gemini and Codex answer :none regardless of mode" do
      assert Agents.write_confinement(Gemini, policy(:strict)) == :none
      refute Agents.write_confined?(Gemini, policy(:strict))
      assert Agents.write_confinement(Codex, policy(:strict)) == :none
      refute Agents.write_confined?(Codex, policy(:strict))
    end

    test "an adapter missing the callback answers :none" do
      assert Agents.write_confinement(String, policy(:strict)) == :none
    end
  end

  describe "write_jail_warning/2 (bd-3s82pf)" do
    test "an adapter missing the callback answers nil" do
      assert Agents.write_jail_warning(String, policy(:strict)) == nil
      assert Agents.write_jail_warning(Claude, policy(:strict)) == nil
    end
  end

  describe "agent_pool/1 (bd-1abj7u)" do
    test "nil workspace is [:claude]" do
      assert Agents.agent_pool(nil) == [:claude]
    end

    test "single string agent.type" do
      ws = %Workspace{config: %{"agent" => %{"type" => "gemini"}}}
      assert Agents.agent_pool(ws) == [:gemini]
    end

    test "list agent.type preserves configured order" do
      ws = %Workspace{config: %{"agent" => %{"type" => ["gemini", "claude"]}}}
      assert Agents.agent_pool(ws) == [:gemini, :claude]
    end

    test "unset agent.type is [:claude]" do
      ws = %Workspace{config: %{}}
      assert Agents.agent_pool(ws) == [:claude]
    end
  end

  describe "strict_eligible_provider/4 (bd-1abj7u)" do
    test "non-strict mode never constrains, even for an unconfined provider" do
      assert Agents.strict_eligible_provider(:gemini, policy(:auto), [:gemini]) ==
               {:ok, :gemini}

      assert Agents.strict_eligible_provider(:codex, policy(:bypass), [:codex]) ==
               {:ok, :codex}
    end

    test "under :strict, a preferred provider that can confine writes is used as-is" do
      assert Agents.strict_eligible_provider(:claude, policy(:strict), [:claude]) ==
               {:ok, :claude}
    end

    test "under :strict, an explicit ineligible preference errors rather than substituting" do
      assert Agents.strict_eligible_provider(:gemini, policy(:strict), [:gemini, :claude],
               explicit: true
             ) == {:error, :ineligible}
    end

    test "under :strict, automatic selection skips an ineligible preferred provider for an eligible pool entry" do
      assert Agents.strict_eligible_provider(:gemini, policy(:strict), [:gemini, :claude]) ==
               {:ok, :claude}
    end

    test "under :strict, automatic selection errors when no pool entry is eligible" do
      assert Agents.strict_eligible_provider(:gemini, policy(:strict), [:gemini, :codex]) ==
               {:error, :ineligible}
    end

    test "under :strict with no pool, an ineligible automatic preference errors" do
      assert Agents.strict_eligible_provider(:codex, policy(:strict), []) ==
               {:error, :ineligible}
    end
  end

  describe "adapters/0 + valid_agent_types/0" do
    test "adapters/0 exposes the registered map" do
      assert Agents.adapters() == %{
               claude: Claude,
               gemini: Arbiter.Agents.Gemini,
               codex: Arbiter.Agents.Codex
             }
    end

    test "valid_agent_types/0 is `[\"claude\", \"gemini\", \"codex\"]`" do
      assert Agents.valid_agent_types() == ["claude", "gemini", "codex"]
    end
  end

  describe "prepare/1 + prepare/2" do
    setup do
      on_exit(fn ->
        Claude.Config.clear()
        Arbiter.Agents.Gemini.Config.clear()
        Arbiter.Agents.Codex.Config.clear()
      end)

      :ok
    end

    test "nil workspace clears the per-process active config" do
      Claude.Config.put_active(%{"model" => "opus"})
      Arbiter.Agents.Gemini.Config.put_active(%{"model" => "gemini-medium"})
      Arbiter.Agents.Codex.Config.put_active(%{"model" => "gpt-5-codex"})
      assert Claude.Config.active_model() == "opus"
      assert Arbiter.Agents.Gemini.Config.active_model() == "gemini-medium"
      assert Arbiter.Agents.Codex.Config.active_model() == "gpt-5-codex"

      assert Agents.prepare(nil) == :ok
      assert Claude.Config.active_model() == nil
      assert Arbiter.Agents.Gemini.Config.active_model() == nil
      assert Arbiter.Agents.Codex.Config.active_model() == nil
    end

    test "seeds configurations from the workspace `agent.config`" do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
        }
      }

      assert Agents.prepare(ws) == :ok
      assert Claude.Config.active_model() == "sonnet"
      assert Arbiter.Agents.Gemini.Config.active_model() == "sonnet"
      assert Arbiter.Agents.Codex.Config.active_model() == "sonnet"
    end

    test "prepare/2 with :review_agent seeds the reviewer config block" do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
          "review_agent" => %{"type" => "claude", "config" => %{"model" => "opus"}}
        }
      }

      assert Agents.prepare(ws, :review_agent) == :ok
      assert Claude.Config.active_model() == "opus"
      assert Arbiter.Agents.Gemini.Config.active_model() == "opus"
    end

    test "prepare/2 accepts keyword list opts directly" do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
          "review_agent" => %{"type" => "claude", "config" => %{"model" => "opus"}}
        }
      }

      assert Agents.prepare(ws, role: :review_agent) == :ok
      assert Claude.Config.active_model() == "opus"
    end

    test "Agent behaviour declares prepare/2 as an optional callback" do
      callbacks = Arbiter.Agents.Agent.behaviour_info(:callbacks)
      optional = Arbiter.Agents.Agent.behaviour_info(:optional_callbacks)

      assert {:prepare, 2} in callbacks
      assert {:prepare, 2} in optional
    end

    test "all in-tree agent adapters implement prepare/2" do
      for {_type, adapter} <- Agents.adapters() do
        assert function_exported?(adapter, :prepare, 2),
               "Expected #{inspect(adapter)} to export prepare/2"
      end
    end

    test "prepare/2 raises FunctionClauseError for invalid role atoms" do
      ws = %Workspace{config: %{}}

      assert_raise FunctionClauseError, fn ->
        Agents.prepare(ws, :invalid_role)
      end
    end
  end
end
