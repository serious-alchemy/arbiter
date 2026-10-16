defmodule Arbiter.Tasks.ClaimRoutingTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Claim, Workspace}
  alias Arbiter.Trackers.Shortcut.Config, as: SCConfig

  @env_var "ARBITER_CLAIM_ROUTING_TEST_TOKEN"
  @member "member-1"

  defp make_ws(claim_cfg, extra \\ %{}) do
    config =
      Map.merge(
        %{
          "tracker" => %{
            "type" => "shortcut",
            "config" => %{"credentials_ref" => "env:#{@env_var}"},
            "claim" => claim_cfg
          },
          "repo_paths" => %{"web" => System.tmp_dir!(), "server" => System.tmp_dir!()},
          "default_repo" => "server"
        },
        extra
      )

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "routing-#{System.unique_integer([:positive])}",
        prefix: "rt#{System.unique_integer([:positive])}",
        config: config
      })

    ws
  end

  setup do
    System.put_env(@env_var, "tok")

    on_exit(fn ->
      SCConfig.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp story_map(id, area, estimate) do
    %{
      "id" => String.to_integer(id),
      "name" => "Story #{id}",
      "description" => "d",
      "owner_ids" => [@member],
      "completed" => false,
      "started" => false,
      "estimate" => estimate,
      "custom_fields" => if(area, do: [%{"field_id" => "f-area", "value" => area}], else: [])
    }
  end

  defp stub_story(area, estimate) do
    Req.Test.stub(Arbiter.Trackers.Shortcut.HTTP, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/member"} ->
          Req.Test.json(conn, %{"id" => @member})

        {"GET", "/api/v3/custom-fields"} ->
          Req.Test.json(conn, [
            %{"id" => "f-area", "name" => "Technical Area"},
            %{"id" => "f-prio", "name" => "Priority"}
          ])

        {"GET", "/api/v3/stories/" <> id} when id in ~w(1 2 3 4 5 6 7 8) ->
          Req.Test.json(conn, story_map(id, area, estimate))

        {"GET", "/api/v3/epics/9/stories"} ->
          Req.Test.json(conn, [story_map("7", area, estimate)])

        {_, _} ->
          Req.Test.json(conn, [])
      end
    end)
  end

  @repo_from %{
    "repo_from" => %{
      "field" => "Technical Area",
      "map" => %{"Web app" => "web", "Server" => "server", "Mobile" => "nonexistent"}
    }
  }

  test "repo_from picks the repo from the mapped field" do
    ws = make_ws(@repo_from)
    stub_story("Web app", nil)
    assert {:ok, :created, task} = Claim.claim(ws, "1")
    assert task.repo == "web"
  end

  test "an explicit repo wins over repo_from" do
    ws = make_ws(@repo_from)
    stub_story("Web app", nil)
    assert {:ok, :created, task} = Claim.claim(ws, "2", repo: "server")
    assert task.repo == "server"
  end

  test "an unmapped value falls back to default_repo with a note" do
    ws = make_ws(@repo_from)
    stub_story("Embedded", nil)
    assert {:ok, :created, task} = Claim.claim(ws, "3")
    assert task.repo == "server"
    assert task.notes =~ "Technical Area"
    assert task.notes =~ "Embedded"
  end

  test "a value mapped to an unconfigured repo falls back with a note" do
    ws = make_ws(@repo_from)
    stub_story("Mobile", nil)
    assert {:ok, :created, task} = Claim.claim(ws, "4")
    assert task.repo == "server"
    assert task.notes =~ "nonexistent"
  end

  describe "an explicit repo is validated against repo_paths keys (bd-7u1b6n)" do
    test "claim maps a slug-shaped repo onto its configured key" do
      ws = make_ws(%{})
      stub_story(nil, nil)
      assert {:ok, :created, task} = Claim.claim(ws, "1", repo: "emricare/web")
      assert task.repo == "web"
    end

    test "claim refuses an unconfigured repo and lists the valid keys" do
      ws = make_ws(%{})
      stub_story(nil, nil)
      assert {:error, err} = Claim.claim(ws, "1", repo: "emricare/nowhere")
      assert inspect(err) =~ "emricare/nowhere"
      assert inspect(err) =~ "server"
      assert inspect(err) =~ "web"
    end

    test "bulk claim maps a slug and refuses an unconfigured repo per row" do
      ws = make_ws(%{})
      stub_story(nil, nil)

      assert {:ok, %{results: [%{status: "created", task_id: id}]}} =
               Claim.bulk(ws, {:epic, "9"}, yes: true, repo: "emricare/web")

      assert Ash.get!(Arbiter.Tasks.Issue, id).repo == "web"

      ws2 = make_ws(%{})

      assert {:ok, %{results: [%{status: "refused", reason: reason}]}} =
               Claim.bulk(ws2, {:epic, "9"}, yes: true, repo: "emricare/nowhere")

      assert reason =~ "server"
    end
  end

  test "difficulty_from_estimate seeds difficulty from points" do
    ws = make_ws(%{"difficulty_from_estimate" => %{"1" => 1, "5" => 3}})
    stub_story(nil, 5)
    assert {:ok, :created, task} = Claim.claim(ws, "5")
    assert task.difficulty == 3
  end

  test "explicit difficulty beats the estimate seed" do
    ws = make_ws(%{"difficulty_from_estimate" => %{"5" => 3}})
    stub_story(nil, 5)
    assert {:ok, :created, task} = Claim.claim(ws, "6", difficulty: 1)
    assert task.difficulty == 1
  end

  test "unmapped or missing estimate leaves difficulty unset" do
    ws = make_ws(%{"difficulty_from_estimate" => %{"5" => 3}})
    stub_story(nil, 8)
    assert {:ok, :created, t1} = Claim.claim(ws, "7")
    stub_story(nil, nil)
    assert {:ok, :created, t2} = Claim.claim(ws, "8")
    assert t1.difficulty == t2.difficulty
    refute t1.difficulty == 3
  end

  test "config validation rejects malformed claim blocks" do
    assert {:error, _} =
             Ash.create(Workspace, %{
               name: "bad-claim",
               prefix: "bcl",
               config: %{"tracker" => %{"claim" => %{"repo_from" => "Technical Area"}}}
             })

    assert {:error, _} =
             Ash.create(Workspace, %{
               name: "bad-claim2",
               prefix: "bcm",
               config: %{
                 "tracker" => %{"claim" => %{"difficulty_from_estimate" => %{"3" => 9}}}
               }
             })
  end
end
