defmodule Arbiter.Worker.WorktreePrivateCloneTest do
  @moduledoc """
  bd-4wy1w1 (P5): the `Worktree` API over a git-layout-B private clone. Every
  caller that provisions, attaches, cleans up or reaps a worker checkout goes
  through `Worktree`, so a clone has to behave there the way a linked worktree
  does, or say why it cannot.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Worktree

  import GitFixture, only: [git!: 2, commit!: 3]

  @branch "feature/bd-p5-wt"

  setup do
    GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
  end

  defp commit_in(path, file, message) do
    File.write!(Path.join(path, file), message <> "\n")
    git!(path, ["add", file])
    git!(path, ["commit", "-q", "-m", message])
    git!(path, ["rev-parse", "HEAD"])
  end

  defp pins(repo, path) do
    git!(repo, [
      "for-each-ref",
      "--format=%(refname)",
      PrivateClone.pin_prefix(Path.basename(path))
    ])
  end

  describe "create/4" do
    test "layout: :private_clone provisions a private clone at the usual leaf", ctx do
      assert {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      assert path == Worktree.worktree_path(@branch)
      assert PrivateClone.clone?(path)
      assert {:ok, @branch} = Worktree.current_branch(path)
    end

    # A workspace switched to podman mid-task: the leaf holds the linked
    # worktree an earlier run left. Its branch and commits live in the main
    # repo, so a clean one becomes a clone of the same branch.
    test "replaces a clean linked worktree on the branch with a clone of it", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main")
      head = commit_in(path, "w.txt", "work")

      assert {:ok, ^path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)

      assert PrivateClone.clone?(path)
      assert git!(path, ["rev-parse", "HEAD"]) == head
      refute git!(ctx.checkout, ["worktree", "list", "--porcelain"]) =~ path
    end

    test "never replaces a linked worktree holding uncommitted work", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main")
      File.write!(Path.join(path, "dirty.txt"), "unsaved\n")

      assert {:error, {:layout_mismatch, ^path}} =
               Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)

      assert File.read!(Path.join(path, "dirty.txt")) == "unsaved\n"
      refute PrivateClone.clone?(path)
    end

    # bd-d0sgb6: the reverse flip. A ticket first worked under podman and
    # redispatched under bwrap finds a clone at the leaf.
    test "replaces a clean private clone on the branch with a linked worktree", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      head = commit_in(path, "w.txt", "work")

      assert {:ok, ^path} =
               Worktree.create(ctx.checkout, @branch, "main", layout: :linked_worktree)

      refute PrivateClone.clone?(path)
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(path, ".git"))
      assert git!(path, ["rev-parse", "HEAD"]) == head
      assert git!(ctx.checkout, ["worktree", "list", "--porcelain"]) =~ path
    end

    test "never replaces a private clone holding uncommitted work", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      File.write!(Path.join(path, "dirty.txt"), "unsaved\n")

      assert {:error, {:layout_mismatch, ^path}} =
               Worktree.create(ctx.checkout, @branch, "main", layout: :linked_worktree)

      assert File.read!(Path.join(path, "dirty.txt")) == "unsaved\n"
      assert PrivateClone.clone?(path)
    end

    test "attach/3 swaps a clean linked worktree for a clone, and back", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main")
      head = commit_in(path, "w.txt", "work")

      assert {:ok, ^path} =
               Worktree.attach(ctx.checkout, @branch, layout: :private_clone, base: "main")

      assert PrivateClone.clone?(path)
      assert git!(path, ["rev-parse", "HEAD"]) == head

      assert {:ok, ^path} = Worktree.attach(ctx.checkout, @branch, layout: :linked_worktree)
      refute PrivateClone.clone?(path)
      assert git!(path, ["rev-parse", "HEAD"]) == head
    end

    test "attach/3 refuses a mismatched layout holding uncommitted work", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main")
      File.write!(Path.join(path, "dirty.txt"), "unsaved\n")

      assert {:error, {:layout_mismatch, ^path}} =
               Worktree.attach(ctx.checkout, @branch, layout: :private_clone, base: "main")

      assert File.exists?(Path.join(path, "dirty.txt"))
    end

    test "the default layout is still a linked worktree", ctx do
      assert {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", [])
      refute PrivateClone.clone?(path)
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(path, ".git"))
    end
  end

  describe "attach/3 with layout: :private_clone" do
    test "attaches to the branch the main repo already has", ctx do
      git!(ctx.checkout, ["branch", @branch])
      git!(ctx.checkout, ["checkout", "-q", @branch])
      tip = commit!(ctx.checkout, %{"pr.txt" => "pr\n"}, "pr work")
      git!(ctx.checkout, ["checkout", "-q", "main"])

      assert {:ok, path} =
               Worktree.attach(ctx.checkout, @branch, layout: :private_clone, base: "main")

      assert PrivateClone.clone?(path)
      assert git!(path, ["rev-parse", "HEAD"]) == tip

      assert git!(path, ["rev-parse", "refs/remotes/origin/main"]) ==
               git!(ctx.checkout, ["rev-parse", "refs/remotes/origin/main"])
    end

    test "falls back to origin/<branch>, as `git worktree add <path> <branch>` does", ctx do
      git!(ctx.seed, ["checkout", "-q", "-b", @branch])
      tip = commit!(ctx.seed, %{"pr.txt" => "pushed elsewhere\n"}, "pr from elsewhere")
      git!(ctx.seed, ["push", "-q", "origin", @branch])
      git!(ctx.checkout, ["fetch", "-q", "origin"])

      assert {:ok, path} = Worktree.attach(ctx.checkout, @branch, layout: :private_clone)
      assert git!(path, ["rev-parse", "HEAD"]) == tip
      assert {:ok, @branch} = Worktree.current_branch(path)
    end

    test "never cuts a new branch for a name the main repo does not know", ctx do
      assert {:error, _} = Worktree.attach(ctx.checkout, @branch, layout: :private_clone)
      refute File.exists?(Worktree.worktree_path(@branch))
    end

    test "reuses a clone already on the branch", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      head = commit_in(path, "w.txt", "work")

      assert {:ok, ^path} = Worktree.attach(ctx.checkout, @branch, layout: :private_clone)
      assert git!(path, ["rev-parse", "HEAD"]) == head
    end
  end

  describe "cleanup/1 on a private clone" do
    test "syncs the branch back, removes the clone and its pins", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      head = commit_in(path, "w.txt", "work")

      assert :ok = Worktree.cleanup(path)
      refute File.exists?(path)
      assert pins(ctx.checkout, path) == ""
      assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == head
    end
  end

  # `AuthDeath.reclaim_debris/3`'s sequence on a worker that died before it
  # committed: the dirty and ahead-of-`origin/<target>` probes, `cleanup/1`,
  # then `delete_branch/3` in the main repo. Its tests drive a real Claude
  # spawn, which a podman workspace cannot do until the wrap point lands (P7).
  describe "auth-death debris on a private clone" do
    test "a clone that never committed leaves no checkout and no branch behind", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)

      assert {:ok, false} = Worktree.has_uncommitted?(path)
      assert {:ok, false} = Worktree.has_commits_ahead?(path, "origin/main")
      assert :ok = Worktree.cleanup(path)
      assert :ok = Worktree.delete_branch(ctx.checkout, @branch, "origin/main")

      refute File.exists?(path)
      assert git!(ctx.checkout, ["branch", "--list", @branch]) == ""
      assert pins(ctx.checkout, path) == ""
    end

    test "a clone with a commit reads as ahead, so it is kept", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      commit_in(path, "w.txt", "work")

      assert {:ok, true} = Worktree.has_commits_ahead?(path, "origin/main")
    end
  end

  # A resumed worker's briefing (`ResumeContext`) and the commit gate name the
  # bare `<target>`, which a linked worktree resolves through the main repo's
  # refs; a clone carries its own copy of the base it was cut from.
  test "the resume briefing lists exactly the worker's commits", ctx do
    {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
    commit_in(path, "w.txt", "the worker's commit")

    briefing = Arbiter.Worker.ResumeContext.work_so_far(path, "main")

    assert briefing =~ "the worker's commit"
    refute briefing =~ "could not read git log"
    refute briefing =~ "init"
    assert {:ok, :ready} = Worktree.completion_state(path, "main")
  end

  describe "repo_path/1" do
    test "names the main repo for a private clone, as for a linked worktree", ctx do
      {:ok, clone} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      {:ok, linked} = Worktree.create(ctx.checkout, "feature/linked", "main")

      assert Worktree.repo_path(clone) == ctx.checkout
      assert Worktree.repo_path(linked) == Worktree.repo_path(ctx.checkout)
    end
  end

  describe "sync_back/1 and sync_branch/2" do
    test "sync_back/1 is a no-op :ok for a linked worktree", ctx do
      {:ok, linked} = Worktree.create(ctx.checkout, "feature/linked", "main")
      assert :ok = Worktree.sync_back(linked)
    end

    test "sync_back/1 carries a clone's branch into the main repo", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      head = commit_in(path, "w.txt", "work")

      assert :ok = Worktree.sync_back(path)
      assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == head
    end

    test "sync_branch/2 refreshes the main repo's copy of a branch from its clone", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      head = commit_in(path, "w.txt", "work")

      assert :ok = Worktree.sync_branch(ctx.checkout, @branch)
      assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == head
    end

    test "sync_branch/2 leaves a branch with no clone (or a linked worktree) alone", ctx do
      assert :ok = Worktree.sync_branch(ctx.checkout, "feature/nothing-here")
      {:ok, _} = Worktree.create(ctx.checkout, "feature/linked", "main")
      assert :ok = Worktree.sync_branch(ctx.checkout, "feature/linked")
    end
  end

  describe "reset_if_merged/4 on a private clone" do
    # bd-8ssxap's empty-PR redispatch, in layout B: the branch merged upstream,
    # so a redispatch must start from the new upstream tip. The clone's own
    # `origin/<base>` is whatever it was at creation; only the main repo's
    # fetch knows the branch landed.
    test "resets a branch upstream already merged, using the main repo's fresh fetch", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      tip = commit_in(path, "w.txt", "work")
      git!(path, ["push", "-q", "origin", @branch])

      # Upstream merges it (fast-forward) and moves on.
      git!(ctx.seed, ["fetch", "-q", "origin", @branch])
      git!(ctx.seed, ["merge", "-q", "--ff-only", "FETCH_HEAD"])
      upstream = commit!(ctx.seed, %{"later.txt" => "later\n"}, "later upstream work")
      git!(ctx.seed, ["push", "-q", "origin", "main"])
      assert git!(ctx.seed, ["merge-base", "--is-ancestor", tip, "main"]) == ""

      assert {:ok, :reset} = Worktree.reset_if_merged(ctx.checkout, @branch, "main")
      assert git!(path, ["rev-parse", "HEAD"]) == upstream
    end

    test "keeps a clone whose branch has unmerged work", ctx do
      {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      tip = commit_in(path, "w.txt", "work")

      assert {:ok, :kept} = Worktree.reset_if_merged(ctx.checkout, @branch, "main")
      assert git!(path, ["rev-parse", "HEAD"]) == tip
    end
  end

  describe "list/1" do
    test "counts the repo's private clones alongside its linked worktrees", ctx do
      {:ok, clone} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
      {:ok, linked} = Worktree.create(ctx.checkout, "feature/linked", "main")

      listed = Worktree.list(ctx.checkout)
      assert %{path: clone, branch: @branch} in listed

      assert Enum.any?(
               listed,
               &(&1.branch == "feature/linked" and &1.path =~ Path.basename(linked))
             )
    end
  end
end
