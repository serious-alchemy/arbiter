defmodule Arbiter.Workflows.MergeQueueReviewAuthorizationTest do
  @moduledoc """
  bd-651ine / #529 — the MergeQueue refuses a ticket whose latest reviewer round
  did not approve, unless an `accept_as_is` / `amend` resolution authorises it.

  The incident (bd-311cun / PR #527): REQUEST_CHANGES, a fix commit, a park, a
  `send_back` resolution, a resume — and the PR merged with no reviewer round on
  the new head. The ticket had no `last_reviewed_sha` (nothing was ever
  approved), so the reviewed-SHA guard had no baseline and merged unguarded.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.MergeQueue

  defmodule FakeWorktree do
    @moduledoc false
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
    def rebase_onto_origin(_path, _branch), do: {:ok, :up_to_date}
  end

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123"
      }
    }
  }

  @head "5ff594325aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "ra#{System.unique_integer([:positive])}",
        config: @ws_github
      })

    test_pid = self()

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and String.ends_with?(path, "/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

        conn.method == "PUT" and String.ends_with?(path, "/merge") ->
          send(test_pid, :merged)
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true, "sha" => "ok"})

        conn.method == "GET" and String.contains?(path, "/compare/") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"status" => "diverged"})

        conn.method == "GET" and String.contains?(path, "/pulls/") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "number" => 527,
            "state" => "open",
            "head" => %{"sha" => @head},
            "base" => %{"ref" => "main"},
            "mergeable" => true,
            "mergeStateStatus" => "clean",
            "html_url" => "https://github.com/octo/widget/pull/527"
          })

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)

    %{workspace: workspace}
  end

  defp start_queue(workspace) do
    name = :"merge_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        name: name,
        worktree_module: FakeWorktree
      )

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    name
  end

  defp rejected_task(workspace) do
    {:ok, task} = Ash.create(Issue, %{title: "rc task", workspace_id: workspace.id})
    {:ok, task} = Ash.update(task, %{pr_ref: "#527"}, action: :update)

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: :request_changes,
        findings: "[high] x.ex:1 needs a guard",
        finding_count: 1
      })

    task
  end

  defp tick_until_decided(name, task) do
    capture_log(fn ->
      :ok = MergeQueue.enqueue(name, task.id)
      for _ <- 1..3, do: :ok = MergeQueue.tick(name)
    end)
  end

  test "a send_back resolution does not let a REQUEST_CHANGES ticket merge", %{workspace: ws} do
    task = rejected_task(ws)

    {:ok, _} =
      Resolutions.record(%{
        task_id: task.id,
        decision: "send_back",
        reasoning: "fix the findings and report done so the gate re-reviews"
      })

    name = start_queue(ws)
    tick_until_decided(name, task)

    refute_received :merged
    assert Ash.get!(Issue, task.id).state != :closed

    assert %{items: [%{last_error: {:review_not_approved, %{verdict: :request_changes}}}]} =
             MergeQueue.state(name)
  end

  test "the refusal is raised once per head, not once per tick", %{workspace: ws} do
    task = rejected_task(ws)

    {:ok, _} =
      Resolutions.record(%{task_id: task.id, decision: "send_back", reasoning: "try again"})

    name = start_queue(ws)

    log =
      capture_log(fn ->
        :ok = MergeQueue.enqueue(name, task.id)
        for _ <- 1..5, do: :ok = MergeQueue.tick(name)
      end)

    assert length(String.split(log, "MergeQueue: refusing merge for task=")) == 2
    assert %{items: [%{review_refused_head: @head}]} = MergeQueue.state(name)
    refute_received :merged
  end

  test "an unanswered REQUEST_CHANGES ticket does not merge", %{workspace: ws} do
    task = rejected_task(ws)
    name = start_queue(ws)
    tick_until_decided(name, task)

    refute_received :merged
    assert Ash.get!(Issue, task.id).state != :closed
  end

  for decision <- ["accept_as_is", "amend"] do
    test "an #{decision} resolution authorises the merge", %{workspace: ws} do
      task = rejected_task(ws)

      {:ok, _} =
        Resolutions.record(%{
          task_id: task.id,
          decision: unquote(decision),
          reasoning: "coordinator reviewed #{@head} by hand"
        })

      name = start_queue(ws)
      tick_until_decided(name, task)

      assert_received :merged
      assert Ash.get!(Issue, task.id).state == :closed
    end
  end

  test "an accept_as_is recorded against another head does not authorise this one",
       %{workspace: ws} do
    task = rejected_task(ws)

    {:ok, _} =
      Resolutions.record(%{
        task_id: task.id,
        decision: "accept_as_is",
        reasoning: "fine at the old head",
        head_sha: "0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld0ld"
      })

    name = start_queue(ws)
    tick_until_decided(name, task)

    refute_received :merged
  end

  test "a later reviewer APPROVE lets a send_back ticket merge", %{workspace: ws} do
    task = rejected_task(ws)

    {:ok, _} =
      Resolutions.record(%{task_id: task.id, decision: "send_back", reasoning: "try again"})

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        fix_round_attempt: 1,
        role: :review,
        verdict: :approve,
        finding_count: 0
      })

    name = start_queue(ws)
    tick_until_decided(name, task)

    assert_received :merged
  end
end
