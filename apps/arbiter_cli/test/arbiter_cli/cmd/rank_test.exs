defmodule ArbiterCli.Cmd.RankTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Rank

  @issue %{
    "id" => "bd-001",
    "title" => "X",
    "priority" => 2,
    "rank" => 1024,
    "workspace_id" => "ws-1"
  }

  test "--top sends {top: true} and prints the updated issue" do
    stub_routes([
      {{"patch", "/api/issues/bd-001/rank"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"top" => true}

         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@issue)
       end},
      {{"get", "/api/issues"}, fn conn -> Req.Test.json(conn, %{"data" => [@issue]}) end}
    ])

    {out, _err, exit_code} = capture(fn -> Rank.run(["bd-001", "--top"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
  end

  test "--bottom sends {bottom: true}" do
    stub_routes([
      {{"patch", "/api/issues/bd-001/rank"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"bottom" => true}

         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@issue)
       end},
      {{"get", "/api/issues"}, fn conn -> Req.Test.json(conn, %{"data" => [@issue]}) end}
    ])

    {_out, _err, exit_code} = capture(fn -> Rank.run(["bd-001", "--bottom"]) end)
    assert exit_code == 0
  end

  test "--before <id> sends {before_id: id}" do
    stub_routes([
      {{"patch", "/api/issues/bd-001/rank"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"before_id" => "bd-002"}

         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@issue)
       end},
      {{"get", "/api/issues"}, fn conn -> Req.Test.json(conn, %{"data" => [@issue]}) end}
    ])

    {_out, _err, exit_code} = capture(fn -> Rank.run(["bd-001", "--before", "bd-002"]) end)
    assert exit_code == 0
  end

  test "--after <id> sends {after_id: id}" do
    stub_routes([
      {{"patch", "/api/issues/bd-001/rank"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"after_id" => "bd-002"}

         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@issue)
       end},
      {{"get", "/api/issues"}, fn conn -> Req.Test.json(conn, %{"data" => [@issue]}) end}
    ])

    {_out, _err, exit_code} = capture(fn -> Rank.run(["bd-001", "--after", "bd-002"]) end)
    assert exit_code == 0
  end

  test "--json emits raw JSON with priority_band fields" do
    other = Map.put(@issue, "id", "bd-000")

    stub_routes([
      {{"patch", "/api/issues/bd-001/rank"},
       fn conn -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(@issue) end},
      {{"get", "/api/issues"}, fn conn -> Req.Test.json(conn, %{"data" => [other, @issue]}) end}
    ])

    {out, _err, exit_code} = capture(fn -> Rank.run(["bd-001", "--top", "--json"]) end)
    assert exit_code == 0
    assert {:ok, body} = Jason.decode(out)
    assert body["priority_band_position"] == 1
    assert body["priority_band_size"] == 2
  end

  test "requires an issue id" do
    {_out, err, exit_code} = capture(fn -> Rank.run(["--top"]) end)
    assert exit_code == 1
    assert err =~ "requires an issue id"
  end

  test "requires exactly one of --top/--bottom/--before/--after" do
    {_out, err, exit_code} = capture(fn -> Rank.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "exactly one of"
  end

  test "rejects more than one of --top/--bottom/--before/--after" do
    {_out, err, exit_code} = capture(fn -> Rank.run(["bd-001", "--top", "--bottom"]) end)
    assert exit_code == 1
    assert err =~ "exactly one of"
  end

  test "surfaces a validation error from the server" do
    stub_routes([
      {{"patch", "/api/issues/bd-001/rank"},
       fn conn ->
         conn
         |> Plug.Conn.put_status(422)
         |> Req.Test.json(%{
           "error" => %{
             "message" => "cannot rank before/after a ticket in a different workspace"
           }
         })
       end}
    ])

    {_out, err, exit_code} =
      capture(fn -> Rank.run(["bd-001", "--before", "other-ws-ticket"]) end)

    assert exit_code == 1
    assert err =~ "different workspace"
  end
end
