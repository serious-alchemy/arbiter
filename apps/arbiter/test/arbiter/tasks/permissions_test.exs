defmodule Arbiter.Tasks.PermissionsTest do
  @moduledoc """
  bd-54m4vv (G12): `issues.permissions`, the append-only `permission_events`
  trail, `ResolvePermissions` defaults at creation and the `grant_by`
  authority checks (`docs/design/guardrail-profiles.md` §5.1–5.3).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PermissionEvent
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace

  setup do
    prior = Application.get_env(:arbiter, :repo_paths)
    Application.delete_env(:arbiter, :repo_paths)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, :repo_paths, prior),
        else: Application.delete_env(:arbiter, :repo_paths)
    end)

    :ok
  end

  defp ws!(guardrails \\ nil) do
    config =
      %{"repo_paths" => %{"tonic" => "/srv/tonic", "arbiter" => "/srv/arbiter"}}
      |> then(&if(guardrails, do: Map.put(&1, "guardrails", guardrails), else: &1))

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "perm-#{System.unique_integer([:positive])}",
        prefix: "pm",
        config: config
      })

    ws
  end

  defp create(ws, attrs \\ %{}, context \\ %{}) do
    Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, repo: "arbiter"}, attrs),
      context: context
    )
  end

  defp coordinator(extra \\ %{}),
    do: Map.merge(%{guardrail_authority: :coordinator, permission_actor: "coordinator:test"}, extra)

  defp operator, do: %{guardrail_authority: :operator, permission_actor: "operator:cli"}
  defp restricted, do: %{guardrail_authority: :restricted, permission_actor: "worker:x"}

  defp events(issue), do: issue |> Permissions.events() |> Enum.map(&{&1.permission, &1.event, &1.source})

  describe "the field" do
    test "defaults to [] and records no events" do
      {:ok, issue} = create(ws!())
      assert issue.permissions == []
      assert Permissions.events(issue) == []
    end

    test "a declaration is stored canonical, sorted and de-duplicated" do
      {:ok, issue} =
        create(
          ws!(),
          %{permissions: ["tracker_write", "network:API.example.com", "network:api.example.com:443"]},
          coordinator()
        )

      assert issue.permissions == ["network:api.example.com:443", "tracker_write"]
    end

    test "an unknown permission is a validation error on :permissions" do
      assert {:error, %Ash.Error.Invalid{} = err} =
               create(ws!(), %{permissions: ["root"]}, coordinator())

      assert Enum.any?(err.errors, &(Map.get(&1, :field) == :permissions))
    end
  end

  describe "create — the filer (§5.3 (2))" do
    test "a coordinator's declaration is `declared`, source filer, with the actor" do
      {:ok, issue} = create(ws!(), %{permissions: ["tracker_write"]}, coordinator())

      assert events(issue) == [{"tracker_write", :declared, :filer}]
      assert [%{actor: "coordinator:test", issue_id: id}] = Permissions.events(issue)
      assert id == issue.id
    end

    test "an operator-grant permission declared by a coordinator is `requested` and pending" do
      {:ok, issue} = create(ws!(), %{permissions: ["prod_ssh", "tracker_write"]}, coordinator())

      assert Enum.sort(events(issue)) ==
               [{"prod_ssh", :requested, :filer}, {"tracker_write", :declared, :filer}]

      assert Permissions.pending(issue) == ["prod_ssh"]
      assert Permissions.in_force(issue) == ["tracker_write"]
    end

    test "the operator's declaration of the same permission is in force" do
      {:ok, issue} = create(ws!(), %{permissions: ["prod_ssh"]}, operator())
      assert events(issue) == [{"prod_ssh", :declared, :filer}]
      assert Permissions.pending(issue) == []
      assert Permissions.in_force(issue) == ["prod_ssh"]
    end

    test "a binding can make prod_read coordinator-grantable" do
      ws = ws!(%{"bindings" => %{"prod_read" => %{"enforced_read_only" => true}}})
      {:ok, issue} = create(ws, %{permissions: ["prod_read"]}, coordinator())
      assert Permissions.pending(issue) == []
    end

    test "a restricted caller (worker / refine) cannot declare anything" do
      assert {:error, %Ash.Error.Invalid{} = err} =
               create(ws!(), %{permissions: ["tracker_write"]}, restricted())

      assert Enum.any?(err.errors, &(Map.get(&1, :field) == :permissions))
    end

    test "a create that declares nothing needs no authority at all" do
      assert {:ok, _} = create(ws!(), %{}, restricted())
    end
  end

  describe "create — workspace and repo defaults (§5.3 (1))" do
    setup do
      ws =
        ws!(%{
          "defaults" => %{"permissions" => ["network:repo.hex.pm"]},
          "repos" => %{"tonic" => %{"defaults" => %{"permissions" => ["phi_data"]}}}
        })

      %{ws: ws}
    end

    test "records `defaulted` events with their source", %{ws: ws} do
      {:ok, issue} = create(ws, %{repo: "tonic"})

      assert issue.permissions == ["network:repo.hex.pm:443", "phi_data"]

      assert Enum.sort(events(issue)) == [
               {"network:repo.hex.pm:443", :defaulted, :workspace_default},
               {"phi_data", :defaulted, :repo_default}
             ]
    end

    test "another repo gets only the workspace defaults", %{ws: ws} do
      {:ok, issue} = create(ws, %{repo: "arbiter"})
      assert issue.permissions == ["network:repo.hex.pm:443"]
    end

    test "defaults are not re-recorded when the filer already declared the permission", %{ws: ws} do
      {:ok, issue} = create(ws, %{repo: "tonic", permissions: ["phi_data"]}, coordinator())

      assert Enum.sort(events(issue)) == [
               {"network:repo.hex.pm:443", :defaulted, :workspace_default},
               {"phi_data", :declared, :filer}
             ]
    end

    test "defaults apply even to a restricted caller: they are operator config", %{ws: ws} do
      {:ok, issue} = create(ws, %{repo: "tonic"}, restricted())
      assert "phi_data" in issue.permissions
    end
  end

  describe "update" do
    test "adding and removing record declared / revoked" do
      {:ok, issue} = create(ws!(), %{permissions: ["tracker_write"]}, coordinator())

      {:ok, issue} =
        Ash.update(issue, %{permissions: ["prod_read"]}, context: coordinator())

      assert issue.permissions == ["prod_read"]

      assert Enum.sort(events(issue)) ==
               [
                 {"prod_read", :requested, :filer},
                 {"tracker_write", :declared, :filer},
                 {"tracker_write", :revoked, :filer}
               ]
    end

    test "removing a data class is operator-only" do
      {:ok, issue} = create(ws!(), %{permissions: ["phi_data"]}, coordinator())

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(issue, %{permissions: []}, context: coordinator())

      assert {:ok, %{permissions: []}} = Ash.update(issue, %{permissions: []}, context: operator())
    end

    test "a restricted caller cannot touch permissions, but other fields update fine" do
      {:ok, issue} = create(ws!(), %{permissions: ["tracker_write"]}, coordinator())

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(issue, %{permissions: []}, context: restricted())

      assert {:ok, %{notes: "n", permissions: ["tracker_write"]}} =
               Ash.update(issue, %{notes: "n"}, context: restricted())
    end

    test "an unchanged permissions list records nothing" do
      {:ok, issue} = create(ws!(), %{permissions: ["tracker_write"]}, coordinator())
      {:ok, issue} = Ash.update(issue, %{permissions: ["tracker_write"]}, context: restricted())
      assert length(Permissions.events(issue)) == 1
    end
  end

  describe "grant / deny — the grant_by authority (§5.3 (2), §6.4)" do
    setup do
      {:ok, issue} = create(ws!(), %{permissions: ["prod_ssh"]}, coordinator())
      %{issue: issue}
    end

    test "a coordinator cannot grant an operator-grant permission", %{issue: issue} do
      assert {:error, msg} =
               Permissions.grant(issue, "prod_ssh", authority: :coordinator, actor: "coordinator:test")

      assert msg =~ "operator"
      assert Permissions.pending(Ash.get!(Issue, issue.id)) == ["prod_ssh"]
    end

    test "the operator grants it: in force, `granted` recorded with the reason", %{issue: issue} do
      assert {:ok, issue} =
               Permissions.grant(issue, "prod_ssh",
                 authority: :operator,
                 actor: "operator:cli",
                 reason: "needed for the deploy check"
               )

      assert Permissions.pending(issue) == []
      assert Permissions.in_force(issue) == ["prod_ssh"]
      assert {"prod_ssh", :granted, :system} in events(issue)

      assert %{reason: "needed for the deploy check", actor: "operator:cli"} =
               issue |> Permissions.events() |> List.last()
    end

    test "the operator denies it: removed from the ticket, `denied` recorded", %{issue: issue} do
      assert {:ok, issue} =
               Permissions.deny(issue, "prod_ssh",
                 authority: :operator,
                 actor: "operator:cli",
                 reason: "no"
               )

      assert issue.permissions == []
      assert Permissions.pending(issue) == []
      assert {"prod_ssh", :denied, :system} in events(issue)
    end

    test "a coordinator decides a coordinator-grant permission" do
      {:ok, issue} = create(ws!(), %{}, coordinator())
      {:ok, issue} = Permissions.suggest(issue, "tracker_write", reason: "mentions the tracker", actor: "refine:x")

      assert Permissions.pending(issue) == []
      assert issue.permissions == []

      assert {:ok, issue} = Permissions.grant(issue, "tracker_write", authority: :coordinator, actor: "c")
      assert issue.permissions == ["tracker_write"]
      assert Permissions.in_force(issue) == ["tracker_write"]
    end

    test "a restricted caller decides nothing", %{issue: issue} do
      assert {:error, _} = Permissions.grant(issue, "prod_ssh", authority: :restricted, actor: "w")
      assert {:error, _} = Permissions.deny(issue, "prod_ssh", authority: :restricted, actor: "w")
    end

    test "only a requested or suggested permission can be decided", %{issue: issue} do
      assert {:error, msg} = Permissions.grant(issue, "tracker_write", authority: :operator, actor: "o")
      assert msg =~ "nothing to decide"
    end
  end

  describe "suggest — inference never grants (§5.3 (3))" do
    test "records `suggested` / source refine and changes nothing else" do
      {:ok, issue} = create(ws!())

      assert {:ok, issue} =
               Permissions.suggest(issue, "prod_read",
                 reason: "description mentions prod",
                 actor: "refine:abc"
               )

      assert issue.permissions == []
      assert Permissions.in_force(issue) == []
      assert events(issue) == [{"prod_read", :suggested, :refine}]
    end

    test "an unparsable suggestion is refused" do
      {:ok, issue} = create(ws!())
      assert {:error, _} = Permissions.suggest(issue, "root", actor: "refine:abc")
    end
  end

  describe "PermissionEvent is append-only" do
    test "has no update or destroy action" do
      actions = PermissionEvent |> Ash.Resource.Info.actions() |> Enum.map(& &1.type)
      assert Enum.sort(Enum.uniq(actions)) == [:create, :read]
    end
  end
end
