defmodule ArbiterCli.Cmd.ResolveTest do
  @moduledoc "bd-4qjl0q — `arb review resolve <ticket> --amend \"<reasoning>\"`."
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Resolve
  alias ArbiterCli.Main

  @resolution %{
    "id" => "res-1",
    "task_id" => "bd-001",
    "gate" => "review_gate",
    "decision" => "amend",
    "reasoning" => "heuristic need not be airtight",
    "actor" => "coordinator",
    "round" => 3,
    "fix_round_attempt" => 0,
    "inserted_at" => "2026-09-29T20:00:00Z"
  }

  # Stub the resolve endpoint and forward the decoded request body to the test
  # process, so the test can assert exactly what the CLI sent.
  defp stub_resolve(task_id \\ "bd-001") do
    test_pid = self()
    path = "/api/issues/#{task_id}/resolve"

    Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, Jason.decode!(raw)})

      if conn.request_path == path do
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(@resolution)
      else
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "path mismatch"})
      end
    end)
  end

  test "--amend posts the decision and reasoning in one call" do
    stub_resolve()

    {out, _err, code} =
      capture(fn -> Resolve.run(["bd-001", "--amend", "heuristic need not be airtight"]) end)

    assert code == 0
    assert_received {:request, "POST", "/api/issues/bd-001/resolve", body}
    assert body == %{"decision" => "amend", "reasoning" => "heuristic need not be airtight"}
    assert out =~ "amend"
    assert out =~ "bd-001"
  end

  test "each decision flag maps to its decision, with gate / round / actor passed through" do
    for {flag, decision} <- [
          {"--accept-as-is", "accept_as_is"},
          {"--send-back", "send_back"},
          {"--reject", "reject"}
        ] do
      stub_resolve()

      {_out, _err, code} =
        capture(fn ->
          Resolve.run([
            "bd-001",
            flag,
            "why",
            "--gate",
            "notes_gate",
            "--round",
            "2",
            "--actor",
            "operator"
          ])
        end)

      assert code == 0
      assert_received {:request, "POST", _, body}

      assert body == %{
               "decision" => decision,
               "reasoning" => "why",
               "gate" => "notes_gate",
               "round" => 2,
               "actor" => "operator"
             }
    end
  end

  test "--json prints the recorded resolution" do
    stub_resolve()

    {out, _err, code} = capture(fn -> Resolve.run(["bd-001", "--reject", "x", "--json"]) end)

    assert code == 0
    assert {:ok, %{"decision" => "amend", "round" => 3}} = Jason.decode(out)
  end

  test "requires a ticket id and exactly one decision flag" do
    {_out, err, code} = capture(fn -> Resolve.run(["--amend", "x"]) end)
    assert code == 1
    assert err =~ "requires a ticket id"

    {_out, err, code} = capture(fn -> Resolve.run(["bd-001"]) end)
    assert code == 1
    assert err =~ "--amend"

    {_out, err, code} = capture(fn -> Resolve.run(["bd-001", "--amend", "a", "--reject", "b"]) end)
    assert code == 1
    assert err =~ "exactly one"
  end

  test "`arb review resolve` routes here without a deprecation note" do
    stub_resolve()

    {_out, err, code} =
      capture(fn -> Main.main(["review", "resolve", "bd-001", "--amend", "why"]) end)

    assert code == 0
    refute err =~ "is now"
    assert_received {:request, "POST", "/api/issues/bd-001/resolve", %{"decision" => "amend"}}
  end

  test "`arb ticket resolve` is the same verb" do
    stub_resolve()

    {_out, _err, code} =
      capture(fn -> Main.main(["ticket", "resolve", "bd-001", "--send-back", "why"]) end)

    assert code == 0
    assert_received {:request, "POST", "/api/issues/bd-001/resolve", %{"decision" => "send_back"}}
  end
end
