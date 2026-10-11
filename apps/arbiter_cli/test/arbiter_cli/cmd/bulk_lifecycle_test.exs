defmodule ArbiterCli.Cmd.BulkLifecycleTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.{Demote, Promote, Rank}

  @mixed %{
    "results" => [
      %{"id" => "bd-1", "status" => "ok", "ticket" => %{"id" => "bd-1", "state" => "queued"}},
      %{"id" => "bd-2", "status" => "refused", "reason" => "needs acceptance criteria"},
      %{"id" => "bd-3", "status" => "not_found", "reason" => "task bd-3 not found"}
    ],
    "counts" => %{"total" => 3, "ok" => 1, "refused" => 1, "not_found" => 1}
  }

  @all_ok %{
    "results" => [
      %{"id" => "bd-1", "status" => "ok", "ticket" => %{"id" => "bd-1", "state" => "backlog"}},
      %{"id" => "bd-2", "status" => "ok", "ticket" => %{"id" => "bd-2", "state" => "backlog"}}
    ],
    "counts" => %{"total" => 2, "ok" => 2, "refused" => 0, "not_found" => 0}
  }

  test "promote with several ids prints a line per id and exits 1 on a refusal" do
    stub_post("/api/issues/promote", @mixed, 200)

    {out, _err, exit_code} = capture(fn -> Promote.run(~w(bd-1 bd-2 bd-3)) end)

    assert exit_code == 1
    assert out =~ "ok         bd-1 (queued)"
    assert out =~ "refused    bd-2: needs acceptance criteria"
    assert out =~ "not_found  bd-3: task bd-3 not found"
    assert out =~ "1 ok, 1 refused, 1 not found (3 total)"
  end

  test "promote --json returns the per-id list, still exits 1" do
    stub_post("/api/issues/promote", @mixed, 200)

    {out, _err, exit_code} = capture(fn -> Promote.run(~w(bd-1 bd-2 bd-3 --json)) end)

    assert exit_code == 1
    assert {:ok, %{"results" => [_, _, _], "counts" => %{"total" => 3}}} = Jason.decode(out)
  end

  test "promote sends ids and the shared waiver in one request" do
    stub_routes([
      {{"post", "/api/issues/promote"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         body = Jason.decode!(raw)
         send(self(), {:body, body})
         Req.Test.json(conn, @all_ok)
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Promote.run(~w(bd-1 bd-2 --waive spike)) end)

    assert exit_code == 0
    assert_received {:body, %{"ids" => ["bd-1", "bd-2"], "acceptance_waived" => "spike"}}
  end

  test "--stdin reads one id per line (blank lines ignored) alongside positional ids" do
    stub_routes([
      {{"post", "/api/issues/demote"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(self(), {:body, Jason.decode!(raw)})
         Req.Test.json(conn, @all_ok)
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Demote.run(~w(bd-1 --stdin)) end, input: "bd-2\n\n bd-3 \n")

    assert exit_code == 0
    assert out =~ "2 ok"
    assert_received {:body, %{"ids" => ["bd-1", "bd-2", "bd-3"]}}
  end

  test "--stdin with a single id is still a bulk call" do
    stub_post("/api/issues/promote", @all_ok, 200)
    {out, _err, 0} = capture(fn -> Promote.run(~w(--stdin)) end, input: "bd-1\n")
    assert out =~ "2 ok"
  end

  test "demote with several ids exits 1 when one is not found" do
    stub_post("/api/issues/demote", @mixed, 200)
    {out, _err, exit_code} = capture(fn -> Demote.run(~w(bd-1 bd-3)) end)
    assert exit_code == 1
    assert out =~ "not_found  bd-3"
  end

  test "rank with several ids posts one shared move" do
    stub_routes([
      {{"post", "/api/issues/rank"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(self(), {:body, Jason.decode!(raw)})
         Req.Test.json(conn, @all_ok)
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Rank.run(~w(bd-1 bd-2 --top)) end)
    assert exit_code == 0
    assert_received {:body, %{"ids" => ["bd-1", "bd-2"], "top" => true}}
  end

  test "rank still validates the move form in bulk mode" do
    {_out, err, exit_code} = capture(fn -> Rank.run(~w(bd-1 bd-2)) end)
    assert exit_code == 1
    assert err =~ "exactly one of"
  end

  test "no ids and --stdin with nothing is an error" do
    {_out, err, exit_code} = capture(fn -> Promote.run(~w(--stdin)) end, input: "")
    assert exit_code == 1
    assert err =~ "at least one ticket id"
  end

  test "over the cap is a clear error before any request" do
    ids = Enum.map(1..201, &"bd-#{&1}")
    {_out, err, exit_code} = capture(fn -> Promote.run(ids) end)
    assert exit_code == 1
    assert err =~ "at most 200"
  end
end
