defmodule Arbiter.Mergers.BranchSyncTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.BranchSync

  @moduletag :tmp_dir

  # A bare `origin`, a seed clone that moves `main`, and a ticket checkout of
  # `feature/x` (cloned from origin, as the ticket worktree tracks it).
  setup %{tmp_dir: dir} do
    origin = Path.join(dir, "origin.git")
    seed = Path.join(dir, "seed")
    wt = Path.join(dir, "wt")

    git!(dir, ["init", "--bare", "--initial-branch=main", origin])
    git!(dir, ["clone", origin, seed])
    configure(seed)
    File.write!(Path.join(seed, "a.txt"), "one\ntwo\nthree\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-m", "base"])
    git!(seed, ["push", "origin", "main"])

    git!(seed, ["checkout", "-b", "feature/x"])
    File.write!(Path.join(seed, "f.txt"), "feature\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-m", "feature work"])
    git!(seed, ["push", "origin", "feature/x"])
    git!(seed, ["checkout", "main"])

    git!(dir, ["clone", "--branch", "feature/x", origin, wt])
    configure(wt)

    %{origin: origin, seed: seed, wt: wt}
  end

  defp configure(path) do
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@example.invalid"])
    git!(path, ["config", "commit.gpgsign", "false"])
  end

  defp git!(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end

  defp advance_main(seed, file, content) do
    git!(seed, ["checkout", "main"])
    File.write!(Path.join(seed, file), content)
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-m", "main moves: #{file}"])
    git!(seed, ["push", "origin", "main"])
  end

  defp remote_head(origin, branch), do: git!(origin, ["rev-parse", "refs/heads/#{branch}"])

  describe "merge_in/3" do
    test "merges the target into the branch and pushes a plain fast-forward", ctx do
      reviewed = remote_head(ctx.origin, "feature/x")
      advance_main(ctx.seed, "b.txt", "main change\n")

      assert {:ok, :synced} = BranchSync.merge_in(ctx.wt, "feature/x", "main")

      new_head = remote_head(ctx.origin, "feature/x")
      refute new_head == reviewed

      # The reviewed head stays an ancestor: nothing was rewritten.
      assert {_, 0} =
               System.cmd("git", ["merge-base", "--is-ancestor", reviewed, new_head],
                 cd: ctx.origin
               )

      # …and the target tip is now contained in the branch.
      main_tip = remote_head(ctx.origin, "main")

      assert {_, 0} =
               System.cmd("git", ["merge-base", "--is-ancestor", main_tip, new_head],
                 cd: ctx.origin
               )

      # A merge commit: the old head is its first parent.
      assert git!(ctx.origin, ["rev-parse", new_head <> "^1"]) == reviewed
      assert git!(ctx.origin, ["rev-parse", new_head <> "^2"]) == main_tip
    end

    test "returns :up_to_date and pushes nothing when the branch already has the target", ctx do
      reviewed = remote_head(ctx.origin, "feature/x")

      assert {:ok, :up_to_date} = BranchSync.merge_in(ctx.wt, "feature/x", "main")
      assert remote_head(ctx.origin, "feature/x") == reviewed
    end

    test "a conflict aborts the merge, leaves origin untouched and reports the files", ctx do
      # Same file, same lines on both sides.
      git!(ctx.seed, ["checkout", "feature/x"])
      File.write!(Path.join(ctx.seed, "a.txt"), "one\nFEATURE\nthree\n")
      git!(ctx.seed, ["commit", "-am", "feature edits a.txt"])
      git!(ctx.seed, ["push", "origin", "feature/x"])
      advance_main(ctx.seed, "a.txt", "one\nMAIN\nthree\n")
      reviewed = remote_head(ctx.origin, "feature/x")

      assert {:error, {:conflict, ["a.txt"]}} =
               BranchSync.merge_in(ctx.wt, "feature/x", "main")

      assert remote_head(ctx.origin, "feature/x") == reviewed
      # The worktree is left clean, not mid-merge.
      assert git!(ctx.wt, ["status", "--porcelain"]) == ""
      refute File.exists?(Path.join([ctx.wt, ".git", "MERGE_HEAD"]))
    end

    test "fast-forwards a local branch that is behind origin before merging", ctx do
      # Someone (e.g. a fix pass elsewhere) pushed to the branch after the checkout was cut.
      git!(ctx.seed, ["checkout", "feature/x"])
      File.write!(Path.join(ctx.seed, "g.txt"), "more\n")
      git!(ctx.seed, ["add", "."])
      git!(ctx.seed, ["commit", "-m", "later feature work"])
      git!(ctx.seed, ["push", "origin", "feature/x"])
      reviewed = remote_head(ctx.origin, "feature/x")
      advance_main(ctx.seed, "b.txt", "main change\n")

      assert {:ok, :synced} = BranchSync.merge_in(ctx.wt, "feature/x", "main")

      assert {_, 0} =
               System.cmd(
                 "git",
                 ["merge-base", "--is-ancestor", reviewed, remote_head(ctx.origin, "feature/x")],
                 cd: ctx.origin
               )
    end

    test "refuses (never force-pushes) when the local branch diverged from origin", ctx do
      File.write!(Path.join(ctx.wt, "local.txt"), "local only\n")
      git!(ctx.wt, ["add", "."])
      git!(ctx.wt, ["commit", "-m", "local commit"])

      git!(ctx.seed, ["checkout", "feature/x"])
      File.write!(Path.join(ctx.seed, "g.txt"), "remote only\n")
      git!(ctx.seed, ["add", "."])
      git!(ctx.seed, ["commit", "-m", "remote commit"])
      git!(ctx.seed, ["push", "origin", "feature/x"])
      advance_main(ctx.seed, "b.txt", "main change\n")
      remote = remote_head(ctx.origin, "feature/x")

      assert {:error, {:diverged, _, ^remote}} =
               BranchSync.merge_in(ctx.wt, "feature/x", "main")

      assert remote_head(ctx.origin, "feature/x") == remote
    end

    test "refuses a worktree with uncommitted changes", ctx do
      advance_main(ctx.seed, "b.txt", "main change\n")
      File.write!(Path.join(ctx.wt, "f.txt"), "dirty\n")

      assert {:error, :dirty_worktree} = BranchSync.merge_in(ctx.wt, "feature/x", "main")
    end

    test "refuses when the checkout is on a different branch", ctx do
      git!(ctx.wt, ["checkout", "-b", "other"])

      assert {:error, {:wrong_branch, "other"}} =
               BranchSync.merge_in(ctx.wt, "feature/x", "main")
    end
  end

  describe "strategy/2" do
    defp ws(merge), do: %Arbiter.Tasks.Workspace{config: %{"merge" => merge}}

    test "defaults to merge" do
      assert BranchSync.strategy(ws(%{"strategy" => "gitlab"}), nil) == :merge
      assert BranchSync.strategy(nil, nil) == :merge
    end

    test "reads merge.sync_strategy, per repo too" do
      assert BranchSync.strategy(ws(%{"sync_strategy" => "rebase"}), nil) == :rebase
      assert BranchSync.strategy(ws(%{"sync_strategy" => "merge"}), nil) == :merge

      workspace = ws(%{"repos" => %{"api" => %{"sync_strategy" => "rebase"}}})
      assert BranchSync.strategy(workspace, "api") == :rebase
      assert BranchSync.strategy(workspace, "web") == :merge
    end

    test "an unknown value falls back to merge" do
      assert BranchSync.strategy(ws(%{"sync_strategy" => "squash"}), nil) == :merge
    end
  end
end
