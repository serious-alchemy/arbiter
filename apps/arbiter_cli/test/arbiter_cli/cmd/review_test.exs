defmodule ArbiterCli.Cmd.ReviewTest do
  use ArbiterCli.CliCase, async: false

  describe "arb review" do
    test "missing task-id fails with usage hint" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run([]) end)
      assert err =~ "review requires a task id"
      assert code != 0
    end

    test "too many positional args fails" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["a", "b"]) end)
      assert err =~ "single positional"
      assert code != 0
    end

    test "happy path posts to /api/workers/review and renders text" do
      stub_post(
        "/api/workers/review",
        %{
          "task" => %{"id" => "bd-rev1", "title" => "review me", "state" => "active"},
          "worker" => %{"task_id" => "bd-rev1", "pid" => "#PID<0.123.0>"},
          "machine" => %{"id" => "mc-1", "pid" => "#PID<0.124.0>"},
          "worktree_path" => nil,
          "claude_started" => true
        }
      )

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["bd-rev1"]) end)
      assert code == 0
      assert out =~ "Review dispatched:"
      assert out =~ "bd-rev1 — review me"
      assert out =~ "State:    active"
      assert out =~ "Claude:   started"
    end

    test "--json mode emits JSON" do
      stub_post("/api/workers/review", %{
        "task" => %{"id" => "bd-rev1", "title" => "t", "state" => "active"},
        "worker" => %{"task_id" => "bd-rev1", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["bd-rev1", "--json"]) end)

      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["task"]["id"] == "bd-rev1"
    end

    test "passes --repo and --model in body when provided" do
      parent = self()
      name = Process.get(:bd2_stub_name)

      Req.Test.stub(name, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/workers/review"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "task" => %{"id" => "bd-rev1", "title" => "t", "state" => "active"},
              "worker" => %{"task_id" => "bd-rev1", "pid" => "x"},
              "machine" => %{"id" => "m", "pid" => "y"}
            })

          _ ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
        end
      end)

      {_out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Review.run(["bd-rev1", "--repo", "apex_server", "--model", "haiku"])
        end)

      assert code == 0
      assert_receive {:body, body}
      assert body["task_id"] == "bd-rev1"
      assert body["repo"] == "apex_server"
      assert body["model"] == "haiku"
    end

    test "404 propagates as die" do
      stub_post(
        "/api/workers/review",
        %{"error" => %{"type" => "not_found", "message" => "task not found"}},
        404
      )

      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["nope-1"]) end)
      assert code != 0
      assert err =~ "not found" || err =~ "404"
    end
  end

  describe "arb review --pr (external PR)" do
    test "posts pr/repo/workspace and renders the dispatched ack" do
      parent = self()
      name = Process.get(:bd2_stub_name)

      Req.Test.stub(name, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/workers/review"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "data" => %{
                "external" => true,
                "status" => "dispatched",
                "pr" => "acme/apex_sigv4#5",
                "mr_ref" => "acme/apex_sigv4#5",
                "strategy" => "github",
                "link" => "https://github.com/acme/apex_sigv4/pull/5"
              }
            })

          _ ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
        end
      end)

      {out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Review.run(["--pr", "acme/apex_sigv4#5", "--repo", "apex_sigv4"])
        end)

      assert code == 0
      assert_receive {:body, body}
      assert body["pr"] == "acme/apex_sigv4#5"
      assert body["repo"] == "apex_sigv4"
      refute Map.has_key?(body, "task_id")

      assert out =~ "External review dispatched:"
      assert out =~ "acme/apex_sigv4#5"
      assert out =~ "github"
      assert out =~ "https://github.com/acme/apex_sigv4/pull/5"
    end

    test "--pr with --json emits the JSON payload" do
      stub_post("/api/workers/review", %{
        "data" => %{"external" => true, "pr" => "#5", "mr_ref" => "#5", "strategy" => "github"}
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["--pr", "#5", "--json"]) end)

      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["data"]["pr"] == "#5"
    end
  end

  describe "arb review --transcript (bd-7efini)" do
    @payload %{
      "data" => %{
        "record_id" => "rec-1",
        "pr_ref" => "github:acme/widgets#42",
        "status" => "completed",
        "model" => "claude-opus-5",
        "path" => "/logs/rec-1.log",
        "prompt_path" => "/logs/rec-1.prompt",
        "exists" => true,
        "prompt_exists" => true,
        "prompt" => "You are a code reviewer.",
        "line_count" => 4,
        "lines" => [~s({"type":"result","result":"done"})],
        "truncated" => false,
        "tool_use_count" => 1,
        "tools_used" => [%{"name" => "Read", "count" => 1}],
        "tool_uses" => [
          %{"name" => "Read", "input" => %{"file_path" => "lib/a.ex"}, "result" => "contents"}
        ]
      }
    }

    test "fetches and renders one review's durable corpus" do
      stub_get("/api/external_reviews/rec-1/transcript", @payload)

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["--transcript", "rec-1"]) end)

      assert code == 0
      assert out =~ "github:acme/widgets#42"
      assert out =~ "You are a code reviewer."
      assert out =~ "Read ×1"
      assert out =~ "lib/a.ex"
      assert out =~ "/logs/rec-1.log"
    end

    test "--json emits the raw payload" do
      stub_get("/api/external_reviews/rec-1/transcript", @payload)

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["--transcript", "rec-1", "--json"]) end)

      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["data"]["record_id"] == "rec-1"
    end

    test "says so when nothing was captured" do
      stub_get("/api/external_reviews/rec-2/transcript", %{
        "data" =>
          Map.merge(@payload["data"], %{
            "record_id" => "rec-2",
            "exists" => false,
            "prompt_exists" => false,
            "prompt" => nil,
            "line_count" => 0,
            "lines" => [],
            "tool_use_count" => 0,
            "tools_used" => [],
            "tool_uses" => []
          })
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["--transcript", "rec-2"]) end)

      assert code == 0
      assert out =~ "no transcript captured"
    end
  end

  # Captures the request a stubbed route receives: {:req, method, path, query, body}.
  defp stub_capture(method, path, payload, status \\ 200) do
    parent = self()
    name = Process.get(:bd2_stub_name)

    Req.Test.stub(name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      send(parent, {:req, conn.method, conn.request_path, conn.query_string, body})

      if conn.method == method and conn.request_path == path do
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(payload)
      else
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
      end
    end)
  end

  describe "arb review --pr flags (D-W-6)" do
    test "sends report_only, force, follow_up, scope and tracker_context_*" do
      stub_capture(
        "POST",
        "/api/workers/review",
        %{"data" => %{"pr" => "5", "mr_ref" => "o/r#5"}},
        201
      )

      {_out, _err, 0} =
        capture(fn ->
          ArbiterCli.Cmd.Review.run([
            "--pr",
            "5",
            "--report-only",
            "--force",
            "--no-follow-up",
            "--scope",
            "repo",
            "--tracker-context-ref",
            "PROJ-7",
            "--tracker-context-type",
            "jira"
          ])
        end)

      assert_receive {:req, "POST", "/api/workers/review", _, body}

      assert body == %{
               "pr" => "5",
               "report_only" => true,
               "force" => true,
               "follow_up" => false,
               "scope" => "repo",
               "tracker_context_ref" => "PROJ-7",
               "tracker_context_type" => "jira"
             }
    end

    test "the workspace is sent as named" do
      stub_capture("POST", "/api/workers/review", %{"data" => %{}}, 201)

      {_out, _err, 0} =
        capture(fn ->
          ArbiterCli.Cmd.Review.run(["--pr", "5", "--workspace", "acme"])
        end)

      assert_receive {:req, "POST", "/api/workers/review", _, %{"workspace" => "acme"}}
    end
  end

  describe "arb review routing (AC 1)" do
    test "`arb review --pr N` reaches the external-review call, not `worker review`" do
      stub_capture("POST", "/api/workers/review", %{"data" => %{"mr_ref" => "o/r#5"}}, 201)

      {out, err, 0} = capture(fn -> ArbiterCli.Main.main(["review", "--pr", "5"]) end)

      assert_receive {:req, "POST", "/api/workers/review", _, %{"pr" => "5"} = body}
      refute Map.has_key?(body, "task_id")
      assert out =~ "External review dispatched"
      refute err =~ "is now `arb worker review`"
    end

    test "`arb review <task-id>` still dispatches a task review, with no redirect note" do
      stub_capture(
        "POST",
        "/api/workers/review",
        %{"task" => %{"id" => "bd-1", "title" => "t", "state" => "active"}},
        201
      )

      {_out, err, 0} = capture(fn -> ArbiterCli.Main.main(["review", "bd-1"]) end)

      assert_receive {:req, "POST", "/api/workers/review", _, %{"task_id" => "bd-1"}}
      refute err =~ "is now"
    end

    test "`arb review resolve` still records a gate resolution" do
      stub_capture("POST", "/api/issues/bd-1/resolve", %{"resolution" => %{}}, 201)

      capture(fn -> ArbiterCli.Main.main(["review", "resolve", "bd-1", "--amend", "why"]) end)

      assert_receive {:req, "POST", "/api/issues/bd-1/resolve", _, %{"decision" => "amend"}}
    end

    test "all six verbs are registered under one `review` entry" do
      assert {:ok, %{kind: :resource, handler: ArbiterCli.Cmd.Review, probes: probes}} =
               ArbiterCli.Verbs.fetch("review")

      subs = for [sub | _] <- probes, do: sub
      assert ~w(list show transcript rounds greenlight) -- subs == []
    end
  end

  @record %{
    "id" => "rec-1",
    "pr_ref" => "octo/widget#42",
    "status" => "completed",
    "mode" => "report_only",
    "greenlight_status" => "pending",
    "verdict" => "request_changes",
    "proposed_count" => 2,
    "finding_count" => 2
  }

  describe "arb review list" do
    test "passes the filters and renders a table with the greenlight state" do
      stub_capture("GET", "/api/external_reviews", %{"data" => [@record]})

      {out, _err, 0} =
        capture(fn ->
          ArbiterCli.Cmd.Review.run([
            "list",
            "--status",
            "completed",
            "--since",
            "2026-01-01T00:00:00Z",
            "--limit",
            "5"
          ])
        end)

      assert_receive {:req, "GET", "/api/external_reviews", query, _}

      assert URI.decode_query(query) == %{
               "status" => "completed",
               "since" => "2026-01-01T00:00:00Z",
               "limit" => "5"
             }

      assert out =~ "rec-1"
      assert out =~ "report_only"
      assert out =~ "pending"
      assert out =~ "2 proposed"
    end

    test "--json emits the payload" do
      stub_capture("GET", "/api/external_reviews", %{"data" => [@record]})
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Review.run(["list", "--json"]) end)
      assert %{"data" => [%{"id" => "rec-1"}]} = Jason.decode!(out)
    end
  end

  describe "arb review show" do
    test "numbers the proposed comments so --select has something to point at" do
      stub_capture("GET", "/api/external_reviews/rec-1", %{
        "data" =>
          Map.merge(@record, %{
            "transcript_exists" => false,
            "proposed_comments" => [
              %{
                "file" => "a.ex",
                "line" => 1,
                "severity" => "error",
                "body" => "**ERROR**: boom",
                "in_diff" => true
              },
              %{
                "file" => "b.ex",
                "line" => 2,
                "severity" => "info",
                "body" => "nit",
                "in_diff" => false
              }
            ]
          })
      })

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Review.run(["show", "rec-1"]) end)

      assert out =~ "[0] a.ex:1 error"
      assert out =~ "[1] b.ex:2 info [out of diff"
      assert out =~ "boom"
    end

    test "requires an id" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["show"]) end)
      assert code != 0
      assert err =~ "review show requires"
    end
  end

  describe "arb review transcript" do
    test "is the subcommand spelling of --transcript" do
      stub_capture("GET", "/api/external_reviews/rec-1/transcript", %{
        "data" => %{
          "record_id" => "rec-1",
          "pr_ref" => "o/r#1",
          "status" => "completed",
          "exists" => false
        }
      })

      {out, _err, 0} =
        capture(fn ->
          ArbiterCli.Cmd.Review.run(["transcript", "rec-1", "--tail", "3", "--no-prompt"])
        end)

      assert_receive {:req, "GET", "/api/external_reviews/rec-1/transcript", query, _}
      assert URI.decode_query(query) == %{"tail" => "3", "include_prompt" => "false"}
      assert out =~ "o/r#1"
    end
  end

  describe "arb review rounds" do
    test "asks for the task's rounds and renders the outcome and resolutions" do
      stub_capture("GET", "/api/review_gate_rounds", %{
        "data" => [
          %{
            "round" => 1,
            "fix_round_attempt" => 0,
            "role" => "review",
            "verdict" => "request_changes",
            "finding_count" => 2,
            "reviewer_provider" => "claude",
            "reviewer_model" => "opus"
          }
        ],
        "count" => 1,
        "total_count" => 3,
        "outcome" => "resolved",
        "resolutions" => [
          %{"decision" => "amend", "gate" => "review_gate", "reasoning" => "by hand"}
        ]
      })

      {out, _err, 0} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["rounds", "bd-1", "--limit", "1"]) end)

      assert_receive {:req, "GET", "/api/review_gate_rounds", query, _}
      assert URI.decode_query(query) == %{"task_id" => "bd-1", "limit" => "1"}
      assert out =~ "1 of 3 round(s) — outcome: resolved"
      assert out =~ "resolved: amend"
    end
  end

  describe "arb review greenlight" do
    @result %{
      "data" => %{
        "mr_ref" => "octo/widget#42",
        "posted" => 1,
        "selected" => 1,
        "proposed" => 2,
        "skipped" => 0,
        "verdict_posted" => true,
        "verdict" => "request_changes"
      }
    }

    test "--select 0,2 posts those indices" do
      stub_capture("POST", "/api/external_reviews/rec-1/greenlight", @result)

      {out, _err, 0} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["greenlight", "rec-1", "--select", "0,2"]) end)

      assert_receive {:req, "POST", "/api/external_reviews/rec-1/greenlight", _, body}
      assert body == %{"select" => [0, 2]}
      assert out =~ "Posted:   1 of 2"
      assert out =~ "submitted (request_changes)"
    end

    test "defaults send no select (all); none approves nothing; --no-post-verdict is forwarded" do
      stub_capture("POST", "/api/external_reviews/rec-1/greenlight", @result)

      capture(fn -> ArbiterCli.Cmd.Review.run(["greenlight", "rec-1"]) end)
      assert_receive {:req, "POST", _, _, %{} = default}
      assert default == %{}

      capture(fn ->
        ArbiterCli.Cmd.Review.run([
          "greenlight",
          "rec-1",
          "--select",
          "none",
          "--no-post-verdict",
          "--repo",
          "widget"
        ])
      end)

      assert_receive {:req, "POST", _, _, body}
      assert body == %{"select" => [], "post_verdict" => false, "repo" => "widget"}
    end

    test "a malformed --select dies before any request" do
      {_out, err, code} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["greenlight", "rec-1", "--select", "a,b"]) end)

      assert code != 0
      assert err =~ "invalid --select"
      refute_received {:req, _, _, _, _}
    end

    test "a server refusal (403) is reported" do
      stub_capture(
        "POST",
        "/api/external_reviews/rec-1/greenlight",
        %{"error" => %{"type" => "unauthorized", "message" => "this token may not dispatch"}},
        403
      )

      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["greenlight", "rec-1"]) end)
      assert code != 0
      assert err =~ "may not dispatch"
    end
  end
end
