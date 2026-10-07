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
    assert {:ok,
            %{
              paused: [
                %{"target" => "antigravity", "reason" => "escape", "by" => "coordinator via mcp"}
              ]
            }} =
             Tools.provider_pause(@coordinator, %{"ref" => "antigravity", "reason" => "escape"})

    assert Arbiter.Providers.Pause.provider_paused?(:antigravity)

    assert {:ok, %{paused: []}} = Tools.provider_resume(@coordinator, %{"ref" => "antigravity"})
    refute Arbiter.Providers.Pause.provider_paused?(:antigravity)
  end

  test "an ambiguous or unknown ref maps to a typed error, not an atom dump" do
    assert {:error, {:not_found, msg}} = Tools.provider_pause(@coordinator, %{"ref" => "nope"})
    refute msg =~ ":not_found"

    assert {:error, {:invalid, msg}} = Tools.provider_resume(@coordinator, %{"ref" => "claude"})
    assert msg =~ "not paused"
  end

  test "a non-string reason is rejected like REST" do
    assert {:error, {:invalid, msg}} =
             Tools.provider_pause(@coordinator, %{"ref" => "codex", "reason" => 5})

    assert msg =~ "reason"
    refute Arbiter.Providers.Pause.provider_paused?(:codex)
  end

  test "an ambiguous bare slug is an :invalid error naming provider:slug" do
    for provider <- [:claude, :codex] do
      {:ok, _} = Ash.create(Arbiter.Accounts.ProviderAccount, %{provider: provider, slug: "dup"})
    end

    assert {:error, {:invalid, msg}} = Tools.provider_pause(@coordinator, %{"ref" => "dup"})
    assert msg =~ "provider:slug"
  end

  test "ref is required and unknown refs error" do
    assert {:error, {:invalid, _}} = Tools.provider_pause(@coordinator, %{})
    assert {:error, _} = Tools.provider_pause(@coordinator, %{"ref" => "nope"})
  end
end
