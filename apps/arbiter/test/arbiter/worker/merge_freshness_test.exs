defmodule Arbiter.Worker.MergeFreshnessTest do
  @moduledoc "bd-5z9yvb — the merge-time freshness setting and the local-git behind check."

  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.MergeFreshness

  defp ws(config), do: %Workspace{id: "w", config: config}

  describe "settings" do
    test "required by default, with no tolerance" do
      assert MergeFreshness.required?(ws(%{}))
      assert MergeFreshness.required?(nil)
      assert MergeFreshness.tolerance(ws(%{})) == 0
    end

    test "merge.require_up_to_date can switch it off (bool or string)" do
      refute MergeFreshness.required?(ws(%{"merge" => %{"require_up_to_date" => false}}))
      refute MergeFreshness.required?(ws(%{"merge" => %{"require_up_to_date" => "false"}}))
      assert MergeFreshness.required?(ws(%{"merge" => %{"require_up_to_date" => true}}))
    end

    test "merge.up_to_date_tolerance is a non-negative commit count" do
      assert MergeFreshness.tolerance(ws(%{"merge" => %{"up_to_date_tolerance" => 5}})) == 5
      assert MergeFreshness.tolerance(ws(%{"merge" => %{"up_to_date_tolerance" => "7"}})) == 7
      assert MergeFreshness.tolerance(ws(%{"merge" => %{"up_to_date_tolerance" => -1}})) == 0
    end
  end

  describe "behind_by/3 (real git)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mf-#{System.unique_integer([:positive])}")
      origin = Path.join(dir, "origin.git")
      clone = Path.join(dir, "clone")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      git(dir, ["init", "--bare", "-b", "main", origin])
      git(dir, ["clone", origin, clone])
      git(clone, ["config", "user.email", "t@t"])
      git(clone, ["config", "user.name", "t"])
      File.write!(Path.join(clone, "a"), "1")
      git(clone, ["add", "."])
      git(clone, ["commit", "-m", "init"])
      git(clone, ["push", "origin", "main"])
      git(clone, ["checkout", "-b", "feat"])
      File.write!(Path.join(clone, "b"), "1")
      git(clone, ["add", "."])
      git(clone, ["commit", "-m", "feat"])
      git(clone, ["push", "origin", "feat"])
      %{clone: clone}
    end

    defp git(cwd, args),
      do: {_, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)

    test "0 when the branch contains the target tip, N once main moves", %{clone: clone} do
      feat = rev(clone, "feat")
      assert {:ok, 0} = Arbiter.Mergers.LocalCompare.behind_by(clone, "main", feat)

      git(clone, ["checkout", "main"])
      File.write!(Path.join(clone, "c"), "1")
      git(clone, ["add", "."])
      git(clone, ["commit", "-m", "main2"])
      git(clone, ["push", "origin", "main"])

      assert {:ok, 1} = Arbiter.Mergers.LocalCompare.behind_by(clone, "main", feat)
    end

    test "counts first-parent target commits: a merged 6-commit branch is one", %{clone: clone} do
      base = rev(clone, "feat")
      merge_feature_into_main(clone, "f1", 6)

      assert {:ok, 1} = Arbiter.Mergers.LocalCompare.behind_by(clone, "main", base)
    end

    test "tolerance counts merged MRs, not their commits", %{clone: clone} do
      base = rev(clone, "feat")
      ws = ws(%{"merge" => %{"up_to_date_tolerance" => 1}})

      merge_feature_into_main(clone, "f1", 6)
      assert :fresh = real_check(ws, clone, base)

      merge_feature_into_main(clone, "f2", 6)
      assert {:stale, 2} = real_check(ws, clone, base)
    end

    test "tolerance 0 syncs for any missing target commit", %{clone: clone} do
      base = rev(clone, "feat")
      merge_feature_into_main(clone, "f1", 3)

      assert {:stale, 1} = real_check(ws(%{}), clone, base)
    end

    test "direct commits on the target each count", %{clone: clone} do
      base = rev(clone, "feat")
      git(clone, ["checkout", "main"])

      for n <- 1..3 do
        File.write!(Path.join(clone, "d#{n}"), "1")
        git(clone, ["add", "."])
        git(clone, ["commit", "-m", "direct#{n}"])
      end

      git(clone, ["push", "origin", "main"])

      assert {:ok, 3} = Arbiter.Mergers.LocalCompare.behind_by(clone, "main", base)
    end

    test "an unusable repo is an error, never 'fresh'" do
      assert {:error, _} = Arbiter.Mergers.LocalCompare.behind_by(nil, "main", "abc1234")
    end

    # test_helper stubs the probe globally (and the env is shared across async
    # tests), so apply `check/4`'s comparison to the real git count directly.
    defp real_check(ws, clone, base) do
      {:ok, n} = Arbiter.Mergers.LocalCompare.behind_by(clone, "main", base)
      if n > MergeFreshness.tolerance(ws), do: {:stale, n}, else: :fresh
    end

    defp merge_feature_into_main(clone, name, commits) do
      git(clone, ["checkout", "-b", name, "main"])

      for n <- 1..commits do
        File.write!(Path.join(clone, "#{name}-#{n}"), "1")
        git(clone, ["add", "."])
        git(clone, ["commit", "-m", "#{name} #{n}"])
      end

      git(clone, ["checkout", "main"])
      git(clone, ["merge", "--no-ff", "-m", "merge #{name}", name])
      git(clone, ["push", "origin", "main"])
    end

    defp rev(clone, ref) do
      {out, 0} = System.cmd("git", ["-C", clone, "rev-parse", ref])
      String.trim(out)
    end
  end
end
