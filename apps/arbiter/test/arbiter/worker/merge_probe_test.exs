defmodule Arbiter.Worker.MergeProbeTest do
  @moduledoc """
  bd-4y9dno — the in-memory conflict probe a waiting merge-train MR gets when its
  target moves: `git merge-tree` of the MR's head against the target's fresh tip,
  in the repo's object store. No commit, no ref, no worktree, no push.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.MergeProbe

  import GitFixture, only: [git!: 2, commit!: 3]

  @branch "feature/bd-probe"

  setup do
    fx = GitFixture.forge_and_checkout(%{"lib/a.ex" => "a1\na2\na3\n", "lib/b.ex" => "b\n"})

    # The MR branch, pushed to the forge from the seed clone.
    git!(fx.seed, ["checkout", "-q", "-b", @branch])
    head = commit!(fx.seed, %{"lib/a.ex" => "a1\nMR\na3\n"}, "mr: edit a2")
    git!(fx.seed, ["push", "-q", "origin", @branch])
    git!(fx.seed, ["checkout", "-q", "main"])

    Map.put(fx, :head, head)
  end

  defp args(fx, overrides \\ %{}) do
    Map.merge(
      %{repo_path: fx.checkout, branch: @branch, head_sha: fx.head, target: "main"},
      overrides
    )
  end

  defp snapshot(fx) do
    %{
      refs: git!(fx.checkout, ["for-each-ref"]),
      status: git!(fx.checkout, ["status", "--porcelain"]),
      forge: git!(fx.forge, ["for-each-ref"]),
      head: git!(fx.checkout, ["rev-parse", "HEAD"])
    }
  end

  test "a target that moved without touching the MR's lines is clean", fx do
    commit!(fx.seed, %{"lib/b.ex" => "b2\n"}, "main: edit b")
    git!(fx.seed, ["push", "-q", "origin", "main"])

    assert %{verdict: :clean, target_tip: tip} = MergeProbe.check(args(fx))
    assert tip == git!(fx.forge, ["rev-parse", "main"])
  end

  test "a target that moved onto the MR's lines is a conflict naming the files", fx do
    tip = commit!(fx.seed, %{"lib/a.ex" => "a1\nMAIN\na3\n"}, "main: edit a2")
    git!(fx.seed, ["push", "-q", "origin", "main"])

    assert %{verdict: {:conflict, ["lib/a.ex"]}, target_tip: ^tip} = MergeProbe.check(args(fx))
  end

  test "it commits, pushes and moves nothing", fx do
    commit!(fx.seed, %{"lib/a.ex" => "a1\nMAIN\na3\n"}, "main: edit a2")
    git!(fx.seed, ["push", "-q", "origin", "main"])
    # fetch once so the probe's own fetch is the only thing that could differ
    _ = MergeProbe.check(args(fx))
    before = snapshot(fx)

    assert %{verdict: {:conflict, _}} = MergeProbe.check(args(fx))
    assert snapshot(fx) == before
  end

  test "a head the repo cannot see, or no repo at all, is unknown (fail open)", fx do
    assert %{verdict: :unknown} = MergeProbe.check(args(fx, %{branch: "no/such-branch"}))
    assert %{verdict: :unknown} = MergeProbe.check(args(fx, %{repo_path: nil}))
    assert %{verdict: :unknown} = MergeProbe.check(args(fx, %{repo_path: "/nonexistent/repo"}))
  end

  test "the probe judges the forge's head of the branch, not a stale sha", fx do
    # head_sha is only a label for the caller; the branch tip is what is merged.
    assert %{verdict: :clean} = MergeProbe.check(args(fx, %{head_sha: "0000"}))
  end

  test "a target and branch that have not moved since the last answer are :unchanged", fx do
    commit!(fx.seed, %{"lib/a.ex" => "a1\nMAIN\na3\n"}, "main: edit a2")
    git!(fx.seed, ["push", "-q", "origin", "main"])

    assert %{verdict: {:conflict, _}, target_tip: tip, head: head} = MergeProbe.check(args(fx))
    since = %{head: head, target_tip: tip}
    assert %{verdict: :unchanged} = MergeProbe.check(args(fx, %{since: since}))

    # the target moves: judged again
    commit!(fx.seed, %{"lib/b.ex" => "b3\n"}, "main: edit b")
    git!(fx.seed, ["push", "-q", "origin", "main"])
    assert %{verdict: {:conflict, _}} = MergeProbe.check(args(fx, %{since: since}))
  end
end
