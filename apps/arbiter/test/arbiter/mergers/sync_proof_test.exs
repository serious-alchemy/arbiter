defmodule Arbiter.Mergers.SyncProofTest do
  @moduledoc """
  bd-2oo8kf / #1062 — the proof that a moved head is the reviewed head synced
  with the target and nothing else. It widens what a ruling or an approval
  covers, so every test here that expects `:ok` has a sibling that adds one
  hunk and expects the proof to refuse.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.GitFixture

  alias Arbiter.Mergers.SyncProof

  # origin has `main` and a `feature` branch with two reviewed commits; the
  # clone has fetched `feature`.
  defp feature_fixture do
    fx = origin_and_clone(%{"lib/a.ex" => "a1\n", "lib/c.ex" => "c1\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])
    commit!(fx.origin, %{"lib/a.ex" => "a1\na2\n"}, "feature one")
    reviewed = commit!(fx.origin, %{"lib/new.ex" => "n1\n"}, "feature two")
    git!(fx.origin, ["checkout", "-q", "main"])
    Map.put(fx, :reviewed, reviewed)
  end

  defp advance_main!(fx, files \\ %{"lib/b.ex" => "b1\n"}) do
    git!(fx.origin, ["checkout", "-q", "main"])
    commit!(fx.origin, files, "main moves")
  end

  defp rebase!(fx) do
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.origin, ["rebase", "-q", "main"])
    sha = git!(fx.origin, ["rev-parse", "HEAD"])
    git!(fx.origin, ["checkout", "-q", "main"])
    sha
  end

  defp merge_main!(fx, opts \\ []) do
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.origin, ["merge", "-q", "--no-ff", "--no-edit", "main"] ++ opts)
    sha = git!(fx.origin, ["rev-parse", "HEAD"])
    git!(fx.origin, ["checkout", "-q", "main"])
    sha
  end

  describe "a rebase" do
    test "with identical patch-ids is proven" do
      fx = feature_fixture()
      advance_main!(fx)
      rebased = rebase!(fx)
      refute rebased == fx.reviewed

      assert {:ok, :rebase, proof} = SyncProof.verify(fx.clone, "main", fx.reviewed, rebased)
      assert proof =~ "patch-id"
    end

    test "a rebase over a target change touching the same file is still proven" do
      fx = feature_fixture()
      advance_main!(fx, %{"lib/a.ex" => "a0\na1\n"})
      rebased = rebase!(fx)

      assert {:ok, :rebase, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, rebased)
    end

    test "an extra commit on top voids it" do
      fx = feature_fixture()
      advance_main!(fx)
      rebased = rebase!(fx)
      git!(fx.origin, ["checkout", "-q", "feature"])
      extra = commit!(fx.origin, %{"lib/evil.ex" => "x\n"}, "extra")

      assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, extra)
      assert {:ok, :rebase, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, rebased)
    end

    test "an amended commit (one changed hunk) voids it" do
      fx = feature_fixture()
      advance_main!(fx)
      git!(fx.origin, ["checkout", "-q", "feature"])
      git!(fx.origin, ["rebase", "-q", "main"])
      File.write!(Path.join(fx.origin, "lib/new.ex"), "n1\nsneaky\n")
      git!(fx.origin, ["commit", "-q", "-a", "--amend", "--no-edit"])
      amended = git!(fx.origin, ["rev-parse", "HEAD"])

      assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, amended)
    end

    test "a squash (same net diff, different commits) voids it" do
      fx = feature_fixture()
      advance_main!(fx)
      git!(fx.origin, ["checkout", "-q", "feature"])
      git!(fx.origin, ["rebase", "-q", "main"])
      git!(fx.origin, ["reset", "-q", "--soft", "main"])
      git!(fx.origin, ["commit", "-q", "-m", "squashed"])
      squashed = git!(fx.origin, ["rev-parse", "HEAD"])

      assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, squashed)
    end
  end

  describe "a merge of the target" do
    test "whose tree equals merge-tree(head, target) is proven" do
      fx = feature_fixture()
      advance_main!(fx)
      merged = merge_main!(fx)

      assert {:ok, :merge, proof} = SyncProof.verify(fx.clone, "main", fx.reviewed, merged)
      assert proof =~ "merge-tree"
    end

    test "two stacked target merges are proven" do
      fx = feature_fixture()
      advance_main!(fx)
      _first = merge_main!(fx)
      advance_main!(fx, %{"lib/d.ex" => "d1\n"})
      second = merge_main!(fx)

      assert {:ok, :merge, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, second)
    end

    test "with a hand-edited merge commit (an evil merge) is voided" do
      fx = feature_fixture()
      advance_main!(fx)
      git!(fx.origin, ["checkout", "-q", "feature"])
      git!(fx.origin, ["merge", "-q", "--no-ff", "--no-commit", "main"])
      File.write!(Path.join(fx.origin, "lib/evil.ex"), "smuggled\n")
      git!(fx.origin, ["add", "lib/evil.ex"])
      git!(fx.origin, ["commit", "-q", "-m", "merge main (with a rider)"])
      evil = git!(fx.origin, ["rev-parse", "HEAD"])
      git!(fx.origin, ["checkout", "-q", "main"])

      assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, evil)
    end

    test "that resolved a conflict is voided" do
      fx = feature_fixture()
      advance_main!(fx, %{"lib/a.ex" => "a1\nmain-side\n"})
      git!(fx.origin, ["checkout", "-q", "feature"])
      {_out, 1} = System.cmd("git", ["-C", fx.origin, "merge", "--no-ff", "--no-edit", "main"])
      File.write!(Path.join(fx.origin, "lib/a.ex"), "a1\nresolved\n")
      git!(fx.origin, ["add", "lib/a.ex"])
      git!(fx.origin, ["commit", "-q", "--no-edit"])
      resolved = git!(fx.origin, ["rev-parse", "HEAD"])
      git!(fx.origin, ["checkout", "-q", "main"])

      assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, resolved)
    end

    test "of a branch that is not the target is voided" do
      fx = feature_fixture()
      git!(fx.origin, ["checkout", "-q", "-b", "other", "main"])
      commit!(fx.origin, %{"lib/other.ex" => "o\n"}, "unreviewed other work")
      git!(fx.origin, ["checkout", "-q", "feature"])
      git!(fx.origin, ["merge", "-q", "--no-ff", "--no-edit", "other"])
      merged = git!(fx.origin, ["rev-parse", "HEAD"])
      git!(fx.origin, ["checkout", "-q", "main"])

      assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, merged)
    end

    test "followed by an extra commit is voided" do
      fx = feature_fixture()
      advance_main!(fx)
      _merged = merge_main!(fx)
      git!(fx.origin, ["checkout", "-q", "feature"])
      extra = commit!(fx.origin, %{"lib/evil.ex" => "x\n"}, "extra")

      assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, extra)
    end
  end

  test "an unchanged head, a missing repo or an unknown commit is never proven" do
    fx = feature_fixture()
    assert {:error, _} = SyncProof.verify(fx.clone, "main", fx.reviewed, fx.reviewed)
    assert {:error, _} = SyncProof.verify(nil, "main", fx.reviewed, String.duplicate("0", 40))

    assert {:error, _} =
             SyncProof.verify(fx.clone, "main", fx.reviewed, String.duplicate("0", 40))
  end
end
