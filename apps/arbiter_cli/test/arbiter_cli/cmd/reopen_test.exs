defmodule ArbiterCli.Cmd.ReopenTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Reopen

  test "reopen success prints updated issue" do
    stub_post(
      "/api/issues/bd-001/reopen",
      %{"id" => "bd-001", "title" => "X", "state" => "queued"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Reopen.run(["bd-001"]) end)
    assert exit_code == 0
    assert out =~ "bd-001"
    assert out =~ "queued"
  end

  test "reopen --json emits raw JSON" do
    stub_post(
      "/api/issues/bd-001/reopen",
      %{"id" => "bd-001", "title" => "X", "state" => "queued"},
      200
    )

    {out, _err, exit_code} = capture(fn -> Reopen.run(["bd-001", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"state" => "queued"}} = Jason.decode(out)
  end

  test "reopen requires id" do
    {_out, err, exit_code} = capture(fn -> Reopen.run([]) end)
    assert exit_code == 1
    assert err =~ "requires a ticket id"
  end

  test "reopen of a non-closed task surfaces the transition refusal" do
    stub_post(
      "/api/issues/bd-001/reopen",
      %{
        "error" => %{
          "type" => "validation_error",
          "message" => "validation failed",
          "details" => %{
            "errors" => [
              %{
                "field" => "state",
                "message" =>
                  "Cannot reopen a ticket that is :queued: reopen moves :closed | :verifying → :queued."
              }
            ]
          }
        }
      },
      422
    )

    {_out, err, exit_code} = capture(fn -> Reopen.run(["bd-001"]) end)
    assert exit_code == 1
    assert err =~ "bd-001 could not be reopened"
    assert err =~ "Cannot reopen a ticket that is :queued"
    refute err =~ "validation failed"
  end
end
