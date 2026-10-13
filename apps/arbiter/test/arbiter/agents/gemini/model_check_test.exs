defmodule Arbiter.Agents.Gemini.ModelCheckTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Gemini.ModelCatalog
  alias Arbiter.Agents.Gemini.ModelCheck
  alias Arbiter.Tasks.Workspace

  @served ~w(gemini-3.8-flash-low gemini-3.8-flash-medium gemini-3.8-flash-high
             claude-opus-5-5-high claude-sonnet-5-5-high)

  setup do
    ModelCatalog.reset()
    on_exit(&ModelCatalog.reset/0)
  end

  defp workspace!(config) do
    Ash.create!(Workspace, %{name: "mc-#{System.unique_integer([:positive])}", config: config})
  end

  defp report(workspaces, models),
    do: ModelCheck.report(workspaces: workspaces, probe: fn -> models end)

  test "the built-in agy defaults are all served by the current `agy models`" do
    assert %{status: :ok, problems: []} = report([], {:ok, @served})
  end

  test "a stale built-in default is reported by tier and model, with the fallback" do
    # What agy served before the 2026-10-13 auto-update dropped Pro / Opus 4.6.
    served = ~w(gemini-3.8-flash-low gemini-3.8-flash-medium claude-sonnet-5-5-high)

    assert %{status: :missing, problems: problems} = report([], {:ok, served})

    assert [
             %{
               tier: "premium",
               model: "gemini-3.8-flash-high",
               source: "default",
               used_by: ["default"],
               fallback: "gemini-3.8-flash-medium"
             },
             %{tier: "flagship", model: "claude-opus-5-5-high", source: "default"}
           ] = problems
  end

  test "a workspace override naming a model agy dropped is reported against that workspace" do
    ws =
      workspace!(%{
        "agent" => %{
          "type" => ["gemini"],
          "config" => %{"gemini" => %{"tier_models" => %{"premium" => "gemini-3.1-pro-high"}}}
        },
        "review_agent" => %{
          "type" => ["gemini"],
          "config" => %{"tier_models" => %{"flagship" => "claude-opus-4-6-thinking"}}
        }
      })

    assert %{status: :missing, problems: problems} = report([ws], {:ok, @served})

    assert [
             %{tier: "premium", model: "gemini-3.1-pro-high", source: "override"} = premium,
             %{tier: "flagship", model: "claude-opus-4-6-thinking", source: "override"} = flagship
           ] = problems

    assert premium.used_by == ["#{ws.name} (agent)"]
    assert flagship.used_by == ["#{ws.name} (review_agent)"]
  end

  test "a workspace that does not use agy is not audited" do
    ws =
      workspace!(%{
        "agent" => %{
          "type" => ["claude"],
          "config" => %{"tier_models" => %{"premium" => "opus"}}
        }
      })

    assert %{status: :ok, problems: []} = report([ws], {:ok, @served})
  end

  test "an unreadable model list is :unknown, never ok and never a false problem" do
    assert %{status: :unknown, problems: [], models: nil} =
             report([], {:error, :not_installed})
  end
end
