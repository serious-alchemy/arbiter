defmodule Arbiter.Reviews.CheckoutPrivateCloneTest do
  @moduledoc """
  bd-7ays3v: `Checkout.provision_branch/3` with `layout: :private_clone` hands a
  container-backed reviewer a read-only private clone of the branch's origin
  head instead of a linked worktree.
  """
  # async: false — the fixture points the worktree root (Application env) at a
  # private directory.
  use ExUnit.Case, async: false

  alias Arbiter.Reviews.Checkout
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrivateClone

  import GitFixture, only: [git!: 2, commit!: 3]

  @branch "feature/under-review"

  setup do
    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    head = commit!(ctx.seed, %{"pr.txt" => "pr\n"}, "the PR head")
    git!(ctx.seed, ["push", "-q", "origin", "main:" <> @branch])
    Map.put(ctx, :head, head)
  end

  test "checks out the origin head in a read-only private clone", ctx do
    assert {:ok, %{path: path, head_sha: head}} =
             Checkout.provision_branch(ctx.checkout, @branch,
               prefix: "gate-review",
               layout: :private_clone,
               base: "main"
             )

    assert head == ctx.head
    assert Path.basename(path) =~ ~r/^gate-review-/
    assert Path.dirname(path) == ctx.worktree_root
    assert PrivateClone.clone?(path)
    assert PrivateClone.read_only?(path)
    assert git!(path, ["rev-parse", "HEAD"]) == ctx.head
    assert File.read!(Path.join(path, "pr.txt")) == "pr\n"
    assert git!(path, ["rev-parse", "refs/remotes/origin/main"])

    # The fetch's temporary ref is gone, and the implementer's branch is untouched.
    assert git!(ctx.checkout, ["for-each-ref", "refs/arbiter/review/"]) == ""
    refute git!(ctx.checkout, ["branch", "--list", @branch]) =~ @branch

    Checkout.teardown(path)
    refute File.exists?(path)
    assert git!(ctx.checkout, ["for-each-ref", "refs/arbiter/workers/"]) == ""
  end

  test "reviews origin's head, not a stale local copy of the branch", ctx do
    git!(ctx.checkout, ["fetch", "-q", "origin", @branch <> ":" <> @branch])
    newer = commit!(ctx.seed, %{"newer.txt" => "n\n"}, "pushed after")
    git!(ctx.seed, ["push", "-q", "origin", "main:" <> @branch])

    assert {:ok, %{path: path, head_sha: ^newer}} =
             Checkout.provision_branch(ctx.checkout, @branch, layout: :private_clone)

    Checkout.teardown(path)
  end

  test "a branch nobody can resolve is an error and leaves nothing behind", ctx do
    assert {:error, _} =
             Checkout.provision_branch(ctx.checkout, "feature/never-pushed",
               layout: :private_clone
             )

    assert File.ls!(ctx.worktree_root) == []
  end

  test "the default layout is still a linked worktree", ctx do
    assert {:ok, %{path: path}} = Checkout.provision_branch(ctx.checkout, @branch)
    refute PrivateClone.clone?(path)
    Checkout.teardown(path)
  end
end
