defmodule ArbiterCli.Cmd.ShowTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Show

  test "prints human-readable detail" do
    stub_get("/api/issues/gte-006", %{
      "id" => "gte-006",
      "title" => "CLI escript",
      "status" => "open",
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

  # bd-6fkgvo AC2: the text view speaks the lifecycle vocabulary.
  describe "lifecycle lines" do
    defp show(issue) do
      stub_get("/api/issues/#{issue["id"]}", issue)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Issue.run(["show", issue["id"]]) end)
      out
    end

    defp line(out, label) do
      out |> String.split("\n") |> Enum.find(&String.starts_with?(&1, label <> ":"))
    end

    test "a merging ticket: state and column, step, attention, PR and merge status, current run" do
      out =
        show(%{
          "id" => "bd-1",
          "title" => "merging one",
          "status" => "in_progress",
          "state" => "merging",
          "column" => "merging",
          "step" => "merge_blocked",
          "refined" => true,
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
          "status" => "closed",
          "state" => "closed",
          "column" => "closed",
          "close_reason" => "duplicate",
          "refined" => true,
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
          "status" => "open",
          "state" => "queued",
          "column" => "blocked",
          "blocked_by" => ["bd-8", "bd-9"],
          "refined" => true
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
          "status" => "in_progress",
          "state" => "active",
          "column" => "in_progress",
          "step" => "in_review",
          "refined" => true,
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

    test "an older server's payload (no state) still prints its status" do
      out = show(%{"id" => "bd-5", "title" => "old", "status" => "open", "refined" => false})
      assert line(out, "Status") =~ "open"
      assert line(out, "Backlog") =~ "Backlog"
    end
  end
end
