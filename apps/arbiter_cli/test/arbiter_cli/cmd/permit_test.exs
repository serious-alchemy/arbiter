defmodule ArbiterCli.Cmd.PermitTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Permit

  @granted %{
    "id" => "bd-001",
    "permission" => "prod_read",
    "decision" => "granted",
    "message" => "prod_read granted; it reaches the worker at its next spawn",
    "pending_permissions" => ["prod_ssh"]
  }

  test "grant posts the permission and prints the decision" do
    stub_routes([
      {{"post", "/api/issues/bd-001/permission"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"permission" => "prod_read"}
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@granted)
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Permit.run(["bd-001", "prod_read"]) end)

    assert exit_code == 0
    assert out =~ "prod_read granted"
    assert out =~ "still pending: prod_ssh"
  end

  test "deny posts deny and the reason" do
    stub_routes([
      {{"post", "/api/issues/bd-001/permission"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)

         assert Jason.decode!(body) ==
                  %{"permission" => "prod_read", "deny" => true, "reason" => "use the dump"}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{@granted | "decision" => "denied", "pending_permissions" => []})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn ->
        Permit.run(["bd-001", "prod_read", "--deny", "--reason", "use the dump"])
      end)

    assert exit_code == 0
    assert out =~ "prod_read denied"
  end

  test "deny without a reason is refused before any request" do
    {_out, err, exit_code} = capture(fn -> Permit.run(["bd-001", "prod_read", "--deny"]) end)
    assert exit_code != 0
    assert err =~ "--reason"
  end

  test "needs an id and a permission" do
    {_out, err, exit_code} = capture(fn -> Permit.run(["bd-001"]) end)
    assert exit_code != 0
    assert err =~ "permission"
  end

  test "an operator-only refusal from the server is reported" do
    stub_routes([
      {{"post", "/api/issues/bd-001/permission"},
       fn conn ->
         conn
         |> Plug.Conn.put_status(403)
         |> Req.Test.json(%{
           "error" => %{
             "type" => "forbidden",
             "message" => "prod_ssh is grant_by: operator; only the operator may decide it"
           }
         })
       end}
    ])

    {_out, err, exit_code} = capture(fn -> Permit.run(["bd-001", "prod_ssh"]) end)
    assert exit_code != 0
    assert err =~ "operator"
  end
end
