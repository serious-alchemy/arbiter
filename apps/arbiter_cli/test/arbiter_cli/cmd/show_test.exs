defmodule ArbiterCli.Cmd.ShowTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Show

  test "prints human-readable detail" do
    stub_get("/api/issues/gte-006", %{
      "id" => "gte-006",
      "title" => "CLI escript",
      "state" => "queued",
      "priority" => 2,
      "description" => "Build it"
    })

    {out, _err, exit_code} = capture(fn -> Show.run(["gte-006"]) end)
    assert exit_code == 0
    assert out =~ "gte-006"
    assert out =~ "CLI escript"
    assert out =~ "Description:"
    assert out =~ "Build it"
  end

  test "--json emits raw JSON" do
    stub_get("/api/issues/x", %{"id" => "x", "title" => "T"})
    {out, _err, exit_code} = capture(fn -> Show.run(["x", "--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"id" => "x"}} = Jason.decode(String.trim(out))
  end

  test "missing id argument exits non-zero" do
    {_out, err, exit_code} = capture(fn -> Show.run([]) end)
    assert exit_code == 1
    assert err =~ "requires a ticket id"
  end

  test "404 surfaces server message and exits with code 4" do
    stub_get(
      "/api/issues/missing",
      %{"error" => %{"type" => "not_found", "message" => "resource not found", "details" => %{}}},
      404
    )

    {_out, err, exit_code} = capture(fn -> Show.run(["missing"]) end)
    assert exit_code == 4
    assert err =~ "resource not found"
  end

  # ES4 (bd-4sw689): the server's `effective_priority`, `priority_via` and
  # `priority_lift` ride through `--json` untouched; the text view names a lift.
  describe "effective priority (ES4)" do
    defp line(out, label) do
      out |> String.split("\n") |> Enum.find(&String.starts_with?(&1, label <> ":"))
    end

    @lifted %{
      "id" => "bd-9",
      "title" => "lifted",
      "state" => "queued",
      "priority" => 3,
      "effective_priority" => 1,
      "priority_via" => "bd-epic",
      "priority_lift" => "applied"
    }

    test "--json carries the three fields" do
      stub_get("/api/issues/bd-9", @lifted)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Issue.run(["show", "bd-9", "--json"]) end)

      assert %{
               "priority" => 3,
               "effective_priority" => 1,
               "priority_via" => "bd-epic",
               "priority_lift" => "applied"
             } = Jason.decode!(String.trim(out))
    end

    test "text: an applied lift prints 'Scheduled as'; a capped one says so" do
      stub_get("/api/issues/bd-9", @lifted)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Issue.run(["show", "bd-9"]) end)
      assert line(out, "Priority") =~ "3"
      assert line(out, "Scheduled as") =~ "P1 via bd-epic"

      stub_get(
        "/api/issues/bd-9",
        Map.merge(@lifted, %{"effective_priority" => 3, "priority_lift" => "capped"})
      )

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Issue.run(["show", "bd-9"]) end)
      assert line(out, "Scheduled as") =~ "P3"
      assert line(out, "Scheduled as") =~ "lift via bd-epic waiting"
    end

    test "text: no lift prints no 'Scheduled as' line" do
      stub_get("/api/issues/bd-8", %{
        "id" => "bd-8",
        "title" => "plain",
        "priority" => 2,
        "effective_priority" => 2,
        "priority_via" => nil,
        "priority_lift" => nil
      })

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Issue.run(["show", "bd-8"]) end)
      refute line(out, "Scheduled as")
    end
  end

  # bd-6fkgvo AC2: the text view speaks the lifecycle vocabulary.
  describe "lifecycle lines" do
    defp show(issue) do
      stub_get("/api/issues/#{issue["id"]}", issue)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Issue.run(["show", issue["id"]]) end)
      out
    end

    test "a merging ticket: state and column, step, attention, PR and merge status, current run" do
      out =
        show(%{
          "id" => "bd-1",
          "title" => "merging one",
          "state" => "merging",
          "column" => "merging",
          "step" => "merge_blocked",
          "attention" => %{
            "owner" => "operator",
            "cause" => "merge_blocked",
            "waiting_on" => "approval",
            "reason" => "the PR needs an approval the fleet cannot give",
            "note" => "ping the reviewer"
          },
          "pr_ref" => "#42",
          "merger_url" => "https://forge.test/pull/42",
          "merger_status" => %{
            "status" => "open",
            "pipeline" => "success",
            "approved" => false,
            "block_reason" => "review_required"
          },
          "current_run" => %{
            "kind" => "implement",
            "state" => "finished",
            "outcome" => "succeeded",
            "phase" => nil
          }
        })

      assert line(out, "State") =~ "merging (Merging)"
      assert line(out, "Step") =~ "merge_blocked"
      assert line(out, "Attention") =~ "operator"
      assert line(out, "Attention") =~ "the PR needs an approval the fleet cannot give"
      assert line(out, "Attention") =~ "ping the reviewer"
      assert line(out, "PR") =~ "#42"
      assert line(out, "PR") =~ "https://forge.test/pull/42"
      assert line(out, "Merge status") =~ "state=open"
      assert line(out, "Merge status") =~ "pipeline=success"
      assert line(out, "Merge status") =~ "block=review_required"
      assert line(out, "Current run") =~ "implement finished (succeeded)"
      refute line(out, "Backlog")
      refute line(out, "Status")
      refute line(out, "Close reason")
    end

    test "a closed ticket prints its close reason and no Backlog/Ready line" do
      out =
        show(%{
          "id" => "bd-2",
          "title" => "closed one",
          "state" => "closed",
          "column" => "closed",
          "close_reason" => "duplicate",
          "attention" => nil,
          "current_run" => nil
        })

      assert line(out, "State") =~ "closed (Closed)"
      assert line(out, "Close reason") =~ "duplicate"
      refute line(out, "Backlog")
      refute line(out, "Step")
      refute line(out, "Attention")
      refute line(out, "Current run")
    end

    test "a queued ticket keeps its Ready line and names its blockers" do
      out =
        show(%{
          "id" => "bd-3",
          "title" => "blocked one",
          "state" => "queued",
          "column" => "blocked",
          "blocked_by" => ["bd-8", "bd-9"]
        })

      assert line(out, "State") =~ "queued (Blocked)"
      assert line(out, "Backlog") =~ "Ready"
      assert line(out, "Blocked by") =~ "bd-8, bd-9"
    end

    test "an in-progress ticket shows its step and the live run" do
      out =
        show(%{
          "id" => "bd-4",
          "title" => "working",
          "state" => "active",
          "column" => "in_progress",
          "step" => "in_review",
          "current_run" => %{
            "kind" => "review",
            "state" => "working",
            "outcome" => nil,
            "phase" => "reviewing",
            "run_task_id" => "bd-4#review",
            "task_id" => "bd-4"
          }
        })

      assert line(out, "State") =~ "active (In progress)"
      assert line(out, "Step") =~ "in_review"
      assert line(out, "Current run") =~ "review working"
      refute line(out, "Backlog")
    end

    test "a backlog ticket prints its Backlog line and no legacy Status line" do
      out =
        show(%{"id" => "bd-5", "title" => "new", "state" => "backlog", "column" => "backlog"})

      assert line(out, "State") =~ "backlog (Backlog)"
      assert line(out, "Backlog") =~ "Backlog"
      refute line(out, "Status")
    end
  end
end
