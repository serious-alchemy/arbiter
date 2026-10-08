defmodule Arbiter.Agents.GrokRoutingFilterTest do
  @moduledoc """
  bd-bvx07f: grok's D1 routing is a candidate like any other — a paused grok or
  a ticket whose provider constraint excludes it is never picked.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Routing
  alias Arbiter.Providers.Pause
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  defp ws do
    %Workspace{
      config: %{
        "agent" => %{"type" => "claude", "config" => %{}},
        "routing" => %{"policy" => "by_difficulty", "grok" => %{"enabled" => true}}
      }
    }
  end

  test "an unconstrained, unpaused D1 ticket still goes to grok" do
    assert %{type: :grok} = Routing.choose(%Issue{difficulty: 1}, ws(), %{})
  end

  test "a paused grok is never routed to" do
    {:ok, _} = Pause.pause("grok", reason: "free tier spent", by: "test")
    assert %{type: :claude} = Routing.choose(%Issue{difficulty: 1}, ws(), %{})
  end

  test "require: [claude] keeps a D1 ticket off grok" do
    task = %Issue{difficulty: 1, provider_constraint: %{"require" => ["claude"]}}
    assert %{type: :claude} = Routing.choose(task, ws(), %{})
  end

  test "exclude: [grok] keeps a D1 ticket off grok; excluding another leaves it" do
    task = %Issue{difficulty: 1, provider_constraint: %{"exclude" => ["grok"]}}
    assert %{type: :claude} = Routing.choose(task, ws(), %{})

    other = %Issue{difficulty: 1, provider_constraint: %{"exclude" => ["gemini"]}}
    assert %{type: :grok} = Routing.choose(other, ws(), %{})
  end
end
