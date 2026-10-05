defmodule Arbiter.Agents.CapabilityMatrixTest do
  @moduledoc """
  bd-57uzkl (R4, docs/design/paced-quota-routing-signals.md §6.2): the
  capability matrix — code defaults plus an operator-owned installation
  override — and the pure check the routers and the legacy dispatch path share.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.CapabilityMatrix
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace

  defp workspace!(config),
    do:
      Ash.create!(Workspace, %{name: "cm-#{System.unique_integer([:positive])}", config: config})

  describe "code defaults" do
    test "claude: resume and reliable async verification" do
      rows = CapabilityMatrix.rows()
      assert :ok = CapabilityMatrix.check(rows, ["resume", "async_verification"], "claude", nil)
    end

    test "antigravity: resumes, but async verification is unreliable and cites its evidence" do
      rows = CapabilityMatrix.rows()
      assert :ok = CapabilityMatrix.check(rows, ["resume"], "antigravity", "gemini-3.8-flash-low")

      assert {:missing, "async_verification", detail} =
               CapabilityMatrix.check(
                 rows,
                 ["async_verification"],
                 "antigravity",
                 "gemini-3.8-flash-low"
               )

      assert detail =~ "needs async_verification"
      assert detail =~ "antigravity/gemini-3.8-flash-low: unreliable"
      assert detail =~ "bd-40h2to"
    end

    test ":unknown fails closed for a required capability and open otherwise" do
      rows = CapabilityMatrix.rows()

      assert {:missing, "async_verification", detail} =
               CapabilityMatrix.check(rows, ["async_verification"], "codex", nil)

      assert detail =~ "unknown"
      assert :ok = CapabilityMatrix.check(rows, ["resume"], "codex", nil)
      assert :ok = CapabilityMatrix.check(rows, [], "codex", nil)
    end

    test "a provider with no row at all is unknown for everything it is required to have" do
      rows = CapabilityMatrix.rows()
      assert :ok = CapabilityMatrix.check(rows, [], "gemini", nil)
      assert {:missing, "resume", _} = CapabilityMatrix.check(rows, ["resume"], "gemini", nil)
    end
  end

  describe "matching" do
    test "a model-glob row beats a provider row for the capabilities it states" do
      rows = [
        %{
          "match" => %{"provider" => "claude", "model" => "claude-haiku*"},
          "async_verification" => "unreliable"
        }
        | CapabilityMatrix.default_rows()
      ]

      assert :ok = CapabilityMatrix.check(rows, ["async_verification"], "claude", "claude-opus-4")

      assert {:missing, "async_verification", _} =
               CapabilityMatrix.check(rows, ["async_verification"], "claude", "claude-haiku-4-5")

      # The haiku row says nothing about resume, so the provider row answers.
      assert :ok = CapabilityMatrix.check(rows, ["resume"], "claude", "claude-haiku-4-5")
    end

    test "a model-glob row does not match a nil model" do
      rows = [
        %{"match" => %{"provider" => "claude", "model" => "claude-haiku*"}, "resume" => false}
        | CapabilityMatrix.default_rows()
      ]

      assert :ok = CapabilityMatrix.check(rows, ["resume"], "claude", nil)
    end
  end

  describe "the installation override" do
    test "rows() puts the override ahead of the code defaults" do
      assert {:ok, _} =
               Settings.set_capability_matrix([
                 %{"match" => %{"provider" => "claude"}, "async_verification" => "unreliable"}
               ])

      rows = CapabilityMatrix.rows()

      assert {:missing, "async_verification", _} =
               CapabilityMatrix.check(rows, ["async_verification"], "claude", nil)

      # Capabilities the override does not state still come from the defaults.
      assert :ok = CapabilityMatrix.check(rows, ["resume"], "claude", nil)
    end

    test "an override can grant what the defaults leave unknown" do
      {:ok, _} =
        Settings.set_capability_matrix([
          %{"match" => %{"provider" => "codex"}, "async_verification" => "reliable"}
        ])

      assert :ok =
               CapabilityMatrix.check(
                 CapabilityMatrix.rows(),
                 ["async_verification"],
                 "codex",
                 nil
               )
    end

    test "nil clears it" do
      {:ok, _} =
        Settings.set_capability_matrix([
          %{"match" => %{"provider" => "claude"}, "resume" => false}
        ])

      {:ok, nil} = Settings.set_capability_matrix(nil)
      assert CapabilityMatrix.rows() == CapabilityMatrix.default_rows()
    end

    test "invalid rows are refused and nothing is written" do
      assert {:error, _} = Settings.set_capability_matrix([%{"resume" => true}])

      assert {:error, _} =
               Settings.set_capability_matrix([
                 %{"match" => %{"provider" => "claude"}, "resume" => "yes"}
               ])

      assert {:error, _} =
               Settings.set_capability_matrix([
                 %{"match" => %{"provider" => "claude"}, "async_verification" => "maybe"}
               ])

      assert {:error, _} =
               Settings.set_capability_matrix([
                 %{"match" => %{"provider" => "claude"}, "teleport" => true}
               ])

      assert Settings.capability_matrix() == nil
    end

    test "a read failure is 'no override'" do
      assert Settings.capability_matrix() == nil
      assert CapabilityMatrix.rows() == CapabilityMatrix.default_rows()
    end
  end

  describe "requirements" do
    test "resume roles need resume; the rest need only what the repo declares" do
      for role <- [:resume, :resume_session, :auto_resume, :reconciler_resume] do
        assert "resume" in CapabilityMatrix.requires(role, [])
      end

      assert CapabilityMatrix.requires(:main, []) == []
      assert CapabilityMatrix.requires(:fix_pass, []) == []
      assert CapabilityMatrix.requires(:reviewer, []) == []
      assert CapabilityMatrix.requires(:main, ["async_verification"]) == ["async_verification"]

      assert CapabilityMatrix.requires(:resume, ["async_verification"]) ==
               ["resume", "async_verification"]
    end
  end

  describe "gate/3" do
    test "off by default, and with the switch off no requirement is ever read" do
      ws =
        workspace!(%{
          "routing" => %{"repos" => %{"arbiter" => %{"requires" => ["async_verification"]}}}
        })

      assert CapabilityMatrix.gate(ws, :main, "arbiter") == nil
      assert CapabilityMatrix.gate(nil, :main, "arbiter") == nil
    end

    test "on: carries the role's and the repo's requirements" do
      ws =
        workspace!(%{
          "routing" => %{
            "capability_gates" => true,
            "repos" => %{"arbiter" => %{"requires" => ["async_verification"]}}
          }
        })

      assert %{requires: ["async_verification"]} = CapabilityMatrix.gate(ws, :main, "arbiter")
      assert %{requires: ["resume"]} = CapabilityMatrix.gate(ws, :resume, "other")
      assert CapabilityMatrix.gate(ws, :main, "other") == nil
    end
  end

  describe "workspace config validation" do
    test "capability_gates must be a boolean" do
      assert {:ok, _} =
               Ash.create(Workspace, %{
                 name: "cm-ok-#{System.unique_integer([:positive])}",
                 config: %{"routing" => %{"capability_gates" => true}}
               })

      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "cm-bad-#{System.unique_integer([:positive])}",
                 config: %{"routing" => %{"capability_gates" => "yes"}}
               })

      assert Exception.message(error) =~ "routing.capability_gates must be true or false"
    end

    test "repos.<repo>.requires must list known capabilities" do
      assert {:ok, _} =
               Ash.create(Workspace, %{
                 name: "cm-ok2-#{System.unique_integer([:positive])}",
                 config: %{
                   "routing" => %{
                     "repos" => %{"arbiter" => %{"requires" => ["async_verification"]}}
                   }
                 }
               })

      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "cm-bad2-#{System.unique_integer([:positive])}",
                 config: %{
                   "routing" => %{"repos" => %{"arbiter" => %{"requires" => ["teleport"]}}}
                 }
               })

      assert Exception.message(error) =~ "routing.repos.arbiter.requires"
    end
  end
end
