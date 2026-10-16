defmodule Arbiter.Tasks.ClaimAcceptanceTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Claim, Issue, Workspace}
  alias Arbiter.Trackers.Shortcut.Config, as: SCConfig

  @env_var "ARBITER_CLAIM_ACC_TEST_TOKEN"
  @member "member-1"

  setup do
    System.put_env(@env_var, "tok")

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "acc-sc",
        prefix: "asc",
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

  defp stub_story(extra) do
    Req.Test.stub(Arbiter.Trackers.Shortcut.HTTP, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/member"} ->
          Req.Test.json(conn, %{"id" => @member})

        {"GET", "/api/v3/stories/" <> id} when id == "1" ->
          Req.Test.json(
            conn,
            Map.merge(
              %{
                "id" => String.to_integer(id),
                "name" => "Story #{id}",
                "description" => "d",
                "story_type" => "feature",
                "owner_ids" => [@member],
                "completed" => false,
                "started" => false
              },
              extra
            )
          )

        {_, _} ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end
    end)
  end

  test "story tasks become acceptance items", %{ws: ws} do
    stub_story(%{"tasks" => [%{"description" => "do a", "complete" => false}]})
    {:ok, :created, t} = Claim.claim(ws, "1")
    assert Ash.get!(Issue, t.id).acceptance == "- [ ] do a"
    assert Ash.get!(Issue, t.id).acceptance_waived == nil
  end

  test "a description section becomes the acceptance text", %{ws: ws} do
    stub_story(%{"description" => "Bug\n\nExpected: it works"})
    {:ok, :created, t} = Claim.claim(ws, "1")
    assert Ash.get!(Issue, t.id).acceptance == "it works"
  end

  test "otherwise the tracker-spec waiver is recorded and promote needs no manual waiver",
       %{ws: ws} do
    stub_story(%{})
    {:ok, :created, t} = Claim.claim(ws, "1")
    t = Ash.get!(Issue, t.id)
    assert t.acceptance_waived == Issue.tracker_spec_waiver()
    assert {:ok, ready} = Ash.update(t, %{}, action: :promote_to_ready)
    assert ready.state == :queued or ready.state == :ready
  end
end
