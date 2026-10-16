defmodule Arbiter.Tasks.ClaimLinksTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Claim, Dependencies, Issue, Workspace}
  alias Arbiter.Trackers.Shortcut.Config, as: SCConfig

  @env_var "ARBITER_CLAIM_LINKS_TEST_TOKEN"
  @member "member-1"

  setup do
    System.put_env(@env_var, "tok")

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "links-sc",
        prefix: "lsc",
        config: %{
          "tracker" => %{
            "type" => "shortcut",
            "config" => %{"credentials_ref" => "env:#{@env_var}"}
          }
        }
      })

    on_exit(fn ->
      SCConfig.clear()
      System.delete_env(@env_var)
    end)

    {:ok, ws: ws}
  end

  defp link(subject, object, verb),
    do: %{"subject_id" => subject, "object_id" => object, "verb" => verb}

  defp stub_shortcut(links_by_id) do
    Req.Test.stub(Arbiter.Trackers.Shortcut.HTTP, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/member"} ->
          Req.Test.json(conn, %{"id" => @member})

        {"GET", "/api/v3/stories/" <> id} when id in ["1", "2", "3"] ->
          Req.Test.json(conn, %{
            "id" => String.to_integer(id),
            "name" => "Story #{id}",
            "description" => "d",
            "owner_ids" => [@member],
            "completed" => false,
            "started" => false,
            "story_links" => Map.get(links_by_id, id, [])
          })

        {_, _} ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end
    end)
  end

  defp edges(task), do: Dependencies.for_issue(task.id)

  test "blocks link between two claimed stories becomes a blocks edge, claimed in either order",
       %{ws: ws} do
    both = [link(1, 2, "blocks")]
    stub_shortcut(%{"1" => both, "2" => both})

    {:ok, :created, a} = Claim.claim(ws, "1")
    {:ok, :created, b} = Claim.claim(ws, "2")

    assert [%{issue_id: id}] = edges(a).blocks
    assert id == b.id
    assert [%{issue_id: id}] = edges(b).blocked_by
    assert id == a.id

    # re-claim is idempotent: no second edge, no duplicate notes
    {:ok, :existing, _} = Claim.claim(ws, "2")
    assert [_] = edges(a).blocks
  end

  test "link to an unclaimed story is recorded in notes, and the edge appears on later claim",
       %{ws: ws} do
    links = [link(1, 2, "blocks"), link(3, 1, "relates to")]
    stub_shortcut(%{"1" => links, "2" => links, "3" => links})

    {:ok, :created, a} = Claim.claim(ws, "1")
    a = Ash.get!(Issue, a.id)
    assert a.notes =~ "blocks 2"
    assert a.notes =~ "relates to 3"
    assert edges(a).blocks == []

    {:ok, :created, b} = Claim.claim(ws, "2")
    assert [_] = edges(a).blocks
    assert edges(b).blocked_by != []

    {:ok, :created, c} = Claim.claim(ws, "3")
    assert [%{issue_id: id}] = edges(c).relates_to
    assert id == a.id

    # re-claiming does not duplicate the note
    {:ok, :existing, _} = Claim.claim(ws, "1")
    assert Ash.get!(Issue, a.id).notes |> String.split("blocks 2") |> length() == 2
  end

  test "a link that would form a cycle is rejected with a note", %{ws: ws} do
    links = [link(1, 2, "blocks"), link(2, 1, "blocks")]
    stub_shortcut(%{"1" => links, "2" => links})

    {:ok, :created, a} = Claim.claim(ws, "1")
    {:ok, :created, b} = Claim.claim(ws, "2")

    assert [_] = edges(a).blocks
    assert edges(b).blocks == []
    assert Ash.get!(Issue, b.id).notes =~ "cycle"
  end
end
