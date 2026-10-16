defmodule ArbiterCli.Cmd.ClaimTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Claim

  @workspace_lookup {{"get", "/api/workspaces"},
                     {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]},
                      200}}

  test "missing ref exits non-zero" do
    {_out, err, code} = capture(fn -> Claim.run([]) end)
    assert code != 0
    assert err =~ "tracker ref"
  end

  test "too many positionals fail with usage" do
    {_out, err, code} = capture(fn -> Claim.run(["43", "44"]) end)
    assert code != 0
    assert err =~ "single positional"
  end

  test "happy path POSTs ref, prints created task" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "created",
          "task" => %{
            "id" => "bd-abc",
            "title" => "Wire it up",
            "state" => "backlog",
            "tracker_type" => "github",
            "tracker_ref" => "43"
          }
        }, 201}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43"]) end)
    assert code == 0
    assert out =~ "Claimed bd-abc"
    assert out =~ "Wire it up"
    assert out =~ "github:43"
  end

  test "existing task → 'Already claimed'" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "existing",
          "task" => %{
            "id" => "bd-abc",
            "title" => "Wire it up",
            "state" => "active",
            "tracker_type" => "github",
            "tracker_ref" => "43"
          }
        }, 200}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43"]) end)
    assert code == 0
    assert out =~ "Already claimed: bd-abc"
  end

  test "--repo prints a dispatch tip" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "created",
          "task" => %{
            "id" => "bd-abc",
            "title" => "T",
            "state" => "backlog",
            "tracker_type" => "github",
            "tracker_ref" => "43"
          }
        }, 201}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43", "--repo", "arbiter"]) end)
    assert code == 0
    assert out =~ "arb dispatch bd-abc arbiter"
  end

  test "--repo forwards as repo in the POST body" do
    parent = self()

    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{
           "status" => "created",
           "task" => %{
             "id" => "bd-abc",
             "title" => "T",
             "state" => "backlog",
             "tracker_type" => "github",
             "tracker_ref" => "43",
             "repo" => "arbiter"
           }
         })
       end}
    ])

    {_out, _err, code} = capture(fn -> Claim.run(["43", "--repo", "arbiter"]) end)
    assert code == 0

    assert_received {:posted, body}
    assert body["repo"] == "arbiter"
  end

  test "--json emits JSON" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "status" => "created",
          "task" => %{
            "id" => "bd-abc",
            "tracker_ref" => "43"
          }
        }, 201}}
    ])

    {out, _err, code} = capture(fn -> Claim.run(["43", "--json"]) end)
    assert code == 0
    assert {:ok, decoded} = Jason.decode(String.trim(out))
    assert decoded["status"] == "created"
  end

  describe "--json purity" do
    test "`arb issue claim --json` keeps stdout to one JSON document; the notice is on stderr" do
      stub_routes([
        @workspace_lookup,
        {{"post", "/api/workspaces/ws-1/claim"},
         {%{"status" => "created", "task" => %{"id" => "bd-abc", "tracker_ref" => "43"}}, 201}}
      ])

      {out, err, code} =
        capture(fn -> ArbiterCli.Main.main(["issue", "claim", "43", "--json"]) end)

      assert code == 0
      assert err =~ "deprecated"
      refute out =~ "deprecated"
      assert {:ok, %{"status" => "created"}} = Jason.decode(out)
      assert String.split(String.trim_trailing(out), "\n") |> length() == 1
    end
  end

  describe "bulk (--epic / --query)" do
    @bulk_resp %{
      "applied" => false,
      "data" => [
        %{"ref" => "41", "title" => "Done already", "status" => "existing", "task_id" => "bd-1"},
        %{"ref" => "42", "title" => "Fresh", "status" => "would_create"}
      ]
    }

    defp bulk_stub(resp) do
      parent = self()

      stub_routes([
        @workspace_lookup,
        {{"post", "/api/workspaces/ws-1/claim"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:posted, Jason.decode!(body)})
           Req.Test.json(conn, resp)
         end}
      ])
    end

    test "--epic previews by default and says how to proceed" do
      bulk_stub(@bulk_resp)
      {out, _err, code} = capture(fn -> Claim.run(["--epic", "9"]) end)
      assert code == 0
      assert_received {:posted, body}
      assert body["epic"] == "9"
      refute body["yes"]
      assert out =~ "Preview"
      assert out =~ "would_create"
      assert out =~ "existing"
      assert out =~ "--yes"
    end

    test "--query --yes --repo forwards options and prints a summary" do
      bulk_stub(%{
        "applied" => true,
        "data" => [
          %{"ref" => "42", "title" => "Fresh", "status" => "created", "task_id" => "bd-2"},
          %{"ref" => "43", "title" => "Nope", "status" => "refused", "reason" => "not assigned"}
        ]
      })

      {out, _err, code} =
        capture(fn -> Claim.run(["--query", "label:x", "--yes", "--repo", "r", "--force"]) end)

      assert code == 0
      assert_received {:posted, body}
      assert body["query"] == "label:x"
      assert body["yes"] == true
      assert body["repo"] == "r"
      assert body["force"] == true
      assert out =~ "1 created"
      assert out =~ "1 refused"
      assert out =~ "not assigned"
    end

    test "--json emits the response verbatim" do
      bulk_stub(@bulk_resp)
      {out, _err, 0} = capture(fn -> Claim.run(["--epic", "9", "--json"]) end)
      assert {:ok, %{"applied" => false}} = Jason.decode(out)
    end

    test "ref together with --epic is rejected" do
      {_out, err, code} = capture(fn -> Claim.run(["43", "--epic", "9"]) end)
      assert code != 0
      assert err =~ "exactly one"
    end
  end

  test "403 not_assigned propagates as die" do
    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       {%{
          "error" => %{
            "type" => "not_assigned",
            "message" => "issue is not assigned to workspace user \"me\"",
            "details" => %{"viewer" => "me"}
          }
        }, 403}}
    ])

    {_out, err, code} = capture(fn -> Claim.run(["43"]) end)
    assert code != 0
    assert err =~ "not assigned"
  end

  test "--difficulty forwards as difficulty in the POST body" do
    parent = self()

    stub_routes([
      @workspace_lookup,
      {{"post", "/api/workspaces/ws-1/claim"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{
           "status" => "created",
           "task" => %{
             "id" => "bd-abc",
             "title" => "Hard task",
             "state" => "backlog",
             "tracker_type" => "github",
             "tracker_ref" => "43",
             "difficulty" => 3
           }
         })
       end}
    ])

    {_out, _err, code} = capture(fn -> Claim.run(["43", "--difficulty", "3"]) end)
    assert code == 0

    assert_received {:posted, body}
    assert body["difficulty"] == 3
  end

  test "--difficulty out-of-range exits non-zero before posting" do
    stub_routes([
      @workspace_lookup
    ])

    {_out, err, code} = capture(fn -> Claim.run(["43", "--difficulty", "9"]) end)
    assert code != 0
    assert err =~ "difficulty"
  end

  for spelling <- ["3", "D3", "d3"] do
    test "--difficulty #{spelling} forwards difficulty 3" do
      parent = self()

      stub_routes([
        @workspace_lookup,
        {{"post", "/api/workspaces/ws-1/claim"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:posted, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{
             "status" => "created",
             "task" => %{"id" => "bd-abc", "title" => "T", "state" => "backlog"}
           })
         end}
      ])

      {_out, _err, code} =
        capture(fn -> Claim.run(["43", "--difficulty", unquote(spelling)]) end)

      assert code == 0
      assert_received {:posted, %{"difficulty" => 3}}
    end
  end

  test "--difficulty with a non-numeric value errors rather than being dropped" do
    {_out, err, code} = capture(fn -> Claim.run(["43", "--difficulty", "hard"]) end)
    assert code == 1
    assert err =~ "invalid --difficulty"
  end

  test "an unknown flag exits 1 naming the flag and does not swallow the ref" do
    {_out, err, code} = capture(fn -> Claim.run(["--acceptance", "43"]) end)
    assert code == 1
    assert err =~ "unknown option --acceptance for arb ticket claim"
  end
end
