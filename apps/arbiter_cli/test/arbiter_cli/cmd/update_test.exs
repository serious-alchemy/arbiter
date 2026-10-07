defmodule ArbiterCli.Cmd.UpdateTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Update
  alias ArbiterCli.Main

  test "updates priority via PATCH" do
    stub_patch(
      "/api/issues/bd-001",
      %{"id" => "bd-001", "title" => "X", "priority" => 0, "state" => "queued"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Update.run(["bd-001", "--priority", "0"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end

  # bd-36ytcl: a ticket's state moves only through its transitions, so the
  # legacy flag is refused (pointing at them) and nothing is sent.
  test "--status is refused with the transition verbs, without a request" do
    for argv <- [["bd-001", "--status", "closed"], ["bd-001", "--status=open"]] do
      {_out, err, exit_code} = capture(fn -> Update.run(argv) end)
      assert exit_code == 1
      assert err =~ "--status was removed"
      assert err =~ "arb ticket promote"
    end
  end

  test "--append-notes sends append_notes for the server to apply — no GET, no notes (D-T-19)" do
    parent = self()

    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:patched, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => "bd-001", "notes" => "p"})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--append-notes", "addendum"]) end)

    assert exit_code == 0
    assert_received {:patched, body}
    assert body == %{"append_notes" => "addendum"}
  end

  test "--qa-notes and --deployment-notes are sent as fields" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["qa_notes"] == "verify the endpoint"
         assert decoded["deployment_notes"] == "no migrations"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "qa_notes" => decoded["qa_notes"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run([
          "bd-001",
          "--qa-notes",
          "verify the endpoint",
          "--deployment-notes",
          "no migrations"
        ])
      end)

    assert exit_code == 0
  end

  test "--pr-body is sent as the pr_body field (bd-53xrmi)" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["pr_body"] == "## Summary\nDid the thing."

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "pr_body" => decoded["pr_body"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run(["bd-001", "--pr-body", "## Summary\nDid the thing."])
      end)

    assert exit_code == 0
  end

  # P-14: PATCH no longer takes `circuit_breaker_*`; the flag drives the typed
  # resume_review route.
  test "--resume-review posts the typed resume_review route, never raw breaker fields" do
    parent = self()

    stub_routes([
      {{"post", "/api/issues/bd-001/resume_review"},
       fn conn ->
         send(parent, :resumed)

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "circuit_breaker_tripped" => false})
       end},
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         send(parent, :patched)
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => "bd-001"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--resume-review"]) end)

    assert exit_code == 0
    assert out =~ "bd-001"
    assert_received :resumed
    refute_received :patched
  end

  test "--resume-review with a field flag patches the field, then resumes" do
    parent = self()

    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         send(parent, {:patched, decoded})
         refute Map.has_key?(decoded, "circuit_breaker_tripped")
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => "bd-001"})
       end},
      {{"post", "/api/issues/bd-001/resume_review"},
       fn conn ->
         send(parent, :resumed)
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => "bd-001"})
       end}
    ])

    {_out, _err, 0} =
      capture(fn -> Update.run(["bd-001", "--priority", "1", "--resume-review"]) end)

    assert_received {:patched, %{"priority" => 1}}
    assert_received :resumed
  end

  test "--repo is sent as the repo field (bd-2jum8j)" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["repo"] == "emricare/tonic_device"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "repo" => decoded["repo"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--repo", "emricare/tonic_device"]) end)

    assert exit_code == 0
  end

  test "no fields supplied → error" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "at least one field flag"
  end

  test "updates difficulty via PATCH" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["difficulty"] == 3

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "difficulty" => 3})
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Update.run(["bd-001", "--difficulty", "3"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end

  test "--difficulty out-of-range exits non-zero before patching" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001", "--difficulty", "7"]) end)
    assert exit_code == 1
    assert err =~ "difficulty"
  end

  test "--acceptance is sent as the acceptance field" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["acceptance"] == "- Verify the new endpoint works\n- Write tests"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "acceptance" => decoded["acceptance"]})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Update.run(["bd-001", "--acceptance", "- Verify the new endpoint works\n- Write tests"])
      end)

    assert exit_code == 0
  end

  # bd-1ozks5: --assignee used to patch the local column, which is gone — it's
  # still accepted for interface parity but ignored, with a warning, rather
  # than rejected outright.
  test "--assignee alongside a real field patches the field, drops assignee, warns" do
    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         decoded = Jason.decode!(body)
         assert decoded["priority"] == 1
         refute Map.has_key?(decoded, "assignee")

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "bd-001", "priority" => 1})
       end}
    ])

    {_out, err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--priority", "1", "--assignee", "alice"]) end)

    assert exit_code == 0
    assert err =~ "--assignee is deprecated"
  end

  test "an --assignee-only update is a no-op that fetches and reports the task, with a warning" do
    stub_routes([
      {{"get", "/api/issues/bd-001"}, {%{"id" => "bd-001", "title" => "unchanged"}, 200}}
    ])

    {out, err, exit_code} =
      capture(fn -> Update.run(["bd-001", "--assignee", "alice"]) end)

    assert exit_code == 0
    assert out =~ "bd-001"
    assert err =~ "--assignee is deprecated"
  end

  # bd-9so315
  describe "--verify-after-deploy" do
    test "sets the flag" do
      stub_patch("/api/issues/bd-1", %{"id" => "bd-1", "verify_after_deploy" => true})

      {out, _err, code} =
        capture(fn -> Update.edit_issue(["bd-1", "--verify-after-deploy", "--json"]) end)

      assert code == 0
      assert {:ok, %{"verify_after_deploy" => true}} = Jason.decode(out)
    end

    test "--no-verify-after-deploy clears it" do
      stub_patch("/api/issues/bd-1", %{"id" => "bd-1", "verify_after_deploy" => false})

      {out, _err, code} =
        capture(fn -> Update.edit_issue(["bd-1", "--no-verify-after-deploy", "--json"]) end)

      assert code == 0
      assert {:ok, %{"verify_after_deploy" => false}} = Jason.decode(out)
    end
  end

  for spelling <- ["3", "D3", "d3"] do
    test "--difficulty #{spelling} PATCHes difficulty 3" do
      parent = self()

      stub_routes([
        {{"patch", "/api/issues/bd-001"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:patched, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => "bd-001", "difficulty" => 3})
         end}
      ])

      {_out, _err, exit_code} =
        capture(fn -> Update.run(["bd-001", "--difficulty", unquote(spelling)]) end)

      assert exit_code == 0
      assert_received {:patched, %{"difficulty" => 3}}
    end
  end

  test "--priority with a non-integer value errors before patching" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001", "--priority", "abc"]) end)
    assert exit_code == 1
    assert err =~ "invalid value \"abc\" for --priority"
  end

  test "an unknown flag on the edit path exits 1 naming the flag" do
    {_out, err, exit_code} = capture(fn -> Update.run(["bd-001", "--nope", "x"]) end)
    assert exit_code == 1
    assert err =~ "unknown option --nope for arb ticket update"
  end

  # ---- P-08: flag parity with MCP / REST ----------------------------------

  defp patched_body(argv) do
    parent = self()

    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:patched, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => "bd-001"})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Update.run(["bd-001" | argv]) end)
    assert exit_code == 0
    assert_received {:patched, body}
    body
  end

  describe "fields MCP/REST accept (D-T-11)" do
    test "--tracker-ref (the recovery step three server messages name) reaches the PATCH" do
      assert patched_body(["--tracker-ref", "PROJ-7"]) == %{"tracker_ref" => "PROJ-7"}
    end

    for {flag, key, value} <- [
          {"--target-branch", "target_branch", "release/1"},
          {"--type", "issue_type", "research"},
          {"--pr-ref", "pr_ref", "123"},
          {"--tracker-type", "tracker_type", "github"},
          {"--tracker-context-type", "tracker_context_type", "jira"},
          {"--tracker-context-ref", "tracker_context_ref", "PROJ-1"}
        ] do
      test "#{flag} is sent as #{key}" do
        assert patched_body([unquote(flag), unquote(value)]) == %{unquote(key) => unquote(value)}
      end
    end

    test "--auto-close / --no-auto-close set and clear the flag" do
      assert patched_body(["--auto-close"]) == %{"auto_close" => true}
      assert patched_body(["--no-auto-close"]) == %{"auto_close" => false}
    end
  end

  describe "an empty string clears a field (D-T-18)" do
    test "is sent through, and is a valid sole field flag" do
      assert patched_body(["--description", ""]) == %{"description" => ""}
      assert patched_body(["--tracker-ref", ""]) == %{"tracker_ref" => ""}

      assert patched_body(["--notes", "", "--acceptance", ""]) == %{
               "notes" => "",
               "acceptance" => ""
             }
    end
  end

  test "`arb ticket update <id> --tracker-ref REF` — the recovery step the server prints — works end to end" do
    parent = self()

    stub_routes([
      {{"patch", "/api/issues/bd-001"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:patched, Jason.decode!(body)})
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => "bd-001"})
       end}
    ])

    {_out, err, code} =
      capture(fn -> Main.main(["ticket", "update", "bd-001", "--tracker-ref", "42"]) end)

    assert code == 0
    refute err =~ "unknown option"
    assert_received {:patched, %{"tracker_ref" => "42"}}
  end

  test "--acceptance-file reads the criteria from a file" do
    path = Path.join(System.tmp_dir!(), "ac-#{System.unique_integer([:positive])}.md")
    File.write!(path, "- it works\n")
    on_exit(fn -> File.rm(path) end)

    assert patched_body(["--acceptance-file", path]) == %{"acceptance" => "- it works\n"}
  end

  test "--help lists every flag the edit path accepts" do
    {out, _err, 0} = capture(fn -> Update.run(["--help"]) end)

    for flag <-
          ~w(--priority --difficulty --notes --append-notes --acceptance --qa-notes
             --deployment-notes --pr-body --description --title --repo --resume-review
             --verify-after-deploy --tracker-ref --target-branch --auto-close --no-auto-close
             --type --pr-ref --tracker-type --tracker-context-type --tracker-context-ref
             --require-provider --exclude-provider --clear-provider-constraint) do
      assert out =~ flag, "update --help does not list #{flag}"
    end
  end
end
