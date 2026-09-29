defmodule Arbiter.Mergers.LocalCompareTest do
  @moduledoc """
  bd-wjpxok / #26 — the adapter-independent local-git answer to the questions
  the merge guard otherwise asks the forge's compare API: the three-dot net
  diff, ancestry, and (for the escalation) the unreviewed delta itself.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.GitFixture

  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Tasks.Workspace

  # The vs-4v8cf0 shape: `reviewed` is the approved commit on `feature`, and a
  # CI fix pass then added one test-only commit on top of it (`head`). The
  # clone has fetched `reviewed` (the ReviewGate's worktree shares its object
  # store) but has never seen `head`, which was pushed from elsewhere.
  defp approved_then_fix_pass do
    fx = origin_and_clone(%{"lib/a.ex" => "a1\n", "test/a_test.exs" => "t1\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])
    reviewed = commit!(fx.origin, %{"lib/a.ex" => "a1\na2\n"}, "feature work")
    git!(fx.clone, ["fetch", "-q", "origin"])
    head = commit!(fx.origin, %{"test/a_test.exs" => "t1\nt2\n"}, "test fix")

    Map.merge(fx, %{reviewed: reviewed, head: head})
  end

  # What `Arbiter.Worker.ReviewGate` stamps on its `:reviewed` coverage row:
  # `fingerprint_local(worktree, "<merge_base>..HEAD")`.
  defp review_gate_fingerprint(repo, sha) do
    mb = git!(repo, ["merge-base", "origin/main", sha])
    NetDiff.fingerprint_local(repo, "#{mb}..#{sha}")
  end

  # `main` moves on (an unrelated file), and `feature` is rebased onto it.
  defp rebase_feature!(origin) do
    git!(origin, ["checkout", "-q", "main"])
    commit!(origin, %{"lib/b.ex" => "b1\n"}, "unrelated main work")
    git!(origin, ["checkout", "-q", "feature"])
    git!(origin, ["rebase", "-q", "main"])
    git!(origin, ["rev-parse", "HEAD"])
  end

  describe "net_diffs/3" do
    test "fetches what the clone is missing and fingerprints like the ReviewGate" do
      fx = approved_then_fix_pass()
      review_fp = review_gate_fingerprint(fx.clone, fx.reviewed)

      assert {:ok, [reviewed_diff, head_diff]} =
               LocalCompare.net_diffs(fx.clone, "main", [fx.reviewed, fx.head])

      assert NetDiff.fingerprint(reviewed_diff) == review_fp,
             "the local net diff must fingerprint exactly as the reviewed coverage row does"

      refute NetDiff.fingerprint(head_diff) == review_fp,
             "a new commit that changes the net diff must not fingerprint as reviewed"

      assert head_diff =~ "test/a_test.exs"
    end

    test "a pure rebase onto a moved base has the reviewed net diff" do
      fx = approved_then_fix_pass()
      git!(fx.origin, ["reset", "-q", "--hard", fx.reviewed])
      rebased = rebase_feature!(fx.origin)
      refute rebased == fx.reviewed

      assert {:ok, [diff]} = LocalCompare.net_diffs(fx.clone, "main", [rebased])
      assert NetDiff.fingerprint(diff) == review_gate_fingerprint(fx.clone, fx.reviewed)
    end

    test "errors (never raises) when the repo cannot answer" do
      assert {:error, :no_repo_path} = LocalCompare.net_diffs(nil, "main", ["abc"])

      fx = approved_then_fix_pass()
      missing = String.duplicate("0", 40)
      assert {:error, _} = LocalCompare.net_diffs(fx.clone, "main", [missing])
      assert {:error, _} = LocalCompare.net_diffs(fx.clone, "no-such-base", [fx.reviewed])

      not_a_repo = Path.join(fx.root, "plain")
      File.mkdir_p!(not_a_repo)
      assert {:error, _} = LocalCompare.net_diffs(not_a_repo, "main", [fx.reviewed])
    end
  end

  describe "ancestor?/3" do
    test "answers from local git, fetching the descendant first" do
      fx = approved_then_fix_pass()

      assert {:ok, true} = LocalCompare.ancestor?(fx.clone, fx.reviewed, fx.head)
      assert {:ok, false} = LocalCompare.ancestor?(fx.clone, fx.head, fx.reviewed)
    end

    test "an unknown commit is an error, not a no" do
      fx = approved_then_fix_pass()
      missing = String.duplicate("0", 40)

      assert {:error, _} = LocalCompare.ancestor?(fx.clone, missing, fx.reviewed)
      assert {:error, :no_repo_path} = LocalCompare.ancestor?(nil, fx.reviewed, fx.head)
    end
  end

  describe "delta/4" do
    test "names the unreviewed commits and files — the vs-4v8cf0 shape" do
      fx = approved_then_fix_pass()

      assert {:ok, %{commits: [commit], files: ["test/a_test.exs"]}} =
               LocalCompare.delta(fx.clone, "main", fx.reviewed, fx.head)

      assert commit =~ String.slice(fx.head, 0, 7)
      assert commit =~ "test fix"
    end

    test "a pure rebase has no unreviewed delta" do
      fx = approved_then_fix_pass()
      git!(fx.origin, ["reset", "-q", "--hard", fx.reviewed])
      rebased = rebase_feature!(fx.origin)

      assert {:ok, %{commits: [], files: []}} =
               LocalCompare.delta(fx.clone, "main", fx.reviewed, rebased)
    end

    test "a rebase that also adds a commit names only the added one" do
      fx = approved_then_fix_pass()
      git!(fx.origin, ["reset", "-q", "--hard", fx.reviewed])
      rebase_feature!(fx.origin)
      extra = commit!(fx.origin, %{"lib/c.ex" => "c1\n"}, "sneaky extra")

      assert {:ok, %{commits: [commit], files: ["lib/c.ex"]}} =
               LocalCompare.delta(fx.clone, "main", fx.reviewed, extra)

      assert commit =~ "sneaky extra"
    end
  end

  describe "diffs/4 — API first, local git on failure" do
    test "the API's answer is used when it has one" do
      api = fn "main", head -> {:ok, "diff for #{head}"} end

      assert {:ok, ["diff for a", "diff for b"], :api} =
               LocalCompare.diffs(api, nil, "main", ["a", "b"])
    end

    test "any API failure falls back to local git for every head" do
      fx = approved_then_fix_pass()
      # One side answers, the other 403s: the pair must still come from ONE
      # source, or a forge-rendered diff is compared with a git-rendered one.
      api = fn
        _base, head when head == fx.reviewed -> {:ok, "forge diff"}
        _base, _head -> {:error, %{status: 403, message: "insufficient_granular_scope"}}
      end

      assert {:ok, [reviewed_diff, head_diff], :local_git} =
               LocalCompare.diffs(api, fx.clone, "main", [fx.reviewed, fx.head])

      assert NetDiff.fingerprint(reviewed_diff) ==
               review_gate_fingerprint(fx.clone, fx.reviewed)

      assert head_diff =~ "test/a_test.exs"
    end

    test "a raising API is a failure like any other" do
      fx = approved_then_fix_pass()
      api = fn _base, _head -> raise "boom" end

      assert {:ok, [_diff], :local_git} = LocalCompare.diffs(api, fx.clone, "main", [fx.head])
    end

    test "both failing reports both reasons" do
      api = fn _base, _head -> {:error, :timeout} end

      assert {:error, %{api: :timeout, local_git: :no_repo_path}} =
               LocalCompare.diffs(api, nil, "main", ["a"])
    end
  end

  describe "ancestry/4 — API first, local git on failure" do
    test "the API's boolean is used when it has one" do
      assert {:ok, false, :api} = LocalCompare.ancestry(fn _, _ -> {:ok, false} end, nil, "a", "b")
    end

    test "an API failure is answered by local git" do
      fx = approved_then_fix_pass()
      api = fn _, _ -> {:error, :forbidden} end

      assert {:ok, true, :local_git} = LocalCompare.ancestry(api, fx.clone, fx.reviewed, fx.head)
      assert {:ok, false, :local_git} = LocalCompare.ancestry(api, fx.clone, fx.head, fx.reviewed)
    end

    test "both failing reports both reasons" do
      assert {:error, %{api: :forbidden, local_git: :no_repo_path}} =
               LocalCompare.ancestry(fn _, _ -> {:error, :forbidden} end, nil, "a", "b")
    end
  end

  describe "repo_path/2" do
    test "resolves the repo through the workspace's repo_paths" do
      ws = %Workspace{config: %{"repo_paths" => %{"vstim" => %{"path" => "/srv/vstim"}}}}

      assert LocalCompare.repo_path(ws, "vstim") == "/srv/vstim"
      assert LocalCompare.repo_path(ws, "other") == nil
      assert LocalCompare.repo_path(ws, nil) == nil
      assert LocalCompare.repo_path(nil, nil) == nil
    end
  end
end
