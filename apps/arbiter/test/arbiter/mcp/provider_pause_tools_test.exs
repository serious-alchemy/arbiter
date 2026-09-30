defmodule Arbiter.MCP.ProviderPauseToolsTest do
  @moduledoc "bd-5ef587: `provider_pause` / `provider_resume` MCP tools."
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.{Catalog, Scope, Tools}

  @coordinator %Scope{tier: :coordinator, workspace_id: nil}

  test "are coordinator-tier catalog entries" do
    for name <- ~w(provider_pause provider_resume) do
      tool = Enum.find(Catalog.all(), &(&1.name == name))
      assert tool
      assert :coordinator in tool.tiers
      refute :worker in tool.tiers
    end
  end

  test "pause then resume" do
    assert {:ok, %{paused: [%{"target" => "antigravity", "reason" => "escape", "by" => "mcp"}]}} =
             Tools.provider_pause(@coordinator, %{"ref" => "antigravity", "reason" => "escape"})

    assert Arbiter.Providers.Pause.provider_paused?(:antigravity)

    assert {:ok, %{paused: []}} = Tools.provider_resume(@coordinator, %{"ref" => "antigravity"})
    refute Arbiter.Providers.Pause.provider_paused?(:antigravity)
  end

  test "ref is required and unknown refs error" do
    assert {:error, {:invalid, _}} = Tools.provider_pause(@coordinator, %{})
    assert {:error, _} = Tools.provider_pause(@coordinator, %{"ref" => "nope"})
  end
end
