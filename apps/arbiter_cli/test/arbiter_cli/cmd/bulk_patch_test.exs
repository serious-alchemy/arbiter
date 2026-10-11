defmodule ArbiterCli.Cmd.BulkPatchTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.{Close, Update, Verify}

  @mixed %{
    "results" => [
      %{"id" => "bd-1", "status" => "ok", "ticket" => %{"id" => "bd-1", "state" => "closed"}},
      %{"id" => "bd-2", "status" => "refused", "reason" => "not awaiting verification"},
      %{"id" => "bd-3", "status" => "not_found", "reason" => "task bd-3 not found"}
    ],
    "counts" => %{"total" => 3, "ok" => 1, "refused" => 1, "not_found" => 1}
  }

  @all_ok %{
    "results" => [
      %{"id" => "bd-1", "status" => "ok", "ticket" => %{"id" => "bd-1", "state" => "queued"}},
      %{"id" => "bd-2", "status" => "ok", "ticket" => %{"id" => "bd-2", "state" => "queued"}}
    ],
    "counts" => %{"total" => 2, "ok" => 2, "refused" => 0, "not_found" => 0}
  }

  defp capture_body(method, path, response) do
    stub_routes([
      {{method, path},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(self(), {:body, Jason.decode!(raw)})
         Req.Test.json(conn, response)
       end}
    ])
  end

  test "update: several ids send one patch and exit 0 when all ok" do
    capture_body("patch", "/api/issues", @all_ok)

    {out, _err, exit_code} =
      capture(fn -> Update.run(~w(bd-1 bd-2 --priority 1 --append-notes more)) end)

    assert exit_code == 0
    assert out =~ "2 ok"

    assert_received {:body,
                     %{
                       "ids" => ["bd-1", "bd-2"],
                       "patch" => %{"priority" => 1, "append_notes" => "more"}
                     }}
  end

  test "update: mixed result exits 1 with a line per id" do
    stub_patch("/api/issues", @mixed, 200)
    {out, _err, exit_code} = capture(fn -> Update.run(~w(bd-1 bd-2 bd-3 --priority 2)) end)
    assert exit_code == 1
    assert out =~ "refused    bd-2: not awaiting verification"
    assert out =~ "not_found  bd-3"
  end

  test "update: bulk --notes needs --confirm-replace-notes" do
    {_out, err, exit_code} = capture(fn -> Update.run(~w(bd-1 bd-2 --notes replaced)) end)
    assert exit_code == 1
    assert err =~ "REPLACE"

    capture_body("patch", "/api/issues", @all_ok)

    {_out, _err, exit_code} =
      capture(fn -> Update.run(~w(bd-1 bd-2 --notes replaced --confirm-replace-notes)) end)

    assert exit_code == 0

    assert_received {:body,
                     %{"confirm_replace_notes" => true, "patch" => %{"notes" => "replaced"}}}
  end

  test "update: --stdin is a bulk call" do
    capture_body("patch", "/api/issues", @all_ok)

    {_out, _err, exit_code} =
      capture(fn -> Update.run(~w(bd-1 --stdin --difficulty 3)) end, input: "bd-2\n")

    assert exit_code == 0
    assert_received {:body, %{"ids" => ["bd-1", "bd-2"]}}
  end

  test "close: several ids share reason; mixed exits 1" do
    capture_body("post", "/api/issues/close", @mixed)
    {out, _err, exit_code} = capture(fn -> Close.run(~w(bd-1 bd-2 bd-3 --reason swept)) end)
    assert exit_code == 1
    assert out =~ "1 ok, 1 refused, 1 not found"
    assert_received {:body, %{"ids" => ["bd-1", "bd-2", "bd-3"], "reason" => "swept"}}
  end

  test "verify: --failed sends the shared outcome for all ids" do
    capture_body("post", "/api/issues/verify", @all_ok)

    {_out, _err, exit_code} =
      capture(fn -> Verify.run(["bd-1", "bd-2", "--failed", "still broken"]) end)

    assert exit_code == 0

    assert_received {:body,
                     %{
                       "ids" => ["bd-1", "bd-2"],
                       "outcome" => "failed",
                       "evidence" => "still broken"
                     }}
  end

  test "verify: mixed result exits 1" do
    stub_post("/api/issues/verify", @mixed, 200)
    {_out, _err, exit_code} = capture(fn -> Verify.run(~w(bd-1 bd-2 bd-3 --observed ok)) end)
    assert exit_code == 1
  end
end
