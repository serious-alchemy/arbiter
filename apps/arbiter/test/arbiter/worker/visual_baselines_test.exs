defmodule Arbiter.Worker.VisualBaselinesTest do
  use ExUnit.Case, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.VisualBaselines

  @moduletag :tmp_dir

  defmodule FakeForge do
    @moduledoc false
    # Reads what to answer from the :visual_fake_forge app env, so the
    # adapter's calls are observable from the test.
    def ci_job_artifacts(mr_ref, job, opts) do
      send(Application.get_env(:arbiter, :visual_fake_forge_pid), {:artifacts, mr_ref, job, opts})
      Application.get_env(:arbiter, :visual_fake_forge_artifacts)
    end

    def last_green_job_sha(mr_ref, job, _opts) do
      send(Application.get_env(:arbiter, :visual_fake_forge_pid), {:green, mr_ref, job})
      Application.get_env(:arbiter, :visual_fake_forge_green)
    end
  end

  defmodule NoArtifactsForge do
    @moduledoc false
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit(dir, files, message) do
    for {rel, content} <- files do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    git(dir, ["add", "-A"])
    git(dir, ["commit", "-q", "-m", message])
    git(dir, ["rev-parse", "HEAD"])
  end

  defp zip(files) do
    {:ok, {_, bin}} =
      :zip.create(
        ~c"a.zip",
        Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end),
        [:memory]
      )

    bin
  end

  setup %{tmp_dir: tmp} do
    origin = Path.join(tmp, "origin.git")
    repo = Path.join(tmp, "tonic")
    wt_root = Path.join(tmp, "wt")
    File.mkdir_p!(wt_root)

    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", origin])
    {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)
    git(repo, ["config", "user.email", "t@example.com"])
    git(repo, ["config", "user.name", "T"])
    git(repo, ["config", "commit.gpgsign", "false"])
    git(repo, ["checkout", "-q", "-b", "main"])

    commit(
      repo,
      [
        {"app/page.html", "<p>one</p>\n<p>two</p>\n<p>three</p>\n"},
        {"app/own.html", "own\n"},
        {"e2e/page-chromium-linux.png", "page-0"},
        {"e2e/settings-chromium-linux.png", "settings-0"},
        {"e2e/untouched-chromium-linux.png", "untouched-0"}
      ],
      "base"
    )

    git(repo, ["push", "-q", "origin", "main"])
    git(repo, ["checkout", "-q", "-b", "feature/x"])
    green = commit(repo, [{"app/own.html", "own, edited\n"}], "the branch's own change")
    git(repo, ["checkout", "-q", "main"])
    commit(repo, [{"app/page.html", "<p>one</p>\n<p>two</p>\n<p>3</p>\n"}], "main moved the page")
    git(repo, ["push", "-q", "origin", "main"])
    git(repo, ["checkout", "-q", "feature/x"])
    git(repo, ["merge", "-q", "--no-edit", "main"])
    head = git(repo, ["rev-parse", "HEAD"])
    git(repo, ["push", "-q", "origin", "feature/x"])
    git(repo, ["checkout", "-q", "main"])

    previous = Application.get_env(:arbiter, :worktree_root)
    Application.put_env(:arbiter, :worktree_root, wt_root)
    Application.put_env(:arbiter, :visual_fake_forge_pid, self())

    Application.put_env(
      :arbiter,
      :visual_fake_forge_artifacts,
      {:ok,
       %{
         sha: head,
         failed_jobs: ["visual"],
         archive:
           zip([
             {"test-results/a/page-actual.png", "page-1"},
             {"test-results/b/settings-actual.png", "settings-1"}
           ])
       }}
    )

    Application.put_env(:arbiter, :visual_fake_forge_green, {:ok, green})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbiter, :worktree_root, previous),
        else: Application.delete_env(:arbiter, :worktree_root)

      for k <- [:visual_fake_forge_pid, :visual_fake_forge_artifacts, :visual_fake_forge_green],
          do: Application.delete_env(:arbiter, k)
    end)

    workspace = %Workspace{
      id: Ecto.UUID.generate(),
      config: %{
        "repo_paths" => %{"tonic" => repo},
        "worker" => %{
          "repos" => %{
            "tonic" => %{
              "visual_baselines" => %{
                "job" => "visual",
                "artifact_path" => "test-results",
                "baseline_dir" => "e2e",
                "baseline_suffix" => "-chromium-linux.png",
                "ignore_paths" => ["docs/**"]
              }
            }
          }
        }
      }
    }

    ctx = %{
      workspace: workspace,
      repo: "tonic",
      adapter: FakeForge,
      mr_ref: "!7",
      result: %{head_sha: head, head_ref: "feature/x", base_ref: "main"}
    }

    %{ctx: ctx, origin: origin, repo: repo, head: head, green: green}
  end

  defp remote_branch_files(origin, from, to) do
    git(origin, ["diff", "--name-only", from, to]) |> String.split("\n", trim: true)
  end

  test "refreshes only the failing snapshots and pushes one commit, with no agent",
       %{ctx: ctx, origin: origin, head: head} do
    assert {:refreshed, %{sha: sha, files: files}} = VisualBaselines.refresh(ctx)

    assert Enum.sort(files) == [
             "e2e/page-chromium-linux.png",
             "e2e/settings-chromium-linux.png"
           ]

    assert_received {:artifacts, "!7", "visual", _opts}

    # the branch on origin now has exactly that one commit on top of the head,
    # touching exactly those files
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == sha
    assert git(origin, ["rev-parse", sha <> "^"]) == head
    assert remote_branch_files(origin, head, sha) == Enum.sort(files)
    assert git(origin, ["log", "-1", "--format=%s", sha]) == VisualBaselines.commit_subject()
    assert git(origin, ["show", sha <> ":e2e/page-chromium-linux.png"]) == "page-1"
    assert git(origin, ["show", sha <> ":e2e/settings-chromium-linux.png"]) == "settings-1"
    # an untouched snapshot keeps its baseline
    assert git(origin, ["show", sha <> ":e2e/untouched-chromium-linux.png"]) == "untouched-0"
  end

  test "leaves no checkout behind", %{ctx: ctx, tmp_dir: tmp} do
    assert {:refreshed, _} = VisualBaselines.refresh(ctx)
    assert File.ls!(Path.join(tmp, "wt")) == []
  end

  test "no config for the repo: nothing is called", %{ctx: ctx} do
    assert {:skip, :not_configured} = VisualBaselines.refresh(%{ctx | repo: "other"})
    refute_received {:artifacts, _, _, _}
  end

  test "an adapter without the artifact callbacks is skipped", %{ctx: ctx} do
    assert {:skip, :adapter_unsupported} =
             VisualBaselines.refresh(%{ctx | adapter: NoArtifactsForge})
  end

  test "another job failing as well: the normal fix path", %{ctx: ctx, origin: origin, head: head} do
    {:ok, art} = Application.get_env(:arbiter, :visual_fake_forge_artifacts)

    Application.put_env(
      :arbiter,
      :visual_fake_forge_artifacts,
      {:ok, %{art | failed_jobs: ["visual", "unit"]}}
    )

    assert {:skip, {:other_jobs_failed, ["unit"]}} = VisualBaselines.refresh(ctx)
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == head
  end

  test "artifacts from a pipeline of another commit are not used", %{
    ctx: ctx,
    origin: origin,
    head: head
  } do
    {:ok, art} = Application.get_env(:arbiter, :visual_fake_forge_artifacts)
    Application.put_env(:arbiter, :visual_fake_forge_artifacts, {:ok, %{art | sha: "deadbeef"}})

    assert {:skip, :artifacts_for_another_head} = VisualBaselines.refresh(ctx)
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == head
  end

  test "own commits since the green run that touch rendering files: no refresh, no push",
       %{ctx: ctx, origin: origin, repo: repo} do
    git(repo, ["checkout", "-q", "feature/x"])
    head = commit(repo, [{"app/own.html", "own, edited again\n"}], "own change after green")
    git(repo, ["push", "-q", "origin", "feature/x"])
    git(repo, ["checkout", "-q", "main"])

    {:ok, art} = Application.get_env(:arbiter, :visual_fake_forge_artifacts)
    Application.put_env(:arbiter, :visual_fake_forge_artifacts, {:ok, %{art | sha: head}})
    ctx = %{ctx | result: %{ctx.result | head_sha: head}}

    assert {:skip, {:own_changes, ["app/own.html"]}} = VisualBaselines.refresh(ctx)
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == head
  end

  test "no green run on record: the heuristic cannot decide, so no refresh",
       %{ctx: ctx, origin: origin, head: head} do
    Application.put_env(:arbiter, :visual_fake_forge_green, {:ok, nil})

    assert {:skip, :no_green_run} = VisualBaselines.refresh(ctx)
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == head
  end

  test "a forge error reading the green run is a skip, not a refresh",
       %{ctx: ctx, origin: origin, head: head} do
    Application.put_env(:arbiter, :visual_fake_forge_green, {:error, :boom})

    assert {:skip, {:green_run_unreadable, :boom}} = VisualBaselines.refresh(ctx)
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == head
  end

  test "a snapshot with no existing baseline is a new snapshot: no refresh",
       %{ctx: ctx, origin: origin, head: head} do
    {:ok, art} = Application.get_env(:arbiter, :visual_fake_forge_artifacts)

    Application.put_env(
      :arbiter,
      :visual_fake_forge_artifacts,
      {:ok, %{art | archive: zip([{"test-results/a/brand-new-actual.png", "x"}])}}
    )

    assert {:skip, {:no_baseline, "brand-new"}} = VisualBaselines.refresh(ctx)
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == head
  end

  test "the branch moved on origin since the pipeline ran: no refresh", %{ctx: ctx, repo: repo} do
    git(repo, ["checkout", "-q", "feature/x"])
    commit(repo, [{"docs/n.md", "n\n"}], "someone pushed")
    git(repo, ["push", "-q", "origin", "feature/x"])
    git(repo, ["checkout", "-q", "main"])

    assert {:skip, :branch_moved} = VisualBaselines.refresh(ctx)
  end

  test "a head that is already an auto-refresh commit is not refreshed again",
       %{ctx: ctx, origin: origin, head: head} do
    assert {:refreshed, %{sha: sha}} = VisualBaselines.refresh(ctx)

    {:ok, art} = Application.get_env(:arbiter, :visual_fake_forge_artifacts)

    Application.put_env(
      :arbiter,
      :visual_fake_forge_artifacts,
      {:ok, %{art | sha: sha, archive: zip([{"test-results/a/page-actual.png", "page-2"}])}}
    )

    ctx = %{ctx | result: %{ctx.result | head_sha: sha}}
    assert {:skip, :already_refreshed} = VisualBaselines.refresh(ctx)
    assert git(origin, ["rev-parse", "refs/heads/feature/x"]) == sha
    refute sha == head
  end
end
