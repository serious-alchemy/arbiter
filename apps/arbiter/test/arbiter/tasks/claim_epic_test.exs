defmodule Arbiter.Tasks.ClaimEpicTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Claim, Dependencies, Issue, Workspace}
  alias Arbiter.Trackers.GitHub.Config, as: GHConfig
  alias Arbiter.Trackers.Shortcut.Config, as: SCConfig

  require Ash.Query

  @env_var "ARBITER_CLAIM_EPIC_TEST_TOKEN"
  @member "member-1"

  setup do
    System.put_env(@env_var, "tok")

    {:ok, sc_ws} =
      Ash.create(Workspace, %{
        name: "epic-sc",
        prefix: "esc",
        config: %{
          "tracker" => %{
            "type" => "shortcut",
            "config" => %{"credentials_ref" => "env:#{@env_var}"}
          }
        }
      })

    {:ok, gh_ws} =
      Ash.create(Workspace, %{
        name: "epic-gh",
        prefix: "egh",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{
              "owner" => "o",
              "repo" => "r",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    on_exit(fn ->
      GHConfig.clear()
      SCConfig.clear()
      System.delete_env(@env_var)
    end)

    {:ok, sc_ws: sc_ws, gh_ws: gh_ws}
  end

  defp stub_shortcut(stories) do
    Req.Test.stub(Arbiter.Trackers.Shortcut.HTTP, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/member"} ->
          Req.Test.json(conn, %{"id" => @member})

        {"GET", "/api/v3/epics/1026"} ->
          Req.Test.json(conn, %{"id" => 1026, "name" => "Big Epic", "description" => "Epic body"})

        {"GET", "/api/v3/stories/" <> id} ->
          case Map.fetch(stories, id) do
            {:ok, story} -> Req.Test.json(conn, story)
            :error -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
          end

        {_, _} ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end
    end)
  end

  defp story(id, epic_id) do
    %{
      "id" => id,
      "name" => "Story #{id}",
      "description" => "d",
      "owner_ids" => [@member],
      "completed" => false,
      "started" => false,
      "epic_id" => epic_id
    }
  end

  defp epics(ws) do
    Issue |> Ash.Query.filter(workspace_id == ^ws.id and issue_type == :epic) |> Ash.read!()
  end

  describe "claim/3 mirrors tracker epics — Shortcut" do
    test "creates one epic on first claim, reuses it, auto-closes when children close", %{
      sc_ws: ws
    } do
      stub_shortcut(%{"1" => story(1, 1026), "2" => story(2, 1026), "3" => story(3, nil)})

      assert {:ok, :created, a} = Claim.claim(ws, "1")
      assert [epic] = epics(ws)
      assert epic.title == "Big Epic"
      assert epic.auto_close == true
      assert epic.tracker_ref =~ "1026"
      assert %{children: [%{issue_id: id1}]} = Dependencies.for_issue(epic.id)
      assert id1 == a.id

      assert {:ok, :created, b} = Claim.claim(ws, "2")
      assert [epic2] = epics(ws)
      assert epic2.id == epic.id
      assert %{children: kids} = Dependencies.for_issue(epic.id)
      assert Enum.sort(Enum.map(kids, & &1.issue_id)) == Enum.sort([a.id, b.id])

      # re-claiming an existing story adds no second epic and no second edge
      assert {:ok, :existing, _} = Claim.claim(ws, "2")
      assert [_] = epics(ws)
      assert %{children: [_, _]} = Dependencies.for_issue(epic.id)

      # a story outside any epic gets no parent
      assert {:ok, :created, _} = Claim.claim(ws, "3")
      assert [_] = epics(ws)

      for t <- [a, b] do
        {:ok, t} = Ash.update(t, %{}, action: :start)
        {:ok, _} = Ash.update(t, %{reason: "done", close_upstream: false}, action: :close)
      end

      assert Ash.get!(Issue, epic.id).state == :closed
    end
  end

  describe "claim/3 mirrors tracker epics — GitHub milestone" do
    test "links claimed issues to one epic per milestone", %{gh_ws: ws} do
      issue = fn n ->
        %{
          "number" => n,
          "title" => "Issue #{n}",
          "body" => "b",
          "state" => "open",
          "labels" => [],
          "assignees" => [%{"login" => @member}],
          "milestone" => %{"number" => 7, "title" => "v1 release", "description" => "ms"}
        }
      end

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} -> Req.Test.json(conn, %{"login" => @member})
          {"GET", "/repos/o/r/issues/1"} -> Req.Test.json(conn, issue.(1))
          {"GET", "/repos/o/r/issues/2"} -> Req.Test.json(conn, issue.(2))
          {"GET", _} -> Req.Test.json(conn, [])
          _ -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, :created, a} = Claim.claim(ws, "1")
      assert {:ok, :created, b} = Claim.claim(ws, "2")
      assert [epic] = epics(ws)
      assert epic.title == "v1 release"
      assert epic.auto_close
      assert %{children: kids} = Dependencies.for_issue(epic.id)
      assert Enum.sort(Enum.map(kids, & &1.issue_id)) == Enum.sort([a.id, b.id])
    end
  end
end
