defmodule ArbiterCli.Cmd.CreateTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Create

  test "creates issue using workspace lookup" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       {%{"id" => "bd-001", "title" => "Hello", "state" => "backlog", "priority" => 2}, 201}}
    ])

    {out, _err, exit_code} = capture(fn -> Create.run(["Hello"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
    assert out =~ "Hello"
  end

  # bd-9dwbvt: `--help` prints the moduledoc, which has to say that repo is now
  # resolved for you rather than left unset.
  test "--help says repo is defaulted from the workspace, not optional" do
    {out, _err, exit_code} = capture(fn -> Create.run(["--help"]) end)

    assert exit_code == 0
    assert out =~ "--repo"
    assert out =~ "default_repo"
    refute out =~ "Optional, and unnecessary in a single-repo workspace"

    # The remediation the operator reads when creation is refused has to name a
    # command that exists: config writes are `arb config set`, not a
    # (nonexistent) `arb workspace config set`.
    assert out =~ "arb config set default_repo"
    refute out =~ "arb workspace config set"
  end

  test "--parent is sent with the create; the CLI posts no edge itself (P-14)" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "bd-007", "title" => "X"})
       end},
      {{"post", "/api/dependencies"},
       fn conn ->
         send(parent, :dependency_posted)
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "dep-1"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Create.run(["X", "--parent", "bd-epic"]) end)

    assert exit_code == 0
    assert out =~ "bd-007"
    assert_received {:posted, %{"parent_id" => "bd-epic"}}
    refute_received :dependency_posted
  end

  test "--deps ids ride along as a list in the create body" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "bd-007", "title" => "X"})
       end}
    ])

    {_out, _err, 0} = capture(fn -> Create.run(["X", "--deps", "bd-1, bd-2"]) end)

    assert_received {:posted, %{"deps" => ["bd-1", "bd-2"]}}
  end

  # #1973: the server needs the parent at create time to default a child of a
  # tracker-linked parent to context-only rather than minting its own ticket.
  test "--parent is sent with the create so the server can default the tracker from it" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "bd-008", "title" => "X"})
       end},
      {{"post", "/api/dependencies"}, {%{"id" => "dep-1"}, 201}}
    ])

    {_out, _err, exit_code} = capture(fn -> Create.run(["X", "--parent", "bd-epic"]) end)

    assert exit_code == 0
    assert_received {:posted, %{"parent_id" => "bd-epic"}}
  end

  test "--acceptance is sent in the create payload and documented in --help" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "bd-010", "title" => "X"})
       end}
    ])

    {_out, _err, 0} =
      capture(fn -> Create.run(["X", "--type", "feature", "--acceptance", "it works"]) end)

    assert_received {:posted, %{"acceptance" => "it works"}}

    {out, _err, 0} = capture(fn -> Create.run(["--help"]) end)
    assert out =~ "--acceptance"
  end

  test "an unknown flag exits non-zero naming the flag and creates nothing" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         send(parent, :posted)
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "bd-011"})
       end}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["X", "--bogus-flag", "y"]) end)

    assert exit_code != 0
    assert err =~ "--bogus-flag"
    refute_received :posted
  end

  test "without --parent no parent_id is sent" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "bd-009", "title" => "X"})
       end}
    ])

    {_out, _err, 0} = capture(fn -> Create.run(["X"]) end)

    assert_received {:posted, body}
    refute Map.has_key?(body, "parent_id")
  end

  # P-14 AC5: a failed edge (or tracker mirror) leaves the ticket created; the
  # server says so with `error.details.task_id`, and `--json` still prints it.
  describe "a create the server answers with the ticket already filed" do
    @edge_failed {%{
                    "issue" => %{"id" => "bd-007", "title" => "X"},
                    "error" => %{
                      "type" => "edge_failed",
                      "message" =>
                        "ticket bd-007 was created, but failed to attach bd-007 to parent bd-epic: task bd-epic not found",
                      "details" => %{"task_id" => "bd-007", "failures" => []}
                    }
                  }, 422}

    test "--json prints the created id on stdout and exits non-zero" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"}, @edge_failed}
      ])

      {out, err, exit_code} =
        capture(fn -> Create.run(["X", "--parent", "bd-epic", "--json"]) end)

      assert exit_code != 0

      assert {:ok, %{"id" => "bd-007", "created" => true, "error" => %{"type" => "edge_failed"}}} =
               Jason.decode(String.trim(out))

      assert err =~ "failed to attach bd-007 to parent bd-epic"
    end

    test "text mode names the id in the message and exits non-zero" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"}, @edge_failed}
      ])

      {out, err, exit_code} = capture(fn -> Create.run(["X", "--parent", "bd-epic"]) end)

      assert exit_code != 0
      assert out == ""
      assert err =~ "bd-007"
    end

    test "a tracker-mirror 502 prints the id under --json too" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"},
         {%{
            "issue" => %{"id" => "bd-008"},
            "error" => %{
              "type" => "upstream_create_failed",
              "message" => "ticket bd-008 mirror failed",
              "details" => %{"task_id" => "bd-008"}
            }
          }, 502}}
      ])

      {out, _err, exit_code} = capture(fn -> Create.run(["X", "--json"]) end)

      assert exit_code != 0
      assert {:ok, %{"id" => "bd-008"}} = Jason.decode(String.trim(out))
    end

    test "a refusal with no created ticket prints nothing on stdout" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"},
         {%{"error" => %{"type" => "not_found", "message" => "ticket bd-epic not found"}}, 404}}
      ])

      {out, err, exit_code} =
        capture(fn -> Create.run(["X", "--parent", "bd-epic", "--json"]) end)

      assert exit_code == 4
      assert out == ""
      assert err =~ "bd-epic not found"
    end
  end

  test "no title argument exits non-zero" do
    {_out, err, exit_code} = capture(fn -> Create.run([]) end)
    assert exit_code == 1
    assert err =~ "title"
  end

  test "--json emits JSON" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"}, {%{"id" => "bd-001", "title" => "X"}, 201}}
    ])

    {out, _err, exit_code} = capture(fn -> Create.run(["X", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"id" => "bd-001"}} = Jason.decode(String.trim(out))
  end

  test "zero workspaces → friendly create-one error" do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => []}, 200}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["X"]) end)
    assert exit_code == 1
    assert err =~ "no workspaces found"
  end

  test "validation error from server surfaces message" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       {%{
          "error" => %{
            "type" => "validation_error",
            "message" => "validation failed",
            "details" => %{}
          }
        }, 422}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["X"]) end)
    assert exit_code == 1
    assert err =~ "validation failed"
  end

  test "--tracker-ref passes the ref through as tracker_ref" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-002", "title" => "Bound", "tracker_ref" => "777"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Create.run(["Bound", "--tracker-ref", "777", "--json"]) end)

    assert exit_code == 0
    assert {:ok, %{"tracker_ref" => "777"}} = Jason.decode(String.trim(out))

    assert_received {:posted, body}
    assert body["tracker_ref"] == "777"
    refute Map.has_key?(body, "skip_upstream_create")
  end

  test "--no-tracker forwards skip_upstream_create=true to the create action" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-003", "title" => "Local"})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Create.run(["Local", "--no-tracker"]) end)
    assert exit_code == 0

    assert_received {:posted, body}
    assert body["skip_upstream_create"] == true
  end

  test "--target-branch forwards as target_branch in the POST body" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-010", "title" => "T", "target_branch" => "dolphin"})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Create.run(["T", "--target-branch", "dolphin"]) end)

    assert exit_code == 0

    assert_received {:posted, body}
    assert body["target_branch"] == "dolphin"
  end

  test "--repo forwards as repo in the POST body (bd-2jum8j)" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-011", "title" => "T", "repo" => "org/tonic"})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Create.run(["T", "--repo", "org/tonic"]) end)

    assert exit_code == 0

    assert_received {:posted, body}
    assert body["repo"] == "org/tonic"
  end

  test "--difficulty forwards as difficulty in the POST body" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-005", "title" => "Hard", "difficulty" => 3})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Create.run(["Hard", "--difficulty", "3"]) end)
    assert exit_code == 0

    assert_received {:posted, body}
    assert body["difficulty"] == 3
  end

  test "--difficulty 5 (the opt-in flagship tier) forwards rather than being rejected" do
    # #1519: D5 must be reachable from the CLI or the flagship tier is
    # unusable — typing it deliberately is the whole point of the level.
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted_difficulty, Jason.decode!(body)["difficulty"]})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-006", "title" => "Flagship", "difficulty" => 5})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Create.run(["Flagship", "--difficulty", "5"]) end)

    assert exit_code == 0
    assert_received {:posted_difficulty, 5}
  end

  test "--difficulty out-of-range exits non-zero before posting" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["X", "--difficulty", "9"]) end)
    assert exit_code == 1
    assert err =~ "difficulty"

    {_out, err, exit_code} = capture(fn -> Create.run(["X", "--difficulty", "6"]) end)
    assert exit_code == 1
    assert err =~ "difficulty"
  end

  test "upstream-create failure (502 with task body + error) surfaces non-zero" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       {%{
          "issue" => %{"id" => "bd-004", "title" => "Half"},
          "error" => %{
            "type" => "upstream_create_failed",
            "message" => "task bd-004 created locally but upstream github create failed: boom",
            "details" => %{"task_id" => "bd-004", "tracker_type" => "github"}
          }
        }, 502}}
    ])

    {_out, err, exit_code} = capture(fn -> Create.run(["Half"]) end)
    assert exit_code != 0
    assert err =~ "upstream"
    assert err =~ "bd-004"
  end

  describe "--ticket-only" do
    test "posts to /api/workspaces/:id/tracker/tickets and prints ref + url" do
      parent = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:posted, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{
             "ref" => "99",
             "url" => "https://github.com/o/r/issues/99",
             "tracker_type" => "github"
           })
         end}
      ])

      {out, _err, exit_code} =
        capture(fn -> Create.run(["Unclaimed ticket", "--ticket-only"]) end)

      assert exit_code == 0
      assert out =~ "99"
      assert out =~ "github"

      assert_received {:posted, body}
      assert body["title"] == "Unclaimed ticket"
      refute Map.has_key?(body, "workspace_id")
    end

    test "--no-task alias works the same as --ticket-only" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "ref" => "77",
            "url" => "https://github.com/o/r/issues/77",
            "tracker_type" => "github"
          }, 201}}
      ])

      {out, _err, exit_code} = capture(fn -> Create.run(["No-task title", "--no-task"]) end)
      assert exit_code == 0
      assert out =~ "77"
    end

    test "--unclaimed alias works the same as --ticket-only" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "ref" => "55",
            "url" => "https://github.com/o/r/issues/55",
            "tracker_type" => "github"
          }, 201}}
      ])

      {out, _err, exit_code} = capture(fn -> Create.run(["Unclaimed", "--unclaimed"]) end)
      assert exit_code == 0
      assert out =~ "55"
    end

    test "--json emits JSON" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "ref" => "42",
            "url" => "https://github.com/o/r/issues/42",
            "tracker_type" => "github"
          }, 201}}
      ])

      {out, _err, exit_code} =
        capture(fn -> Create.run(["My ticket", "--ticket-only", "--json"]) end)

      assert exit_code == 0
      assert {:ok, %{"ref" => "42", "tracker_type" => "github"}} = Jason.decode(String.trim(out))
    end

    test "forwards --description to the tickets endpoint and ignores --assignee, with a warning" do
      parent = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:posted, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"ref" => "10", "url" => nil, "tracker_type" => "github"})
         end}
      ])

      {_out, err, exit_code} =
        capture(fn ->
          Create.run([
            "Detailed",
            "--ticket-only",
            "--description",
            "some body",
            "--assignee",
            "alice"
          ])
        end)

      assert exit_code == 0
      assert_received {:posted, body}
      assert body["description"] == "some body"
      refute Map.has_key?(body, "assignee")
      assert err =~ "--assignee is deprecated"
    end

    test "--ticket-only and --no-tracker errors before posting" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}
      ])

      {_out, err, exit_code} =
        capture(fn -> Create.run(["T", "--ticket-only", "--no-tracker"]) end)

      assert exit_code == 1
      assert err =~ "mutually exclusive"
    end

    test "--ticket-only and --local-only errors before posting" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}
      ])

      {_out, err, exit_code} =
        capture(fn -> Create.run(["T", "--ticket-only", "--local-only"]) end)

      assert exit_code == 1
      assert err =~ "mutually exclusive"
    end

    test "server error (e.g. no tracker configured) surfaces non-zero" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/tracker/tickets"},
         {%{
            "error" => %{
              "type" => "invalid_request",
              "message" => "workspace has no tracker configured",
              "details" => %{}
            }
          }, 400}}
      ])

      {_out, err, exit_code} =
        capture(fn -> Create.run(["T", "--ticket-only"]) end)

      assert exit_code != 0
      assert err =~ "tracker"
    end
  end

  # bd-9so315
  test "--verify-after-deploy sets the flag on create" do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:create_body, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "bd-1", "title" => "T", "verify_after_deploy" => true})
       end}
    ])

    {out, err, code} =
      capture(fn -> Create.run(["T", "--verify-after-deploy", "--json"]) end)

    assert code == 0, err
    assert_receive {:create_body, %{"verify_after_deploy" => true}}
    assert {:ok, %{"verify_after_deploy" => true}} = Jason.decode(out)
  end

  for spelling <- ["3", "D3", "d3"] do
    test "--difficulty #{spelling} forwards difficulty 3" do
      parent = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/issues"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:posted, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "bd-005", "title" => "Hard", "difficulty" => 3})
         end}
      ])

      {_out, _err, exit_code} =
        capture(fn -> Create.run(["Hard", "--difficulty", unquote(spelling)]) end)

      assert exit_code == 0
      assert_received {:posted, %{"difficulty" => 3}}
    end
  end

  test "--priority with a non-integer value errors rather than creating the ticket" do
    {_out, err, exit_code} = capture(fn -> Create.run(["X", "--priority", "abc"]) end)
    assert exit_code == 1
    assert err =~ "invalid value \"abc\" for --priority"
  end

  test "--difficulty with a non-numeric value errors" do
    {_out, err, exit_code} = capture(fn -> Create.run(["X", "--difficulty", "hard"]) end)
    assert exit_code == 1
    assert err =~ "invalid --difficulty"
  end

  # ---- P-08: flag parity with MCP / REST (D-T-8) ---------------------------

  defp posted_body(argv) do
    parent = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/issues"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "bd-010", "title" => "X"})
       end}
    ])

    {_out, _err, 0} = capture(fn -> Create.run(["X" | argv]) end)
    assert_received {:posted, body}
    body
  end

  for {flag, key, value} <- [
        {"--notes", "notes", "n"},
        {"--qa-notes", "qa_notes", "q"},
        {"--deployment-notes", "deployment_notes", "d"},
        {"--tracker-type", "tracker_type", "github"},
        {"--tracker-context-type", "tracker_context_type", "jira"},
        {"--tracker-context-ref", "tracker_context_ref", "PROJ-1"}
      ] do
    test "#{flag} is sent as #{key}" do
      body = posted_body([unquote(flag), unquote(value)])
      assert body[unquote(key)] == unquote(value)
    end
  end

  test "--acceptance-file reads the acceptance criteria from a file" do
    path = Path.join(System.tmp_dir!(), "ac-#{System.unique_integer([:positive])}.md")
    File.write!(path, "1. it works\n2. it is tested\n")
    on_exit(fn -> File.rm(path) end)

    assert posted_body(["--acceptance-file", path])["acceptance"] ==
             "1. it works\n2. it is tested\n"
  end

  test "--acceptance and --acceptance-file together are refused before posting" do
    {_out, err, exit_code} =
      capture(fn -> Create.run(["X", "--acceptance", "a", "--acceptance-file", "/nope"]) end)

    assert exit_code == 1
    assert err =~ "--acceptance"
  end

  test "an unreadable --acceptance-file is refused before posting" do
    {_out, err, exit_code} =
      capture(fn -> Create.run(["X", "--acceptance-file", "/nonexistent/ac.md"]) end)

    assert exit_code == 1
    assert err =~ "/nonexistent/ac.md"
  end

  test "--help lists every flag create accepts" do
    {out, _err, 0} = capture(fn -> Create.run(["--help"]) end)

    for flag <-
          ~w(--description --acceptance --acceptance-file --notes --qa-notes --deployment-notes
             --priority --difficulty --type --deps --labels --tracker-ref --tracker-type
             --tracker-context-type --tracker-context-ref --no-tracker --local-only
             --target-branch --repo --parent --ticket-only --auto-close --verify-after-deploy
             --force --require-provider --exclude-provider) do
      assert out =~ flag, "create --help does not list #{flag}"
    end
  end
end
