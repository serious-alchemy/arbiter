defmodule Arbiter.Agents.GrokRoutingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.ByDifficulty
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

  describe "ByDifficulty with grok" do
    test "disabled by default: D1 stays on the workspace agent" do
      assert %{type: :claude} = ByDifficulty.choose(%Issue{difficulty: 1}, ws(nil), %{})
      assert %{type: :claude} = ByDifficulty.choose(%Issue{difficulty: 1}, ws(%{}), %{})
    end

    test "enabled: only D1 goes to grok" do
      w = ws(%{"enabled" => true})
      assert %{type: :grok} = ByDifficulty.choose(%Issue{difficulty: 1}, w, %{})

      for d <- [nil, 0, 2, 3, 4, 5] do
        assert %{type: :claude} = ByDifficulty.choose(%Issue{difficulty: d}, w, %{})
      end
    end

    test "enabled with an override widens the set" do
      w = ws(%{"enabled" => true, "difficulties" => [0, 1]})
      assert %{type: :grok} = ByDifficulty.choose(%Issue{difficulty: 0}, w, %{})
      assert %{type: :claude} = ByDifficulty.choose(%Issue{difficulty: 2}, w, %{})
    end

    test "other policies are untouched" do
      w = %Workspace{
        config: %{"routing" => %{"policy" => "static", "grok" => %{"enabled" => true}}}
      }

      assert %{type: :claude} = Routing.choose(%Issue{difficulty: 1}, w, %{})
    end
  end

  test "grok is a registered agent type" do
    assert "grok" in Arbiter.Agents.valid_agent_types()
  end
end
