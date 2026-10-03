defmodule Arbiter.Worker.PrivateCloneReadsTest do
  @moduledoc """
  bd-4wy1w1 (P5), acceptance 3: what ReviewGate and the MergeQueue read from a
  worker's checkout, run against a private clone (git layout B) in the order
  they run it.

  Neither looks the worker's commits up in the main repo by branch name:
  ReviewGate runs every git command in the worker's checkout (or in a review
  checkout cut from it), and the MergeQueue rebases and pushes there too, both
  talking to `origin`. So a clone answers them itself, provided `origin` is
  the forge, `origin/<base>` and the local `<base>` mean what they mean in a
  linked worktree, and what they push lands on the forge, never in the main
  repo. The readers that do look in the main repo (the Direct merger, the
  conflict resolver's divergence check, a dispatched reviewer's never-pushed
  fallback) are tested where they live: `completion_merge_test.exs`,
  `merge_queue_conflict_test.exs`, `dispatch_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Checkout
  alias Arbiter.Reviews.PushState
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Worktree

  import GitFixture, only: [git!: 2, commit!: 3]

  @branch "feature/bd-p5-reads"

  setup do
    fx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = Worktree.create(fx.checkout, @branch, "main", layout: :private_clone)
    git!(clone, ["config", "commit.gpgsign", "false"])
    head = commit!(clone, %{"lib/work.ex" => "work\n"}, "worker: the work")
    Map.merge(fx, %{clone: clone, head: head})
  end

  defp on_forge(forge, branch) do
    case System.cmd("git", [
           "-C",
           forge,
           "rev-parse",
           "--verify",
           "--quiet",
           "refs/heads/" <> branch
         ]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp in_main?(checkout, branch),
    do:
      match?(
        {_, 0},
        System.cmd("git", [
          "-C",
          checkout,
          "rev-parse",
          "--verify",
          "--quiet",
          "refs/heads/" <> branch
        ])
      )

  test "ReviewGate: pre-review sync, target merge, merge-base, push gate, CI head, review checkout",
       ctx do
    # Pre-review `sync_from_origin/2`: the branch is not on the forge yet, so
    # it fails open and leaves the branch alone, as in a linked worktree.
    assert {:error, _} = Worktree.sync_from_origin(ctx.clone, @branch)
    assert git!(ctx.clone, ["rev-parse", "HEAD"]) == ctx.head

    # Upstream moves on; `update_from_target/2` brings the forge's tip in.
    upstream = commit!(ctx.seed, %{"lib/upstream.ex" => "upstream\n"}, "upstream moved")
    git!(ctx.seed, ["push", "-q", "origin", "main"])
    assert {:ok, :merged} = Worktree.update_from_target(ctx.clone, "main")
    merged_head = git!(ctx.clone, ["rev-parse", "HEAD"])

    # The reviewer's diff base is the fork point against the CURRENT target,
    # so the upstream commit is not mistaken for the branch's own work.
    base = Worktree.merge_base(ctx.clone, "main")
    assert base == upstream
    diff_files = git!(ctx.clone, ["diff", "--name-only", "#{base}..HEAD"])
    assert diff_files == "lib/work.ex"

    # The push gate pushes to the forge (the clone's `origin`), not into the
    # main repo.
    assert {:ok, :pushed, _state} = PushState.ensure_pushed(ctx.clone, @branch)
    assert on_forge(ctx.forge, @branch) == merged_head
    refute in_main?(ctx.checkout, @branch)

    # The CI gate's head is read live from the forge.
    assert Worktree.remote_head(ctx.clone, @branch) == merged_head
    assert {:ok, ^merged_head} = PushState.reviewable_head(ctx.clone, @branch)

    # The review checkout is cut from the clone at the head the forge carries,
    # and registered in the clone, never in the main repo.
    assert {:ok, %{path: review, head_sha: ^merged_head}} =
             Checkout.provision_branch(ctx.clone, @branch, prefix: "gate-review")

    refute git!(ctx.checkout, ["worktree", "list", "--porcelain"]) =~ review
    assert git!(ctx.clone, ["worktree", "list", "--porcelain"]) =~ review

    # The reviewer's diff, and the verdict path's blank-diff and fingerprint
    # reads, see exactly the branch's own change.
    assert {:ok, false} = NetDiff.local_diff_blank?(review, "#{base}..HEAD")

    assert NetDiff.fingerprint_local(review, "#{base}..HEAD") ==
             NetDiff.fingerprint_local(ctx.clone, "#{base}..HEAD")

    assert :ok = Checkout.teardown(review)
    refute File.exists?(review)
    refute git!(ctx.clone, ["worktree", "list", "--porcelain"]) =~ review
  end

  test "MergeQueue: reconcile and push reach the forge; LocalCompare in main reads the head by sha",
       ctx do
    git!(ctx.clone, ["push", "-q", "origin", @branch])

    # A ReviewGate implementer round pushed a fix straight to the forge branch
    # while the clone committed more: genuinely diverged.
    git!(ctx.seed, ["fetch", "-q", "origin", @branch])
    git!(ctx.seed, ["checkout", "-q", "-b", @branch, "FETCH_HEAD"])
    fix = commit!(ctx.seed, %{"lib/fix.ex" => "fix\n"}, "review fix round")
    git!(ctx.seed, ["push", "-q", "origin", @branch])
    commit!(ctx.clone, %{"lib/more.ex" => "more\n"}, "worker: more")

    # `push_for_hosted_pr/3`'s reconcile-before-push, then its push.
    assert {:ok, :rebased} = Worktree.rebase_onto_origin(ctx.clone, @branch)
    assert {:ok, _} = Worktree.push(ctx.clone, set_upstream: true)
    pushed = git!(ctx.clone, ["rev-parse", "HEAD"])
    assert on_forge(ctx.forge, @branch) == pushed

    # The merge guard's local-git fallback works in the main repo by sha,
    # fetching what it lacks from the forge.
    assert {:ok, true} = LocalCompare.ancestor?(ctx.checkout, fix, pushed)
    assert {:ok, [diff]} = LocalCompare.net_diffs(ctx.checkout, "main", [pushed])
    assert diff =~ "lib/fix.ex"
    assert diff =~ "lib/more.ex"
    assert diff =~ "lib/work.ex"

    # And sync-back hands the main repo the same branch the forge has.
    assert :ok = Worktree.sync_back(ctx.clone)
    assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == pushed
    assert PrivateClone.clone?(ctx.clone)
  end
end
