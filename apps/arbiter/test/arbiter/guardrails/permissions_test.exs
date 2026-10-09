defmodule Arbiter.Guardrails.PermissionsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.Permissions

  describe "parse/1 — the vocabulary (§5.1)" do
    test "network: lower-cases the host and makes the port explicit" do
      assert {:ok, %{kind: :network, optional?: false, canonical: "network:api.example.com:443"}} =
               Permissions.parse("network:API.Example.com")

      assert {:ok, %{canonical: "network:api.example.com:8080"}} =
               Permissions.parse("network:api.example.com:8080")
    end

    test "a trailing ? after the kind marks the permission optional (§5.2)" do
      assert {:ok, %{kind: :network, optional?: true, canonical: "network?:status.example.com:443"}} =
               Permissions.parse("network?:status.example.com")

      assert {:ok, %{kind: :tracker_write, optional?: true, canonical: "tracker_write?"}} =
               Permissions.parse("tracker_write?")

      assert {:ok, %{kind: :secrets, optional?: true, canonical: "secrets?:broker_demo"}} =
               Permissions.parse("secrets?:broker_demo")
    end

    test "the plain actions and the data class" do
      for name <- ~w(tracker_write prod_read prod_ssh phi_data) do
        assert {:ok, %{canonical: ^name}} = Permissions.parse(name)
      end

      assert {:ok, %{kind: :secrets, canonical: "secrets:broker_demo"}} =
               Permissions.parse("secrets:broker_demo")
    end

    test "prod permissions and data classes are never optional (§5.7)" do
      for name <- ~w(prod_read? prod_ssh? phi_data?) do
        assert {:error, msg} = Permissions.parse(name)
        assert msg =~ "optional"
      end
    end

    test "rejects anything outside the vocabulary" do
      assert {:error, _} = Permissions.parse("root")
      assert {:error, _} = Permissions.parse("network:")
      assert {:error, _} = Permissions.parse("network:bad host")
      assert {:error, _} = Permissions.parse("network:example.com:0")
      assert {:error, _} = Permissions.parse("network:example.com:70000")
      assert {:error, _} = Permissions.parse("secrets:")
      assert {:error, _} = Permissions.parse("prod_read:extra")
      assert {:error, _} = Permissions.parse("")
      assert {:error, _} = Permissions.parse(nil)
    end
  end

  describe "normalize/1 — canonical, sorted, de-duplicated (§5.2)" do
    test "sorts and de-duplicates after canonicalising" do
      assert {:ok, ["network:a.example.com:443", "phi_data", "prod_read"]} =
               Permissions.normalize([
                 "prod_read",
                 "phi_data",
                 "network:A.example.com",
                 "network:a.example.com:443",
                 "prod_read"
               ])
    end

    test "nil is the empty list; one bad entry names itself" do
      assert {:ok, []} = Permissions.normalize(nil)
      assert {:error, msg} = Permissions.normalize(["prod_read", "bogus"])
      assert msg =~ "bogus"
    end

    test "a non-list is refused" do
      assert {:error, _} = Permissions.normalize("prod_read")
    end
  end

  describe "grant_by/2 — who may grant (§5.1, §7.1)" do
    test "the table's defaults without any binding" do
      assert Permissions.grant_by("network:a.example.com:443", %{}) == :coordinator
      assert Permissions.grant_by("tracker_write", %{}) == :coordinator
      assert Permissions.grant_by("secrets:broker_demo", %{}) == :coordinator
      assert Permissions.grant_by("prod_ssh", %{}) == :operator
      # prod_read is coordinator-grantable only when the binding enforces read-only.
      assert Permissions.grant_by("prod_read", %{}) == :operator
    end

    test "prod_read follows the binding's enforced_read_only" do
      ro = %{"bindings" => %{"prod_read" => %{"enforced_read_only" => true}}}
      rw = %{"bindings" => %{"prod_read" => %{"enforced_read_only" => false}}}
      assert Permissions.grant_by("prod_read", ro) == :coordinator
      assert Permissions.grant_by("prod_read", rw) == :operator
    end

    test "secrets: tagged prod need the operator" do
      block = %{"bindings" => %{"secrets:db" => %{"tags" => ["prod"]}}}
      assert Permissions.grant_by("secrets:db", block) == :operator
      assert Permissions.grant_by("secrets:other", block) == :coordinator
    end

    test "an explicit binding grant_by wins; the optional marker is ignored for lookup" do
      block = %{
        "bindings" => %{
          "prod_ssh" => %{"grant_by" => "coordinator"},
          "network:api.example.com" => %{"grant_by" => "operator"}
        }
      }

      assert Permissions.grant_by("prod_ssh", block) == :coordinator
      assert Permissions.grant_by("network?:api.example.com:443", block) == :operator
    end

    test "phi_data is fixed: anyone may add it, only the operator may remove it" do
      assert Permissions.grant_by("phi_data", %{"bindings" => %{"phi_data" => %{"grant_by" => "operator"}}}) ==
               :coordinator
    end
  end

  describe "plan/4 — declaring and removing, by authority (§5.3)" do
    test "an operator declaration is `declared` for everything" do
      assert {:ok, [%{permission: "prod_ssh", event: :declared}]} =
               Permissions.plan([], ["prod_ssh"], :operator, %{})
    end

    test "a coordinator declaring an operator-grant permission records `requested`" do
      assert {:ok, [%{permission: "prod_ssh", event: :requested}]} =
               Permissions.plan([], ["prod_ssh"], :coordinator, %{})

      assert {:ok, [%{permission: "tracker_write", event: :declared}]} =
               Permissions.plan([], ["tracker_write"], :coordinator, %{})
    end

    test "a restricted caller (worker, refine, no token) can add or remove nothing" do
      assert {:error, msg} = Permissions.plan([], ["tracker_write"], :restricted, %{})
      assert msg =~ "coordinator"
      assert {:error, _} = Permissions.plan(["tracker_write"], [], :restricted, %{})
    end

    test "anyone but a restricted caller may add phi_data" do
      assert {:ok, [%{permission: "phi_data", event: :declared}]} =
               Permissions.plan([], ["phi_data"], :coordinator, %{})
    end

    test "removing an action permission tightens: a coordinator may" do
      assert {:ok, [%{permission: "prod_read", event: :revoked}]} =
               Permissions.plan(["prod_read"], [], :coordinator, %{})
    end

    test "removing a data class loosens: only the operator may" do
      assert {:error, msg} = Permissions.plan(["phi_data"], [], :coordinator, %{})
      assert msg =~ "phi_data"
      assert msg =~ "operator"

      assert {:ok, [%{permission: "phi_data", event: :revoked}]} =
               Permissions.plan(["phi_data"], [], :operator, %{})
    end

    test "no difference, no events" do
      assert {:ok, []} = Permissions.plan(["prod_read"], ["prod_read"], :restricted, %{})
    end

    test "a mixed change reports every event, removals and additions" do
      assert {:ok, events} =
               Permissions.plan(["prod_read"], ["tracker_write"], :coordinator, %{})

      assert Enum.sort(Enum.map(events, &{&1.permission, &1.event})) ==
               [{"prod_read", :revoked}, {"tracker_write", :declared}]
    end
  end

  describe "authorize_decision/3 — grant / deny of a pending permission" do
    test "the binding's authority decides" do
      assert :ok = Permissions.authorize_decision("tracker_write", :coordinator, %{})
      assert :ok = Permissions.authorize_decision("prod_ssh", :operator, %{})
      assert {:error, msg} = Permissions.authorize_decision("prod_ssh", :coordinator, %{})
      assert msg =~ "operator"
      assert {:error, _} = Permissions.authorize_decision("tracker_write", :restricted, %{})
    end
  end

  describe "defaults/2 — workspace and repo defaults (§5.3 (1))" do
    test "workspace defaults then the repo's, each tagged with its source" do
      block = %{
        "defaults" => %{"permissions" => ["network:repo.hex.pm"]},
        "repos" => %{"tonic" => %{"defaults" => %{"permissions" => ["phi_data"]}}}
      }

      assert Permissions.defaults(block, "tonic") == [
               {"network:repo.hex.pm:443", :workspace_default},
               {"phi_data", :repo_default}
             ]

      assert Permissions.defaults(block, "other") == [{"network:repo.hex.pm:443", :workspace_default}]
      assert Permissions.defaults(%{}, "tonic") == []
    end

    test "an unparsable default is dropped, not fatal" do
      block = %{"defaults" => %{"permissions" => ["bogus", "prod_read"]}}
      assert Permissions.defaults(block, nil) == [{"prod_read", :workspace_default}]
    end
  end
end
