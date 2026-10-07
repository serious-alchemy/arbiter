defmodule ArbiterCli.Cmd.SkillTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Skill

  # `-w` (via Main) writes ARB_WORKSPACE, and a worker shell may already carry
  # one; every test starts and ends without it.
  setup do
    previous = System.get_env("ARB_WORKSPACE")
    System.delete_env("ARB_WORKSPACE")

    on_exit(fn ->
      if previous,
        do: System.put_env("ARB_WORKSPACE", previous),
        else: System.delete_env("ARB_WORKSPACE")
    end)
  end

  test "skill list renders name + size + description" do
    stub_get("/api/skills", %{
      "data" => [
        %{"name" => "tdd", "body" => "abc", "metadata" => %{"description" => "test first"}},
        %{"name" => "plain", "body" => "x", "metadata" => %{}}
      ]
    })

    {out, _err, exit_code} = capture(fn -> Skill.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "tdd  [never used]  — test first"
    assert out =~ "plain"
  end

  test "skill list shows materialize/invoke counts when present" do
    stub_get("/api/skills", %{
      "data" => [
        %{
          "name" => "tdd",
          "body" => "abc",
          "metadata" => %{},
          "materialize_count" => 5,
          "invoke_count" => 2
        },
        %{
          "name" => "unused-skill",
          "body" => "x",
          "metadata" => %{},
          "materialize_count" => 3,
          "invoke_count" => 0
        }
      ]
    })

    {out, _err, exit_code} = capture(fn -> Skill.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "tdd  [↓ 5, ⧗ 2]"
    assert out =~ "unused-skill  [↓ 3]"
  end

  test "skill create with --body posts and reports" do
    stub_post("/api/skills", %{"id" => "s1", "name" => "tdd", "body" => "write test first"}, 201)

    {out, _err, exit_code} =
      capture(fn -> Skill.run(["create", "tdd", "--body", "write test first"]) end)

    assert exit_code == 0
    assert out =~ "created skill tdd"
  end

  test "skill create surfaces a bundled-collision warning on stderr" do
    stub_post(
      "/api/skills",
      %{
        "id" => "s2",
        "name" => "code-review",
        "body" => "x",
        "warning" => "collides with a bundled skill of the same name"
      },
      201
    )

    {out, err, exit_code} =
      capture(fn -> Skill.run(["create", "code-review", "--body", "x"]) end)

    assert exit_code == 0
    assert out =~ "created skill code-review"
    assert err =~ "collides with a bundled skill"
  end

  test "skill create without a body errors" do
    {_out, err, exit_code} = capture(fn -> Skill.run(["create", "tdd"]) end)
    assert exit_code == 1
    assert err =~ "requires a body"
  end

  test "skill update patches the named skill" do
    stub_patch("/api/skills/tdd", %{"id" => "s1", "name" => "tdd", "body" => "v2"}, 200)

    {out, _err, exit_code} =
      capture(fn -> Skill.run(["update", "tdd", "--body", "v2"]) end)

    assert exit_code == 0
    assert out =~ "updated skill tdd"
  end

  test "skill update with nothing to change errors" do
    {_out, err, exit_code} = capture(fn -> Skill.run(["update", "tdd"]) end)
    assert exit_code == 1
    assert err =~ "nothing to change"
  end

  test "skill delete --force hits DELETE" do
    stub_delete("/api/skills/tdd", %{"name" => "tdd"}, 200)

    {out, _err, exit_code} = capture(fn -> Skill.run(["delete", "tdd", "--force"]) end)
    assert exit_code == 0
    assert out =~ "deleted skill tdd"
  end

  test "skill with no subcommand errors" do
    {_out, err, exit_code} = capture(fn -> Skill.run([]) end)
    assert exit_code == 1
    assert err =~ "subcommand"
  end

  describe "workspace scoping and list shape" do
    defp ws_routes(extra) do
      [
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-x", "name" => "x", "prefix" => "xx"}]}, 200}}
        | extra
      ]
    end

    defp capture_params(method, path, body, tag) do
      test_pid = self()

      {{method, path},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(test_pid, {tag, conn.query_params, raw})
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)
       end}
    end

    test "skill show <name> -w X sends the resolved workspace" do
      stub_routes(
        ws_routes([
          capture_params("get", "/api/skills/scoped", %{"name" => "scoped", "id" => "s"}, :show)
        ])
      )

      {out, _err, exit_code} =
        capture(fn -> ArbiterCli.Main.main(~w(skill show scoped -w x)) end)

      assert exit_code == 0
      assert out =~ "scoped"
      assert_received {:show, %{"workspace" => "ws-x"}, _}
    end

    test "skill delete <name> -w X --force sends the resolved workspace" do
      stub_routes(
        ws_routes([
          capture_params(
            "delete",
            "/api/skills/scoped",
            %{"deleted" => true, "name" => "scoped"},
            :del
          )
        ])
      )

      {out, _err, exit_code} =
        capture(fn -> ArbiterCli.Main.main(~w(skill delete scoped -w x --force)) end)

      assert exit_code == 0
      assert out =~ "deleted skill scoped"
      assert_received {:del, %{"workspace" => "ws-x"}, _}
    end

    test "skill update <name> -w X sends the workspace; --code-only=false sends false" do
      stub_routes(
        ws_routes([capture_params("patch", "/api/skills/scoped", %{"name" => "scoped"}, :upd)])
      )

      {_out, _err, exit_code} =
        capture(fn ->
          ArbiterCli.Main.main(~w(skill update scoped -w x --code-only=false))
        end)

      assert exit_code == 0
      assert_received {:upd, %{"workspace" => "ws-x"}, raw}
      assert %{"code_only" => false} = Jason.decode!(raw)
    end

    test "skill list renders without a body size" do
      stub_get("/api/skills", %{"data" => [%{"name" => "tdd", "metadata" => %{}}]})
      {out, _err, 0} = capture(fn -> Skill.run(["list"]) end)
      assert out =~ "tdd"
      refute out =~ "bytes"
    end
  end
end
