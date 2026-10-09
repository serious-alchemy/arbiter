defmodule Arbiter.Guardrails.ReportTest do
  @moduledoc "G11 AC4: the doctor reports the effective tier per workspace and flags inconsistent config."
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Report
  alias Arbiter.Tasks.Workspace

  defp workspace!(config, name \\ nil) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: name || "rep-#{System.unique_integer([:positive])}",
        prefix: "rp#{:rand.uniform(99_999)}",
        config: config
      })

    ws
  end

  defp kinds(report), do: report.issues |> Enum.map(& &1.kind) |> Enum.sort()

  test "nothing configured: inactive, no issues, no tiers" do
    ws = workspace!(%{})
    report = Report.build([ws], rules: [])

    assert report.active == false
    assert report.issues == []
    assert [%{subjects: subjects}] = report.workspaces
    assert subjects != []
    assert Enum.all?(subjects, &(&1.tier == nil and &1.guardrails == "off"))
  end

  test "reports the effective tier of each attached subject, per workspace" do
    rules = [%{match: %{provider: "claude"}, tier: :privileged}]

    capped =
      workspace!(%{
        "guardrails" => %{
          "subjects" => [%{"match" => %{"provider" => "claude"}, "max_tier" => "probation"}]
        }
      })

    plain = workspace!(%{})

    report = Report.build([capped, plain], rules: rules)
    assert report.active
    assert report.rules == 1

    tiers =
      Map.new(report.workspaces, fn w ->
        {w.workspace, w.subjects |> Enum.map(& &1.tier) |> Enum.uniq()}
      end)

    assert tiers[capped.name] == ["probation"]
    assert tiers[plain.name] == ["privileged"]

    # probation needs an egress allowlist and Claude (bwrap backend) has no egress
    # confinement here; the privileged workspace has nothing to flag.
    assert Enum.all?(
             report.issues,
             &(&1.kind == :egress_unenforceable and &1.workspace == capped.name)
           )

    assert report.issues != []
  end

  test "flags a guardrails block with no subject rules behind it (inert)" do
    ws =
      workspace!(%{
        "guardrails" => %{
          "subjects" => [%{"match" => %{"provider" => "claude"}, "max_tier" => "probation"}]
        }
      })

    report = Report.build([ws], rules: [])

    assert kinds(report) == [:inert_block]
    assert report.active == false
  end

  test "flags an unmatched subject (it runs as quarantine)" do
    ws = workspace!(%{})
    report = Report.build([ws], rules: [%{match: %{provider: "codex"}, tier: :trusted}])

    assert :unmatched_subject in kinds(report)
    assert [%{subjects: subjects}] = report.workspaces
    assert Enum.all?(subjects, &(&1.tier == "quarantine" and &1.matched == false))
  end

  test "flags a subject outside its rule's scope here" do
    ws = workspace!(%{}, "somewhere-else")
    rules = [%{match: %{provider: "claude"}, tier: :privileged, scope: %{"only-here" => []}}]

    assert :out_of_scope in kinds(Report.build([ws], rules: rules))
  end

  test "flags a tier the adapter cannot enforce on this host" do
    ws = workspace!(%{"agent" => %{"type" => "codex"}})
    report = Report.build([ws], rules: [%{match: %{provider: "codex"}, tier: :quarantine}])

    # codex has neither write nor egress confinement, and quarantine needs both
    assert :write_confinement_none in kinds(report)
    assert [%{subjects: subjects}] = report.workspaces
    assert Enum.all?(subjects, &(&1.enforceable == false))
  end

  test "flags a cap that matches no attached subject, and an unknown repo" do
    ws =
      workspace!(%{
        "repo_paths" => %{"real" => "/tmp/real"},
        "guardrails" => %{
          "subjects" => [%{"match" => %{"provider" => "antigravity"}, "max_tier" => "quarantine"}],
          "repos" => %{"ghost" => %{"defaults" => %{"permissions" => []}}}
        }
      })

    report = Report.build([ws], rules: [%{match: %{provider: "claude"}, tier: :privileged}])
    assert :dead_cap in kinds(report)
    assert :unknown_repo in kinds(report)
  end

  test "flags a binding no attached subject can reach" do
    ws =
      workspace!(%{
        "guardrails" => %{"bindings" => %{"prod_ssh" => %{"min_tier" => "privileged"}}}
      })

    report = Report.build([ws], rules: [%{match: %{provider: "claude"}, tier: :probation}])

    assert :unreachable_binding in kinds(report)
  end

  describe "binding secrets exist (G14, bd-ld8qde)" do
    defp with_secrets(guardrails, secrets) do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rep-#{System.unique_integer([:positive])}",
          prefix: "rp#{:rand.uniform(99_999)}",
          config: %{"guardrails" => guardrails},
          secrets: secrets
        })

      ws
    end

    @bindings %{
      "bindings" => %{
        "prod_read" => %{"env_from_secret" => %{"RO_URL" => "prod_ro_url"}},
        "prod_ssh" => %{"ssh_key_secret" => "prod_ssh_key", "hosts" => ["prod.internal:22"]},
        "tracker_write" => %{"token_secret" => "gh_token"}
      }
    }

    test "a binding naming a secret the workspace lacks is flagged, once per secret" do
      ws = with_secrets(@bindings, %{"prod_ro_url" => "x"})
      report = Report.build([ws], rules: [])

      missing =
        for %{kind: :binding_secret_missing, message: m} <- report.issues, do: m

      assert length(missing) == 2
      assert Enum.any?(missing, &(&1 =~ "prod_ssh_key" and &1 =~ "prod_ssh"))
      assert Enum.any?(missing, &(&1 =~ "gh_token" and &1 =~ "tracker_write"))
      refute Enum.any?(missing, &(&1 =~ "prod_ro_url"))
    end

    test "nothing to flag when every named secret exists" do
      ws =
        with_secrets(@bindings, %{"prod_ro_url" => "x", "prod_ssh_key" => "y", "gh_token" => "z"})

      refute :binding_secret_missing in kinds(Report.build([ws], rules: []))
    end

    test "a worker_env var of that name also satisfies it" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rep-#{System.unique_integer([:positive])}",
          prefix: "rp#{:rand.uniform(99_999)}",
          config: %{
            "guardrails" => %{
              "bindings" => %{"prod_read" => %{"env_from_secret" => %{"X" => "ro_tok"}}}
            }
          },
          worker_env: %{"ro_tok" => %{"value" => "v", "secret" => true}}
        })

      refute :binding_secret_missing in kinds(Report.build([ws], rules: []))
    end
  end

  test "posture/1 is string-keyed for the REST and MCP workspace surfaces" do
    ws = workspace!(%{})
    posture = Report.posture(ws, rules: [%{match: %{provider: "claude"}, tier: :trusted}])

    assert posture["active"] == true

    assert [%{"provider" => "claude", "tier" => "trusted", "min_mode" => "bypass"} | _] =
             posture["subjects"]

    assert posture["issues"] == []
  end
end
