defmodule Arbiter.Doctor.ScopeTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Doctor.Scope
  alias Arbiter.Providers.Pause
  alias Arbiter.Tasks.Workspace

  defp workspace!(config) do
    Ash.create!(Workspace, %{name: "scope-#{System.unique_integer([:positive])}", config: config})
  end

  defp report_for(workspaces), do: Scope.report(workspaces: workspaces)

  test "a workspace with no config uses claude only; nothing is paused" do
    r = report_for([workspace!(%{})])

    assert %{in_use: true, paused: false} = r.providers["claude"]
    assert %{in_use: false} = r.providers["gemini"]
    assert %{in_use: false} = r.providers["codex"]
    assert %{in_use: false} = r.providers["grok"]
    assert r.podman_in_use == false
    assert r.egress_enforced == false
  end

  test "an agent.type list puts agy (gemini) and codex in use, naming the workspace" do
    ws = workspace!(%{"agent" => %{"type" => ["claude", "gemini", "codex"]}})
    r = report_for([ws])

    assert %{in_use: true, workspaces: [name]} = r.providers["gemini"]
    assert name == ws.name
    assert r.providers["codex"].in_use
  end

  test "grok routing counts as in use" do
    r = report_for([workspace!(%{"routing" => %{"grok" => %{"enabled" => true}}})])
    assert r.providers["grok"].in_use
  end

  test "a provider-wide pause is reported, and only for that provider" do
    ws = workspace!(%{"agent" => %{"type" => ["claude", "gemini"]}})
    {:ok, _} = Pause.pause("antigravity", by: "test", reason: "doctor scope test")

    r = report_for([ws])

    assert %{in_use: true, paused: true} = r.providers["gemini"]
    assert %{paused: false} = r.providers["claude"]
  end

  test "sandbox.backend podman, a podman review backend or a repo override each count" do
    for config <- [
          %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}},
          %{"agent" => %{"security" => %{"sandbox" => %{"review_backend" => "podman"}}}},
          %{
            "agent" => %{
              "security" => %{
                "repos" => %{"tonic" => %{"sandbox" => %{"backend" => "podman"}}}
              }
            }
          }
        ] do
      assert report_for([workspace!(config)]).podman_in_use, inspect(config)
    end
  end

  test "an egress allowlist or none counts, including from a repo override" do
    for config <- [
          %{"agent" => %{"security" => %{"sandbox" => %{"egress" => "allowlist"}}}},
          %{"agent" => %{"security" => %{"sandbox" => %{"egress" => "none"}}}},
          %{
            "agent" => %{
              "security" => %{"repos" => %{"tonic" => %{"sandbox" => %{"egress" => "none"}}}}
            }
          }
        ] do
      assert report_for([workspace!(config)]).egress_enforced, inspect(config)
    end
  end
end
