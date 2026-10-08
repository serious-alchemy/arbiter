defmodule ArbiterCli.Cmd.AttentionTest do
  @moduledoc "`arb attention` (P-27): the attention queue, `GET /api/attention`."
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Attention

  @item %{
    "ticket_id" => "bd-1",
    "title" => "Fix the thing",
    "state" => "active",
    "workspace_id" => "ws-1",
    "owner" => "coordinator",
    "reason" => "the run crashed",
    "note" => "boom",
    "since" => "2026-10-07T12:00:00Z"
  }

  test "prints each item" do
    stub_get("/api/attention", %{"attention" => [@item], "attention_count" => 1})

    {out, _err, code} = capture(fn -> Attention.run([]) end)

    assert code == 0
    assert out =~ "bd-1"
    assert out =~ "the run crashed"
    assert out =~ "[note: boom]"
  end

  test "says so when the queue is empty" do
    stub_get("/api/attention", %{"attention" => [], "attention_count" => 0})

    {out, _err, 0} = capture(fn -> Attention.run([]) end)
    assert out =~ "Nothing needs attention"
  end

  test "--json prints the REST body untouched" do
    body = %{"attention" => [@item], "attention_count" => 1, "workspace_id" => nil}
    stub_get("/api/attention", body)

    {out, _err, 0} = capture(fn -> Attention.run(["--json"]) end)
    assert Jason.decode!(out) == body
  end

  test "sends --owner and the resolved --workspace" do
    test_pid = self()

    Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/api/workspaces" ->
          Req.Test.json(conn, %{"data" => [%{"id" => "ws-acme", "name" => "acme"}]})

        "/api/attention" ->
          send(test_pid, {:query, conn.query_params})
          Req.Test.json(conn, %{"attention" => [], "attention_count" => 0})
      end
    end)

    {_out, err, code} =
      capture(fn -> Attention.run(["--owner", "operator", "--workspace", "acme"]) end)

    assert code == 0, err
    assert_received {:query, %{"owner" => "operator", "workspace" => "ws-acme"}}
  end

  test "an unknown flag is refused" do
    {_out, err, code} = capture(fn -> Attention.run(["--bogus"]) end)

    assert code == 1
    assert err =~ "unknown option --bogus for arb attention"
  end
end
