defmodule Arbiter.Agents.GrokRoutingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Agents.Routing
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  defp ws(grok) do
    routing = %{"policy" => "by_difficulty"}
    routing = if grok, do: Map.put(routing, "grok", grok), else: routing
    %Workspace{config: %{"agent" => %{"type" => "claude", "config" => %{}}, "routing" => routing}}
  end

  describe "enabled?/1" do
    test "off unless the workspace sets routing.grok.enabled: true" do
      refute GrokRouting.enabled?(nil)
      refute GrokRouting.enabled?(ws(nil))
      refute GrokRouting.enabled?(ws(%{}))
      refute GrokRouting.enabled?(ws(%{"enabled" => "yes"}))
      assert GrokRouting.enabled?(ws(%{"enabled" => true}))
    end
  end

  describe "difficulties/1" do
    test "defaults to D1 only; a workspace may override" do
      assert GrokRouting.difficulties(ws(%{"enabled" => true})) == [1]

      assert GrokRouting.difficulties(ws(%{"enabled" => true, "difficulties" => [0, 1]})) == [
               0,
               1
             ]

      assert GrokRouting.difficulties(ws(%{"enabled" => true, "difficulties" => "x"})) == [1]
    end
  end

  describe "Routing with grok" do
    test "disabled by default: D1 stays on the workspace agent" do
      assert %{type: :claude} = Routing.choose(%Issue{difficulty: 1}, ws(nil), %{})
      assert %{type: :claude} = Routing.choose(%Issue{difficulty: 1}, ws(%{}), %{})
    end

    test "enabled: only D1 goes to grok" do
      w = ws(%{"enabled" => true})
      assert %{type: :grok} = Routing.choose(%Issue{difficulty: 1}, w, %{})

      for d <- [nil, 0, 2, 3, 4, 5] do
        assert %{type: :claude} = Routing.choose(%Issue{difficulty: d}, w, %{})
      end
    end

    test "enabled with an override widens the set" do
      w = ws(%{"enabled" => true, "difficulties" => [0, 1]})
      assert %{type: :grok} = Routing.choose(%Issue{difficulty: 0}, w, %{})
      assert %{type: :claude} = Routing.choose(%Issue{difficulty: 2}, w, %{})
    end

    test "other policies honour it too" do
      for policy <- ["static", "by_priority"] do
        w = %Workspace{
          config: %{"routing" => %{"policy" => policy, "grok" => %{"enabled" => true}}}
        }

        assert %{type: :grok} = Routing.choose(%Issue{difficulty: 1, priority: 2}, w, %{})
        assert %{type: :claude} = Routing.choose(%Issue{difficulty: 3, priority: 2}, w, %{})
      end
    end

    test "a pinned model from another provider is dropped" do
      w = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "haiku"}},
          "routing" => %{"policy" => "static", "grok" => %{"enabled" => true}}
        }
      }

      choice = Routing.choose(%Issue{difficulty: 1}, w, %{})
      assert choice.type == :grok
      refute Map.has_key?(choice.config, "model")
    end
  end

  test "grok is a registered agent type" do
    assert "grok" in Arbiter.Agents.valid_agent_types()
  end
end
