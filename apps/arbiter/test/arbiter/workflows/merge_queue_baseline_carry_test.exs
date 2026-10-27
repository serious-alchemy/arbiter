defmodule Arbiter.Workflows.MergeQueueBaselineCarryTest do
  @moduledoc """
  bd-2oo8kf / #1062 — through the real GitHub adapter and a real checkout: an
  `accept_as_is` ruling (or a ReviewGate APPROVE latch) on head H survives the
  queue's sync to H' when H' is H plus the target's own delta, and the merge
  proceeds pinned to H'. Any extra content voids the baseline exactly as before.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.GitFixture

  alias Arbiter.ReviewGate.{Resolutions, Round, RoundsReport}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueue

  defmodule FakeWorktree do
    @moduledoc false
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
    def rebase_onto_origin(_path, _branch), do: {:ok, :up_to_date}
  end

  # `feature` holds the reviewed commit; main has since moved.
  defp fixture do
    fx = origin_and_clone(%{"lib/widget.ex" => "w1\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])
    reviewed = commit!(fx.origin, %{"lib/widget.ex" => "w1\nw2\n"}, "feature work")
    git!(fx.origin, ["checkout", "-q", "main"])
    commit!(fx.origin, %{"lib/other.ex" => "o1\n"}, "unrelated main work")
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.clone, ["fetch", "-q", "origin"])
    Map.put(fx, :reviewed, reviewed)
  end

  defp rebased!(fx) do
    git!(fx.origin, ["rebase", "-q", "main"])
    git!(fx.origin, ["rev-parse", "HEAD"])
  end

  defp merged_main!(fx) do
    git!(fx.origin, ["merge", "-q", "--no-ff", "--no-edit", "main"])
    git!(fx.origin, ["rev-parse", "HEAD"])
  end

  defp workspace(clone) do
    Ash.create!(Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "mqc#{System.unique_integer([:positive])}",
      config: %{
        "merge" => %{
          "strategy" => "github",
          "config" => %{
            "owner" => "octo",
            "repo" => "widget",
            "credentials_ref" => "test-token-abc123"
          }
        },
        "repo_paths" => %{"widget" => clone}
      }
    })
  end

  defp github_stub(number, head) do
    test_pid = self()

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and String.ends_with?(path, "/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

        conn.method == "PUT" and String.ends_with?(path, "/merge") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:merged, Jason.decode!(body)["sha"]})
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true, "sha" => "ok"})

        conn.method == "GET" and String.contains?(path, "/compare/") ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "no compare"})

        conn.method == "GET" and String.contains?(path, "/pulls/#{number}") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "number" => number,
            "state" => "open",
            "base" => %{"ref" => "main"},
            "head" => %{"sha" => head},
            "mergeable" => true,
            "mergeStateStatus" => "clean",
            "html_url" => "https://github.com/octo/widget/pull/#{number}"
          })

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)
  end

  # The task the reviewer rounds / resolutions hang off. `baseline` is `:ruling`
  # (a REQUEST_CHANGES round answered by accept_as_is on `fx.reviewed`) or
  # `:approval` (an APPROVE round with the latch on `fx.reviewed`).
  defp task_with_baseline(fx, ws, number, baseline) do
    {:ok, task} = Ash.create(Issue, %{title: "carried", workspace_id: ws.id})

    {:ok, task} =
      Ash.update(task, %{pr_ref: "##{number}", last_reviewed_sha: fx.reviewed}, action: :update)

    verdict = if baseline == :ruling, do: :request_changes, else: :approve

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: verdict,
        findings: if(verdict == :approve, do: "", else: "[high] a.ex:1 needs a guard"),
        finding_count: if(verdict == :approve, do: 0, else: 1)
      })

    if baseline == :ruling do
      {:ok, _} =
        Resolutions.record(
          %{
            task_id: task.id,
            decision: :accept_as_is,
            reasoning: "ship it",
            head_sha: fx.reviewed,
            actor: "coordinator"
          },
          resume: false
        )
    end

    {:ok, _run} =
      Ash.create(Run, %{
        task_id: task.id,
        repo: "widget",
        workspace_id: ws.id,
        state: :finished,
        outcome: :succeeded,
        started_at: DateTime.utc_now()
      })

    task
  end

  defp run_queue(fx, number, head, baseline) do
    ws = workspace(fx.clone)
    github_stub(number, head)
    task = task_with_baseline(fx, ws, number, baseline)

    name = :"merge_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: ws.id,
        base: "main",
        auto_tick: false,
        name: name,
        worktree_module: FakeWorktree
      )

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)

    :ok = MergeQueue.enqueue(name, task.id)
    for _ <- 1..3, do: :ok = MergeQueue.tick(name)
    %{task: task, name: name}
  end

  describe "an accept_as_is ruling" do
    test "survives a rebase sync with identical patch-ids and the merge proceeds" do
      fx = fixture()
      head = rebased!(fx)
      refute head == fx.reviewed

      %{task: task} = run_queue(fx, 501, head, :ruling)

      assert_received {:merged, ^head}
      assert Ash.get!(Issue, task.id).state == :closed

      report = RoundsReport.build(task.id)
      carried = List.last(report.resolutions)
      assert carried.head_sha == head
      assert carried.actor == "system:ruling-resume"
      assert [%{baseline: "ruling", from_sha: from, head_sha: ^head}] = report.carries
      assert from == fx.reviewed
    end

    test "survives a merge sync whose tree equals merge-tree(H, target)" do
      fx = fixture()
      head = merged_main!(fx)

      %{task: task} = run_queue(fx, 502, head, :ruling)

      assert_received {:merged, ^head}
      assert Ash.get!(Issue, task.id).state == :closed
      assert [%{baseline: "ruling"}] = RoundsReport.build(task.id).carries
    end

    test "an extra commit on top of the rebase voids it exactly as today" do
      fx = fixture()
      _rebased = rebased!(fx)
      head = commit!(fx.origin, %{"lib/evil.ex" => "x\n"}, "extra")

      %{task: task, name: name} = run_queue(fx, 503, head, :ruling)

      refute_received {:merged, _}
      assert Ash.get!(Issue, task.id).state in [:backlog, :queued]
      assert [%{last_error: {:review_not_approved, _}}] = MergeQueue.state(name).items
      assert RoundsReport.build(task.id).carries == []
    end

    test "a conflict-resolving merge voids it exactly as today" do
      fx = fixture()
      git!(fx.origin, ["checkout", "-q", "main"])
      commit!(fx.origin, %{"lib/widget.ex" => "w1\nmain-side\n"}, "main edits the same file")
      git!(fx.origin, ["checkout", "-q", "feature"])

      {_out, 1} = System.cmd("git", ["-C", fx.origin, "merge", "--no-ff", "--no-edit", "main"])
      File.write!(Path.join(fx.origin, "lib/widget.ex"), "w1\nresolved\n")
      git!(fx.origin, ["add", "lib/widget.ex"])
      git!(fx.origin, ["commit", "-q", "--no-edit"])
      head = git!(fx.origin, ["rev-parse", "HEAD"])

      %{task: task} = run_queue(fx, 504, head, :ruling)

      refute_received {:merged, _}
      assert RoundsReport.build(task.id).carries == []
    end
  end

  describe "a ReviewGate APPROVE baseline" do
    test "survives a rebase sync: the latch is re-stamped and the carry recorded" do
      fx = fixture()
      head = rebased!(fx)

      %{task: task} = run_queue(fx, 511, head, :approval)

      assert_received {:merged, ^head}
      assert Ash.get!(Issue, task.id).last_reviewed_sha == head
      assert [%{baseline: "approval", head_sha: ^head}] = RoundsReport.build(task.id).carries
    end

    test "an extra commit voids it: nothing merges and the latch stays put" do
      fx = fixture()
      _rebased = rebased!(fx)
      head = commit!(fx.origin, %{"lib/evil.ex" => "x\n"}, "extra")

      %{task: task} = run_queue(fx, 512, head, :approval)

      refute_received {:merged, _}
      assert Ash.get!(Issue, task.id).last_reviewed_sha == fx.reviewed
      assert RoundsReport.build(task.id).carries == []
    end
  end
end
