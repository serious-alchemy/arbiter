defmodule ArbiterWeb.Api.LoopControllerTest do
  # async: false — the pass reads via raw SQL on the sandbox connection and we
  # swap the :output_log_root app env.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.PendingWrite
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "loop-ctrl-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), root: root}
  end

  # `Issue.workspace_id` is required, so every fixture task needs a home.
  defp workspace! do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "loop-ctrl-#{n}", prefix: "lc#{n}"})
    ws
  end

  defp run!(attrs) do
    base = %{
      task_id: "bd-ctrl",
      repo: "arbiter",
      # An authoring run, as the worker records it (bd-1uu19b: kind +
      # role replace worker_type :main).
      kind: :implement,
      role: "base",
      state: :finished,
      outcome: :succeeded,
      model: "claude-sonnet-5",
      started_at: DateTime.utc_now()
    }

    {:ok, run} = Ash.create(Run, Map.merge(base, attrs))
    run
  end

  describe "POST /api/loop/analyze (P-23)" do
    test "runs the pass, records its own cost row and returns the same envelope as GET", %{
      conn: conn
    } do
      _ = run!(%{task_id: "bd-ctrl-post", state: :finished, outcome: :succeeded})
      before = Event |> Ash.read!() |> length()

      conn = post(conn, ~p"/api/loop/analyze", %{since: "24h"})
      body = json_response(conn, 200)

      assert body["markdown"] =~ "Loop-analysis report"
      assert body["summary"]["totals"]
      assert {:ok, _} = Ash.get(Event, body["usage_event_id"])
      assert length(Ash.read!(Event)) == before + 1
      refute Map.has_key?(body, "proposals")
      assert get_resp_header(conn, "deprecation") == []
    end

    test "accepts an integer limit and rejects a bad one with 400", %{conn: conn} do
      assert conn |> post(~p"/api/loop/analyze", %{limit: 25}) |> json_response(200)

      conn = post(conn, ~p"/api/loop/analyze", %{limit: 0})
      assert json_response(conn, 400)
    end

    test "rejects a malformed since with 400", %{conn: conn} do
      assert conn |> post(~p"/api/loop/analyze", %{since: "not-a-date"}) |> json_response(400)
    end

    test "an unknown workspace is a 404, not an empty report", %{conn: conn} do
      conn = post(conn, ~p"/api/loop/analyze", %{workspace: "no-such-ws"})
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/loop/analyze is a deprecated alias (P-23)" do
    test "still answers, and is marked deprecated in the response headers", %{conn: conn} do
      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})

      assert %{"markdown" => _, "usage_event_id" => _} = json_response(conn, 200)
      assert get_resp_header(conn, "deprecation") == ["true"]
      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/loop/analyze"
      assert link =~ "successor-version"
      assert [warning] = get_resp_header(conn, "warning")
      assert warning =~ "deprecated"
    end
  end

  describe "GET /api/loop/analyze" do
    test "runs the pass over a window and returns the markdown report", %{conn: conn} do
      # A context-exhaustion run mislabelled as rate-limited.
      c88 =
        run!(%{
          task_id: "bd-dyfaq3",
          state: :finished,
          outcome: :failed,
          failure_reason: "agent was rate-limited / the API was overloaded"
        })

      {:ok, h} = OutputLog.open(c88.id)
      OutputLog.append(h, "Autocompact is thrashing: refilled within 3 turns, 3 times in a row.")
      OutputLog.append(h, "⚙ claude session error · 523.8s · $4.61")
      OutputLog.close(h)

      conn = get(conn, ~p"/api/loop/analyze", %{since: "7d"})
      body = json_response(conn, 200)

      assert is_binary(body["markdown"])
      assert body["markdown"] =~ "Loop-analysis report"
      assert body["markdown"] =~ c88.id
      assert body["markdown"] =~ "context_exhaustion"
      assert body["summary"]["totals"]["failed"] >= 1
      # The pass recorded its own cost row.
      assert body["usage_event_id"]
    end

    test "the pass writes only its own-cost usage row (report-only)", %{conn: conn} do
      _ = run!(%{task_id: "bd-ctrl-2", state: :finished, outcome: :succeeded})
      before = Event |> Ash.read!() |> length()

      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})
      assert %{"usage_event_id" => uid} = json_response(conn, 200)
      assert uid

      after_count = Event |> Ash.read!() |> length()
      assert after_count == before + 1

      {:ok, ev} = Ash.get(Event, uid)
      assert ev.step == :other
      assert ev.model == "loop-analysis-pass"
    end

    test "rejects a malformed since with 4xx", %{conn: conn} do
      conn = get(conn, ~p"/api/loop/analyze", %{since: "not-a-date"})
      assert response(conn, 400) || json_response(conn, 400)
    end

    test "the response body carries no :proposals key without the opt-in", %{conn: conn} do
      _ = run!(%{task_id: "bd-ctrl-3", state: :finished, outcome: :succeeded})

      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})
      body = json_response(conn, 200)

      refute Map.has_key?(body, "proposals")
      assert Ash.read!(PendingWrite) == []
    end

    # bd-5ja2vb: the finding-residue count/rate/distinct_tasks must reach the
    # compact JSON summary, not just the markdown, so a programmatic caller can
    # watch the ceiling without parsing prose.
    test "the JSON summary carries the finding-residue count/rate/distinct_tasks", %{conn: conn} do
      {:ok, issue} =
        Ash.create(Issue, %{title: "ctrl residue", difficulty: 1, workspace_id: workspace!().id})

      run =
        run!(%{
          task_id: issue.id,
          state: :finished,
          outcome: :failed,
          failure_reason: ":review_gate_rejected"
        })

      {:ok, _} =
        Ash.create(Round, %{
          task_id: issue.id,
          run_id: run.id,
          round: 1,
          role: :review,
          verdict: :request_changes,
          converged: false,
          findings: "1. The memoisation key omits the tenant id."
        })

      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})
      body = json_response(conn, 200)

      residue = body["summary"]["finding_residue"]
      assert residue["total_units"] == 1
      assert residue["count"] == 1
      assert residue["rate"] == 1.0
      assert residue["distinct_tasks"] == 1
      assert body["markdown"] =~ "memoisation key"
    end

    # bd-cuu8n3: the CI section reaches `--json` as structured data — the red
    # rate with counts and breakdowns, every fix_pass's class, the unknown
    # share, and the approved-PR-only undercount as metadata.
    test "the JSON summary carries the CI section", %{conn: conn} do
      ws = workspace!()
      {:ok, red} = Ash.create(Issue, %{title: "red", difficulty: 2, workspace_id: ws.id})
      {:ok, green} = Ash.create(Issue, %{title: "green", difficulty: 2, workspace_id: ws.id})
      red = Ash.update!(red, %{pr_ref: "#1"})
      green = Ash.update!(green, %{pr_ref: "#2"})

      run!(%{task_id: red.id, provider: "claude"})
      run!(%{task_id: green.id, provider: "claude"})
      fp = run!(%{task_id: red.id, kind: :fix_pass, role: "fix_pass", provider: "claude"})

      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})
      body = json_response(conn, 200)
      ci = body["summary"]["ci"]

      assert ci["red_rate"] == %{"tasks" => 2, "red" => 1, "rate" => 0.5}
      assert %{"key" => "arbiter", "tasks" => 2, "red" => 1} = hd(ci["by_repo"])
      assert %{"key" => "claude/claude-sonnet-5"} = hd(ci["by_model"])
      assert %{"key" => 2} = hd(ci["by_difficulty"])
      assert ci["outcomes"]["total"] == 1
      assert ci["outcomes"]["counts"]["unknown"] == 1
      assert ci["outcomes"]["unknown_share"] == 1.0
      assert [%{"run_id" => run_id, "class" => "unknown"}] = ci["runs"]
      assert run_id == fp.id
      assert ci["meta"]["undercount"] =~ "approved"
      assert ci["meta"]["classes"] == ~w(lint flake_rerun test_fix infra unknown)
      assert body["markdown"] =~ "## CI: first-push red rate"
    end

    # bd-6vullc: a flake recorded by two different fix_passes at the same test
    # file:line reaches the JSON summary as a recurring-flake group with a
    # count and the affected task ids, not just the markdown.
    test "the JSON summary carries recurring flakes", %{conn: conn} do
      ws = workspace!()
      {:ok, t1} = Ash.create(Issue, %{title: "t1", difficulty: 2, workspace_id: ws.id})
      {:ok, t2} = Ash.create(Issue, %{title: "t2", difficulty: 2, workspace_id: ws.id})

      for task <- [t1, t2] do
        {:ok, _} =
          Loop.Flakes.record(%{
            task_id: task.id,
            repo: "arbiter",
            ci_job: "mix test",
            signature: "DataCase teardown timeout",
            test_file: "test/coverage_test.exs",
            test_line: 150
          })
      end

      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h"})
      body = json_response(conn, 200)
      ci = body["summary"]["ci"]

      assert [flake] = ci["recurring_flakes"]
      assert flake["repo"] == "arbiter"
      assert flake["test_file"] == "test/coverage_test.exs"
      assert flake["test_line"] == 150
      assert flake["count"] == 2
      assert Enum.sort(flake["task_ids"]) == Enum.sort([t1.id, t2.id])
      assert ci["meta"]["flake_recurrence_threshold"]
      assert body["markdown"] =~ "### Recurring flakes"
    end
  end

  # bd-4f6opo: `?discover=true` is the opt-in model pass. The invoker is
  # swapped in app env (saved and restored — config/test.exs sets `:disabled`).
  describe "GET /api/loop/analyze?discover=true" do
    setup do
      prev = Application.get_env(:arbiter, :loop_discovery_invoker)
      test_pid = self()

      Application.put_env(:arbiter, :loop_discovery_invoker, fn prompt, _opts ->
        send(test_pid, {:invoked, prompt})

        {:ok,
         Jason.encode!(%{
           "candidates" => [
             %{
               "category" => "stale memoisation key",
               "regex" => "memo key",
               "matches" => [1, 2, 3],
               "rationale" => "cache keys omit a discriminator"
             }
           ]
         }), %{tokens_in: 10, tokens_out: 5, cost_usd: 0.01}}
      end)

      on_exit(fn -> Application.put_env(:arbiter, :loop_discovery_invoker, prev) end)

      for t <- ~w(bd-memo-1 bd-memo-2 bd-memo-3) do
        {:ok, _} =
          Ash.create(Round, %{
            task_id: t,
            run_id: Ecto.UUID.generate(),
            round: 1,
            role: :review,
            verdict: :request_changes,
            converged: false,
            findings: "1. The memo key omits the tenant id."
          })
      end

      :ok
    end

    test "without the opt-in: no model call and no discovery key", %{conn: conn} do
      body = conn |> get(~p"/api/loop/analyze", %{since: "24h"}) |> json_response(200)

      refute_received {:invoked, _}
      refute Map.has_key?(body["summary"], "discovery")
      refute body["markdown"] =~ "Candidate detectors"
    end

    test "with the opt-in: a verified candidate section, and nothing queued", %{conn: conn} do
      body =
        conn
        |> get(~p"/api/loop/analyze", %{since: "24h", discover: "true"})
        |> json_response(200)

      assert_received {:invoked, _prompt}
      assert body["markdown"] =~ "Candidate detectors"

      assert %{"status" => "ok", "candidates" => [cand], "rejected" => []} =
               body["summary"]["discovery"]

      assert cand["category"] == "stale memoisation key"
      assert cand["history_matches"] == 3
      assert length(cand["citations"]) == 3
      assert body["summary"]["discovery"]["cost"]["usage_event_id"]
      assert Ash.read!(PendingWrite) == []
    end

    test "rejects a malformed discover flag with 400", %{conn: conn} do
      conn = get(conn, ~p"/api/loop/analyze", %{since: "24h", discover: "maybe"})
      assert json_response(conn, 400)
      refute_received {:invoked, _}
    end
  end

  describe "POST /api/loop/propose" do
    test "queues the proposals the report implies and applies nothing", %{conn: conn} do
      {:ok, issue} =
        Ash.create(Issue, %{title: "ctrl inert", difficulty: 1, workspace_id: workspace!().id})

      run =
        run!(%{
          task_id: issue.id,
          state: :finished,
          outcome: :failed,
          model: "claude-haiku-4-5",
          failure_reason: ":review_gate_rejected"
        })

      {:ok, _} =
        Ash.create(Round, %{
          task_id: issue.id,
          run_id: run.id,
          round: 2,
          role: :review,
          verdict: :request_changes,
          converged: false,
          findings: "Green tests but the new path is never executed at runtime — inert."
        })

      conn = post(conn, ~p"/api/loop/propose", %{since: "24h"})
      body = json_response(conn, 200)

      assert is_list(body["proposals"])
      assert body["proposals"] != []
      assert Enum.all?(body["proposals"], &(&1["state"] in ["proposed", "hypothesis"]))

      # Nothing was applied: the task's difficulty is untouched.
      {:ok, reloaded} = Ash.get(Issue, issue.id)
      assert reloaded.difficulty == 1
    end

    # `arb loop analyze --propose --limit N` parses `limit` with OptionParser as
    # an integer and posts it in a JSON body, so it never arrives as the string
    # the query-string routes see.
    test "accepts an integer limit from the JSON body", %{conn: conn} do
      _ = run!(%{task_id: "bd-ctrl-limit", state: :finished, outcome: :succeeded})

      conn = post(conn, ~p"/api/loop/propose", %{since: "24h", limit: 50})
      body = json_response(conn, 200)

      assert is_binary(body["markdown"])
      assert is_list(body["proposals"])
    end

    test "rejects a non-positive or non-numeric limit with a 400", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/loop/propose", %{limit: 0}), 400)
      assert json_response(post(conn, ~p"/api/loop/propose", %{limit: "lots"}), 400)
      assert json_response(get(conn, ~p"/api/loop/analyze", %{limit: "-3"}), 400)
    end

    # A fleet-scope candidate (every reviewer-finding category, per
    # `Arbiter.Loop.Proposals`) with no `workspace_id` opt is attributed via
    # `Quota.default_workspace_id/0`, which refuses on an ambiguous install
    # (several workspaces, none named "default") rather than guessing
    # (bd-3dasqm). `record_all/2` counts such a refusal in `:dropped` instead
    # of losing it, and the controller surfaces that as `:proposals_dropped`
    # — this is the first test to exercise that path through the HTTP
    # surface end to end.
    test "an ambiguous install without --workspace surfaces a refused fleet candidate in proposals_dropped",
         %{conn: conn} do
      # No workspace named "default" among these two: ambiguous.
      _ws_a = workspace!()
      _ws_b = workspace!()

      {:ok, issue} =
        Ash.create(Issue, %{title: "ctrl inert 2", difficulty: 1, workspace_id: workspace!().id})

      run =
        run!(%{
          task_id: issue.id,
          state: :finished,
          outcome: :failed,
          model: "claude-haiku-4-5",
          failure_reason: ":review_gate_rejected"
        })

      {:ok, _} =
        Ash.create(Round, %{
          task_id: issue.id,
          run_id: run.id,
          round: 2,
          role: :review,
          verdict: :request_changes,
          converged: false,
          findings: "Green tests but the new path is never executed at runtime — inert."
        })

      conn = post(conn, ~p"/api/loop/propose", %{since: "24h"})
      body = json_response(conn, 200)

      assert is_list(body["proposals_dropped"])
      assert Enum.any?(body["proposals_dropped"], &(&1["reason"] =~ "ambiguous_workspace"))
    end
  end

  describe "POST /api/loop/propose/repo_doc_patch" do
    test "hand-authors a :repo_doc_patch proposal", %{conn: conn} do
      ws = workspace!()

      conn =
        post(conn, ~p"/api/loop/propose/repo_doc_patch", %{
          repo: "myrepo",
          lesson: "this repo's tests need FLAG=1 set",
          workspace_id: ws.id
        })

      body = json_response(conn, 200)

      assert body["pending"]["kind"] == "repo_doc_patch"
      assert body["pending"]["state"] == "proposed"
      assert body["pending"]["payload"]["lesson"] == "this repo's tests need FLAG=1 set"
    end

    test "422s when `repo` is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/loop/propose/repo_doc_patch", %{lesson: "some lesson"})
      assert json_response(conn, 422)
    end

    test "422s when `lesson` is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/loop/propose/repo_doc_patch", %{repo: "myrepo"})
      assert json_response(conn, 422)
    end
  end

  describe "routing canary endpoints" do
    test "POST /api/loop/propose/routing then GET /api/loop/canary", %{conn: conn} do
      ws = workspace!()

      body =
        conn
        |> post(~p"/api/loop/propose/routing", %{
          workspace_id: ws.id,
          difficulty: 3,
          model_tier: "standard",
          thinking: "high"
        })
        |> json_response(200)

      assert body["pending"]["kind"] == "config_set"
      assert body["pending"]["state"] == "proposed"

      status = conn |> get(~p"/api/loop/canary", %{workspace_id: ws.id}) |> json_response(200)
      assert status["running"] == false
      assert status["message"] =~ "no canary is running"
    end

    test "POST /api/loop/propose/routing 422s on a bad difficulty", %{conn: conn} do
      ws = workspace!()

      conn =
        post(conn, ~p"/api/loop/propose/routing", %{
          workspace_id: ws.id,
          difficulty: 12,
          model_tier: "standard"
        })

      assert json_response(conn, 422)
    end
  end

  describe "the pending queue" do
    setup do
      row = proposed_row()
      %{row: row}
    end

    test "GET /api/loop/pending lists live states with the evidence bar", %{
      conn: conn,
      row: row
    } do
      conn = get(conn, ~p"/api/loop/pending")
      body = json_response(conn, 200)

      summary = Enum.find(body["pending"], &(&1["id"] == row.id))
      assert summary
      assert body["evidence_bar"]["min_incidents"] == 3
      assert body["evidence_bar"]["min_distinct_tasks"] == 2
      # Amendment D: `arb loop pending` renders the recurring context price
      # straight off this summary shape, so it travels even when it is zero.
      assert summary["context_cost_tokens"] == row.context_cost_tokens
      # bd-bldypb: a difficulty override's payload is always complete.
      refute summary["needs_authoring"]
      # The summary shape stays compact — the diff is on the detail route.
      refute Map.has_key?(hd(body["pending"]), "diff")
    end

    test "GET /api/loop/pending marks a payload-less row as needing authoring (bd-bldypb)", %{
      conn: conn
    } do
      {:ok, gapped} =
        Loop.record(%{
          kind: :skill_patch,
          scope: :task,
          gist: "teach read discipline: context exhaustion",
          category: "missing test coverage",
          target: nil,
          incident_refs: ["run-a"],
          task_refs: ["bd-1"],
          payload: %{},
          workspace_id: workspace!().id
        })

      conn = get(conn, ~p"/api/loop/pending")
      body = json_response(conn, 200)

      summary = Enum.find(body["pending"], &(&1["id"] == gapped.id))
      assert summary["needs_authoring"]
    end

    test "GET /api/loop/pending rejects an unknown state rather than returning nothing", %{
      conn: conn
    } do
      conn = get(conn, ~p"/api/loop/pending", %{state: "propsed"})
      assert json_response(conn, 400)
    end

    test "GET /api/loop/pending/:id returns the full row including the diff", %{
      conn: conn,
      row: row
    } do
      conn = get(conn, ~p"/api/loop/pending/#{row.id}")
      body = json_response(conn, 200)

      assert body["pending"]["diff"] =~ "+difficulty: 3"
      assert body["pending"]["fingerprint"] == row.fingerprint
      assert body["pending"]["applicable"] == true
      refute body["pending"]["authoring_gap"]
    end

    test "GET /api/loop/pending/:id 404s on an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/loop/pending/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "POST .../apply applies through the domain API and marks the row applied", %{
      conn: conn,
      row: row
    } do
      conn = post(conn, ~p"/api/loop/pending/#{row.id}/apply", %{})
      body = json_response(conn, 200)

      assert body["applied"] == true
      assert body["pending"]["state"] == "applied"

      {:ok, issue} = Ash.get(Issue, row.target)
      assert issue.difficulty == 3
    end

    test "POST .../apply refuses a hypothesis, naming what it still needs", %{conn: conn} do
      # Fleet scope, one incident: below the bar, so it lands as a hypothesis.
      hyp =
        proposed_row(%{
          kind: :skill_patch,
          scope: :fleet,
          incident_refs: ["one"],
          task_refs: ["bd-solo"]
        })

      assert hyp.state == :hypothesis

      conn = post(conn, ~p"/api/loop/pending/#{hyp.id}/apply", %{})
      body = json_response(conn, 409)

      assert inspect(body) =~ "1 incident"
      {:ok, unchanged} = Loop.get_pending(hyp.id)
      assert unchanged.state == :hypothesis
    end

    # D-C-27: the apply carries the token's guardrail authority, so a
    # coordinator token cannot loosen a guardrail by way of a queued proposal.
    test "POST .../apply refuses a guardrail-loosening config_set for a coordinator token", %{
      conn: conn
    } do
      ws = workspace!()

      {:ok, row} =
        Loop.record(%{
          kind: :config_set,
          scope: :task,
          category: "cfg",
          target: "cfg-#{System.unique_integer([:positive])}",
          gist: "loosen the sandbox",
          workspace_id: ws.id,
          incident_refs: ["r"],
          task_refs: ["t"],
          payload: %{
            "workspace_id" => ws.id,
            "patch" => %{"agent" => %{"security" => %{"sandbox" => %{"enabled" => false}}}}
          },
          origin: "test"
        })

      conn = post(conn, ~p"/api/loop/pending/#{row.id}/apply", %{})
      body = json_response(conn, 422)
      assert inspect(body) =~ "operator-only"
      assert {:ok, %{state: :proposed}} = Loop.get_pending(row.id)
    end

    test "POST .../reject is soft and records the reason", %{conn: conn, row: row} do
      conn = post(conn, ~p"/api/loop/pending/#{row.id}/reject", %{reason: "handled by hand"})
      body = json_response(conn, 200)

      assert body["rejected"] == true
      assert body["pending"]["state"] == "rejected"
      assert body["pending"]["rejection_reason"] == "handled by hand"

      # Soft: the row is still there.
      assert {:ok, _} = Loop.get_pending(row.id)
    end
  end

  # A task-scoped difficulty bump: applicable immediately (blast radius 1), and
  # its apply path lands on a real Issue.
  defp proposed_row(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, issue} =
      Ash.create(Issue, %{title: "ctrl target #{n}", difficulty: 2, workspace_id: workspace!().id})

    base = %{
      kind: :difficulty_override,
      scope: :task,
      gist: "raise difficulty on #{issue.id}: D2 → D3",
      category: "difficulty misestimate (rework)",
      target: issue.id,
      difficulty: 2,
      repo: "arbiter",
      incident_refs: [issue.id],
      task_refs: [issue.id],
      # Every call to `workspace!/0` mints a fresh workspace, so by the time a
      # later test (or a `scope: :fleet` override below) runs, the install has
      # several workspaces and none named "default" — `resolve_workspace_id/3`
      # then refuses a :fleet candidate with no workspace as ambiguous
      # (`Arbiter.Loop.resolve_workspace_id/3`). Stamping the issue's own real
      # workspace here keeps every fixture deterministic regardless of scope.
      workspace_id: issue.workspace_id,
      payload: %{"task_id" => issue.id, "difficulty" => 3},
      diff: "--- a/task\n+++ b/task\n@@ Issue.difficulty @@\n-difficulty: 2\n+difficulty: 3\n"
    }

    {:ok, row} = Loop.record(Map.merge(base, attrs))
    row
  end
end
