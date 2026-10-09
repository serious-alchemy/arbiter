defmodule Arbiter.Guardrails.ProjectionTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.Profile
  alias Arbiter.Guardrails.Projection

  @block %{
    "bindings" => %{
      "prod_read" => %{
        "enforced_read_only" => true,
        "tunnels" => ["replica.internal:5432"],
        "env_from_secret" => %{"RO_DATABASE_URL" => "prod_ro_url"}
      },
      "prod_ssh" => %{
        "hosts" => ["prod.internal"],
        "ssh_key_secret" => "prod_ssh_key"
      },
      "secrets:broker_demo" => %{"env_from_secret" => %{"BROKER_KEY" => "broker_demo_key"}},
      "tracker_write" => %{"token_secret" => "github_worker_token"}
    }
  }

  defp profile(tier, permissions \\ nil) do
    %Profile{
      tier: tier,
      permissions:
        permissions ||
          case tier do
            :quarantine -> []
            :probation -> ["network:"]
            :trusted -> ["network:", "tracker_write", "secrets:"]
            :privileged -> ["network:", "tracker_write", "secrets:", "prod_read", "prod_ssh"]
          end
    }
  end

  defp build(perms, tier, opts \\ []) do
    Projection.build(perms, [profile: profile(tier), block: @block] ++ opts)
  end

  describe "guarded?" do
    test "no profile means guardrails are off: nothing is withheld by this module" do
      p = Projection.build(["prod_ssh"], profile: nil, block: @block)
      refute p.guarded?
    end

    test "sealed/0 is guarded and projects nothing" do
      p = Projection.sealed()
      assert p.guarded?
      assert p.env == [] and p.hosts == [] and p.tunnels == [] and p.ssh == nil
      assert p.claims == []
    end
  end

  describe "undeclared means withheld" do
    test "no permissions: nothing is projected" do
      p = build([], :privileged)
      assert p.guarded?

      assert %{env: [], hosts: [], tunnels: [], ssh: nil, claims: [], granted: [], withheld: []} =
               p
    end
  end

  describe "network:" do
    test "adds host:port to the allowlist (probation may hold it)" do
      p = build(["network:api.tradovate.com:443"], :probation)
      assert p.hosts == ["api.tradovate.com:443"]
      assert p.granted == ["network:api.tradovate.com:443"]
    end

    test "an optional network permission projects like a required one" do
      p = build(["network?:status.example.com:443"], :probation)
      assert p.hosts == ["status.example.com:443"]
    end

    test "quarantine may hold no network grants" do
      p = build(["network:api.example.com:443"], :quarantine)
      assert p.hosts == []
      assert [%{permission: "network:api.example.com:443", reason: reason}] = p.withheld
      assert reason =~ "quarantine"
    end
  end

  describe "tracker_write" do
    test "trusted gets the token env, api.github.com and the MCP claim" do
      p = build(["tracker_write"], :trusted)
      assert p.env == [{"GH_TOKEN", "github_worker_token"}]
      assert "api.github.com:443" in p.hosts
      assert p.claims == ["tracker_write"]
    end

    test "names the env var the tracker token lands in, even with no binding token" do
      assert build(["tracker_write"], :trusted).tracker_env == "GH_TOKEN"
      assert build(["prod_read"], :privileged).tracker_env == nil

      block = %{"bindings" => %{"tracker_write" => %{"token_env" => "GITLAB_TOKEN"}}}
      p = Projection.build(["tracker_write"], profile: profile(:trusted), block: block)
      assert p.tracker_env == "GITLAB_TOKEN"
    end

    test "probation is below the default min_tier" do
      p = build(["tracker_write"], :probation)
      assert p.env == [] and p.claims == [] and p.hosts == []
      assert [%{permission: "tracker_write"}] = p.withheld
    end
  end

  describe "secrets:<name>" do
    test "projects the binding's env vars from the named secrets" do
      p = build(["secrets:broker_demo"], :trusted)
      assert p.env == [{"BROKER_KEY", "broker_demo_key"}]
    end

    test "a secret with no binding is withheld" do
      p = build(["secrets:unbound"], :privileged)
      assert p.env == []
      assert [%{reason: reason}] = p.withheld
      assert reason =~ "no binding"
    end

    test "a binding tagged prod needs privileged" do
      block = put_in(@block, ["bindings", "secrets:broker_demo", "tags"], ["prod"])

      trusted =
        Projection.build(["secrets:broker_demo"], profile: profile(:trusted), block: block)

      assert trusted.env == []

      priv =
        Projection.build(["secrets:broker_demo"], profile: profile(:privileged), block: block)

      assert priv.env == [{"BROKER_KEY", "broker_demo_key"}]
    end
  end

  describe "prod_read" do
    test "privileged gets the read credential and the tunnel" do
      p = build(["prod_read"], :privileged)
      assert p.env == [{"RO_DATABASE_URL", "prod_ro_url"}]
      assert p.tunnels == [{5432, "replica.internal", 5432}]
    end

    test "a LOCAL:HOST:PORT tunnel keeps its local port" do
      block =
        put_in(@block, ["bindings", "prod_read", "tunnels"], ["15432:replica.internal:5432"])

      p = Projection.build(["prod_read"], profile: profile(:privileged), block: block)
      assert p.tunnels == [{15_432, "replica.internal", 5432}]
    end

    test "trusted is withheld" do
      p = build(["prod_read"], :trusted)
      assert p.env == [] and p.tunnels == []
      assert [%{reason: reason}] = p.withheld
      assert reason =~ "privileged"
    end

    test "a profile that does not list the kind withholds it even at the right tier" do
      p =
        Projection.build(["prod_read"],
          profile: profile(:privileged, ["network:"]),
          block: @block
        )

      assert p.env == []
      assert [%{reason: reason}] = p.withheld
      assert reason =~ "profile"
    end
  end

  describe "prod_ssh" do
    test "privileged gets an ssh key to hold in a per-worker agent, plus host:22" do
      p = build(["prod_ssh"], :privileged)
      assert p.ssh == %{key_secret: "prod_ssh_key", hosts: ["prod.internal:22"]}
      assert "prod.internal:22" in p.hosts
      # the key is never an env var
      assert p.env == []
    end

    test "a binding with no ssh_key_secret is withheld" do
      block = update_in(@block, ["bindings", "prod_ssh"], &Map.delete(&1, "ssh_key_secret"))
      p = Projection.build(["prod_ssh"], profile: profile(:privileged), block: block)
      assert p.ssh == nil
      assert [%{reason: reason}] = p.withheld
      assert reason =~ "ssh_key_secret"
    end
  end

  test "a wildcard binding host never becomes a grant" do
    block =
      put_in(@block, ["bindings", "prod_read", "hosts"], ["*.internal:443", "db.internal:5432"])

    p = Projection.build(["prod_read"], profile: profile(:privileged), block: block)
    assert p.hosts == ["db.internal:5432"]
  end

  describe "data classes and roles" do
    test "phi_data projects no reach and is neither granted nor withheld" do
      p = build(["phi_data"], :privileged)
      assert p.granted == [] and p.withheld == []
    end

    test "a reviewer gets no action permissions at all" do
      p = build(["prod_read", "network:api.example.com:443"], :privileged, role: :reviewer)
      assert p.env == [] and p.hosts == [] and p.tunnels == []
      assert length(p.withheld) == 2
    end

    test "a profile outside its scope withholds everything" do
      p =
        Projection.build(["network:api.example.com:443"],
          profile: %{profile(:privileged) | in_scope?: false},
          block: @block
        )

      assert p.hosts == []
      assert [%{reason: reason}] = p.withheld
      assert reason =~ "scope"
    end
  end

  test "to_decision/1 is JSON-friendly and carries no secret values" do
    decision = Projection.to_decision(build(["prod_read", "prod_ssh"], :privileged))
    assert decision["granted"] == ["prod_read", "prod_ssh"]
    assert decision["env"] == ["RO_DATABASE_URL"]
    assert {:ok, _} = Jason.encode(decision)
    refute inspect(decision) =~ "prod_ro_url"
  end
end
