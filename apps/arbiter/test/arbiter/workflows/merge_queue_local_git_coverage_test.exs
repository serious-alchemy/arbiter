defmodule Arbiter.Workflows.MergeQueueLocalGitCoverageTest do
  @moduledoc """
  bd-wjpxok / #26 — the MergeQueue's mirror of the Watchdog's local-git
  fallback, driven through the real GitHub adapter (the Watchdog's tests use
  the stub merger and a GitLab-shaped 403): the compare endpoint refuses every
  request, and the queue's content check must still tell a pure rebase of the
  approved change (merge) from a head carrying an unreviewed commit (refuse),
  from local git in the task's checkout.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.GitFixture
  import ExUnit.CaptureLog

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueue

  defmodule FakeWorktree do
    @moduledoc false
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
    def rebase_onto_origin(_path, _branch), do: {:ok, :up_to_date}
  end

  defp approved_branch do
    fx = origin_and_clone(%{"lib/widget.ex" => "w1\n", "test/widget_test.exs" => "t1\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])
    reviewed = commit!(fx.origin, %{"lib/widget.ex" => "w1\nw2\n"}, "feature work")
    git!(fx.clone, ["fetch", "-q", "origin"])
    Map.put(fx, :reviewed, reviewed)
  end

  defp review_gate_fingerprint(repo, sha) do
    mb = git!(repo, ["merge-base", "origin/main", sha])
    NetDiff.fingerprint_local(repo, "#{mb}..#{sha}")
  end

  defp workspace(clone) do
    Ash.create!(Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "mql#{System.unique_integer([:positive])}",
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

  # An approved, clean PR at `head`, whose compare endpoint answers 403 to
  # every request — diffs and ancestry probes alike.
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
          send(test_pid, :compare_refused)

          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"message" => "Resource not accessible by personal access token"})

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

  defp enqueue_and_tick(fx, number, head) do
    ws = workspace(fx.clone)
    github_stub(number, head)

    {:ok, task} = Ash.create(Issue, %{title: "local git queue", workspace_id: ws.id})

    {:ok, task} =
      Ash.update(task, %{pr_ref: "##{number}", last_reviewed_sha: fx.reviewed}, action: :update)

    {:ok, _run} =
      Ash.create(Run, %{
        task_id: task.id,
        repo: "widget",
        workspace_id: ws.id,
        state: :finished,
        outcome: :succeeded,
        started_at: DateTime.utc_now()
      })

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
    %{items: [item]} = MergeQueue.state(name)

    {:ok, _} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: item.mr_ref,
        head_sha: fx.reviewed,
        base_ref: "main",
        net_diff_id: review_gate_fingerprint(fx.clone, fx.reviewed),
        kind: :reviewed,
        source: :review_gate
      })

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log = capture_log(fn -> for _ <- 1..2, do: :ok = MergeQueue.tick(name) end)
    %{task: task, name: name, item: item, log: log}
  end

  test "AC3/AC6: a pure rebase merges on the local content check when compare 403s" do
    fx = approved_branch()
    git!(fx.origin, ["checkout", "-q", "main"])
    commit!(fx.origin, %{"lib/other.ex" => "o1\n"}, "unrelated main work")
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.origin, ["rebase", "-q", "main"])
    head = git!(fx.origin, ["rev-parse", "HEAD"])

    %{task: task, item: item, log: log} = enqueue_and_tick(fx, 411, head)

    assert_received :compare_refused, "the forge was asked first"
    assert_received {:merged, ^head}
    assert Ash.get!(Issue, task.id).status == :closed
    assert log =~ "decided via local_git"

    assert Enum.any?(
             Coverage.for_mr(item.mr_ref),
             &(&1.kind == :mechanical and &1.head_sha == head)
           )
  end

  test "AC4/AC6: an unreviewed commit is refused when compare 403s" do
    fx = approved_branch()
    head = commit!(fx.origin, %{"test/widget_test.exs" => "t1\nt2\n"}, "test fix")

    %{task: task, name: name} = enqueue_and_tick(fx, 412, head)

    refute_received {:merged, _}
    assert Ash.get!(Issue, task.id).status == :open

    reviewed = fx.reviewed
    %{items: [after_item]} = MergeQueue.state(name)
    assert {:stale_reviewed_sha, ^reviewed, ^head} = after_item.last_error
  end
end
