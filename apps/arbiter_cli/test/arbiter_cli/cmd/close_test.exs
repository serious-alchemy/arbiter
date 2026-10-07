defmodule ArbiterCli.Cmd.CloseTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Close

  @closed_issue %{"id" => "bd-001", "title" => "X", "state" => "closed"}

  test "close success prints updated issue" do
    stub_routes([
      {{"post", "/api/issues/bd-001/close"}, {@closed_issue, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "closed"
  end

  test "close with --reason" do
    stub_routes([
      {{"post", "/api/issues/bd-001/close"}, {@closed_issue, 200}}
    ])

    {out, _err, exit_code} =
      capture(fn -> Close.run(["bd-001", "--reason", "no longer needed"]) end)

    assert exit_code == 0
    assert out =~ "closed"
  end

  test "sends no close_upstream by default and never pre-fetches the ticket (D-T-12)" do
    stub_routes([
      {{"post", "/api/issues/bd-001/close"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         parsed = Jason.decode!(body)
         refute Map.has_key?(parsed, "close_upstream")
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@closed_issue)
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Close.run(["bd-001"]) end)
    assert exit_code == 0
  end

  test "--no-upstream sends close_upstream: false" do
    stub_routes([
      {{"post", "/api/issues/bd-001/close"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"reason" => "dup", "close_upstream" => false}
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@closed_issue)
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Close.run(["bd-001", "--no-upstream", "--reason", "dup"]) end)

    assert exit_code == 0
  end

  test "--help lists --no-upstream" do
    {out, _err, 0} = capture(fn -> Close.run(["--help"]) end)
    assert out =~ "--no-upstream"
  end

  test "close requires id" do
    {_out, err, exit_code} = capture(fn -> Close.run([]) end)
    assert exit_code == 1
    assert err =~ "requires a ticket id"
  end
end
