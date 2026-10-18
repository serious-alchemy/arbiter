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
      assert {:ok, 0} = MergeFreshness.behind_by(clone, "main", feat)

      git(clone, ["checkout", "main"])
      File.write!(Path.join(clone, "c"), "1")
      git(clone, ["add", "."])
      git(clone, ["commit", "-m", "main2"])
      git(clone, ["push", "origin", "main"])

      assert {:ok, 1} = MergeFreshness.behind_by(clone, "main", feat)
    end

    test "an unusable repo is an error, never 'fresh'" do
      assert {:error, _} = MergeFreshness.behind_by(nil, "main", "abc1234")
    end

    defp rev(clone, ref) do
      {out, 0} = System.cmd("git", ["-C", clone, "rev-parse", ref])
      String.trim(out)
    end
  end
end
