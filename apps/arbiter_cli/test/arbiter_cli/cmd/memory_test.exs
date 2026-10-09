defmodule ArbiterCli.Cmd.MemoryTest do
  @moduledoc """
  `arb memory pending|diff|apply|reject|quarantine|restore|distill` (P-25):
  the operator CLI over `/api/memory/*`.
  """
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Memory

  @candidate %{
    "id" => "sess-1/habit.md",
    "session_id" => "sess-1",
    "filename" => "habit.md",
    "name" => "habit",
    "type" => "feedback",
    "description" => "Prefer small PRs",
    "bytes" => 120,
    "replaces_shared" => true
  }

  # Echo the request (method, path, query, JSON body) back so a test can assert
  # on exactly what the CLI sent.
  defp stub_echo(method, path, response) do
    parent = self()

    stub_routes([
      {{method, path},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         body = if raw == "", do: %{}, else: Jason.decode!(raw)
         send(parent, {:req, conn.query_string, body})
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(response)
       end}
    ])
  end

  describe "pending" do
    test "lists candidates" do
      stub_echo("get", "/api/memory/pending", %{"candidates" => [@candidate], "count" => 1})

      {out, _err, code} = capture(fn -> Memory.run(["pending"]) end)

      assert code == 0
      assert out =~ "sess-1/habit.md"
      assert out =~ "feedback"
      assert out =~ "replaces shared"
      assert_received {:req, "", _}
    end

    test "--state rejected is forwarded, and an empty queue says so" do
      stub_echo("get", "/api/memory/pending", %{"candidates" => [], "count" => 0})

      {out, _err, 0} = capture(fn -> Memory.run(["pending", "--state", "rejected"]) end)

      assert out =~ "No rejected"
      assert_received {:req, "state=rejected", _}
    end

    test "--json prints the body untouched" do
      stub_echo("get", "/api/memory/pending", %{"candidates" => [@candidate], "count" => 1})

      {out, _err, 0} = capture(fn -> Memory.run(["pending", "--json"]) end)

      assert %{"count" => 1} = Jason.decode!(out)
    end
  end

  describe "diff" do
    test "prints verification and the diff for the id" do
      stub_echo("get", "/api/memory/pending/diff", %{
        "id" => "sess-1/habit.md",
        "content" => "new text",
        "diff" => "--- shared/habit.md\n+++ candidate/habit.md\n-old\n+new",
        "verification" => %{"status" => "ok", "reasons" => []}
      })

      {out, _err, 0} = capture(fn -> Memory.run(["diff", "sess-1/habit.md"]) end)

      assert out =~ "+new"
      assert out =~ "ok"
      assert_received {:req, query, _}
      assert URI.decode_query(query) == %{"id" => "sess-1/habit.md"}
    end

    test "a missing id is a usage error" do
      {_out, err, code} = capture(fn -> Memory.run(["diff"]) end)

      assert code == 1
      assert err =~ "id"
    end
  end

  describe "apply" do
    test "posts the id and overwrite flag" do
      stub_echo("post", "/api/memory/pending/apply", %{
        "id" => "sess-1/habit.md",
        "memory" => "habit.md",
        "promoted" => true,
        "status" => "ok"
      })

      {out, _err, 0} = capture(fn -> Memory.run(["apply", "sess-1/habit.md", "--overwrite"]) end)

      assert out =~ "habit.md"
      assert_received {:req, _, %{"id" => "sess-1/habit.md", "overwrite" => true}}
    end

    test "a refusal (stale) exits non-zero with the reasons" do
      stub_request(
        :post,
        "/api/memory/pending/apply",
        %{"error" => %{"type" => "conflict", "message" => "stale: lib/a.ex:9", "details" => %{}}},
        409
      )

      {_out, err, code} = capture(fn -> Memory.run(["apply", "sess-1/habit.md"]) end)

      assert code == 1
      assert err =~ "lib/a.ex:9"
    end
  end

  describe "reject" do
    test "posts the id and reason" do
      stub_echo("post", "/api/memory/pending/reject", %{
        "id" => "sess-1/habit.md",
        "rejected" => true,
        "kept_at" => "/x/rejected/habit.md"
      })

      {out, _err, 0} =
        capture(fn -> Memory.run(["reject", "sess-1/habit.md", "--reason", "too vague"]) end)

      assert out =~ "Rejected"
      assert_received {:req, _, %{"id" => "sess-1/habit.md", "reason" => "too vague"}}
    end

    test "a missing --reason is a usage error before any request" do
      {_out, err, code} = capture(fn -> Memory.run(["reject", "sess-1/habit.md"]) end)

      assert code == 1
      assert err =~ "--reason"
    end
  end

  describe "quarantine and restore" do
    test "quarantine lists name, reason and sha" do
      stub_echo("get", "/api/memory/quarantine", %{
        "count" => 1,
        "quarantined" => [
          %{
            "name" => "stale.md",
            "quarantined_from" => "stale.md",
            "reason" => "lib/short.ex:99 is gone",
            "sha" => "abc1234",
            "quarantined_at" => "2026-10-09T00:00:00Z"
          }
        ]
      })

      {out, _err, 0} = capture(fn -> Memory.run(["quarantine"]) end)

      assert out =~ "stale.md"
      assert out =~ "lib/short.ex:99 is gone"
    end

    test "restore posts name and reanchor" do
      stub_echo("post", "/api/memory/quarantine/restore", %{
        "name" => "stale.md",
        "memory" => "stale.md",
        "restored" => true,
        "status" => "ok"
      })

      {out, _err, 0} = capture(fn -> Memory.run(["restore", "stale.md", "--reanchor"]) end)

      assert out =~ "Restored"
      assert_received {:req, _, %{"name" => "stale.md", "reanchor" => true}}
    end
  end

  describe "distill" do
    test "posts the session id and only the bounds given" do
      stub_echo("post", "/api/memory/distill", %{
        "session_id" => "sess-1",
        "count" => 1,
        "candidates" => [%{"id" => "sess-1/a.md", "name" => "a", "type" => "feedback"}],
        "rejected" => [],
        "window" => %{},
        "cost" => %{"cost_usd" => 0.01, "max_cost_usd" => 0.5, "over_budget" => false}
      })

      {out, _err, 0} =
        capture(fn -> Memory.run(["distill", "sess-1", "--max-candidates", "3"]) end)

      assert out =~ "sess-1/a.md"
      assert_received {:req, _, body}
      assert body == %{"session_id" => "sess-1", "max_candidates" => 3}
    end
  end

  test "an unknown subcommand exits 2" do
    {_out, err, code} = capture(fn -> Memory.run(["bogus"]) end)

    assert code == 2
    assert err =~ "unknown memory subcommand"
  end

  test "--help prints usage" do
    {out, _err, 0} = capture(fn -> Memory.run(["--help"]) end)
    assert out =~ "arb memory"
  end
end
