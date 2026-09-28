defmodule ArbiterCli.Cmd.HandoffTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Handoff

  @issue %{
    "id" => "bd-001",
    "title" => "X",
    "priority" => 2,
    "attention_owner" => "coordinator",
    "attention_note" => "retry now"
  }

  test "handback posts the note and prints who owns it now" do
    stub_routes([
      {{"post", "/api/issues/bd-001/handback"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"note" => "retry now"}
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(@issue)
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Handoff.run(:coordinator, ["bd-001", "--note", "retry now"]) end)

    assert exit_code == 0
    assert out =~ "bd-001"
    assert out =~ "attention: coordinator"
  end

  test "handoff requires a note" do
    {_out, err, exit_code} = capture(fn -> Handoff.run(:operator, ["bd-001"]) end)
    assert exit_code != 0
    assert err =~ "--note"
  end

  test "handoff posts to /handoff" do
    stub_routes([
      {{"post", "/api/issues/bd-001/handoff"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"note" => "yours"}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{@issue | "attention_owner" => "operator"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Handoff.run(:operator, ["bd-001", "--note", "yours"]) end)

    assert exit_code == 0
    assert out =~ "attention: operator"
  end

  test "a refusal from the server is reported" do
    stub_routes([
      {{"post", "/api/issues/bd-001/handback"},
       fn conn ->
         conn
         |> Plug.Conn.put_status(422)
         |> Req.Test.json(%{
           "error" => %{
             "type" => "validation_error",
             "message" => "no attention",
             "details" => %{}
           }
         })
       end}
    ])

    {_out, err, exit_code} = capture(fn -> Handoff.run(:coordinator, ["bd-001"]) end)
    assert exit_code != 0
    assert err =~ "no attention"
  end
end
