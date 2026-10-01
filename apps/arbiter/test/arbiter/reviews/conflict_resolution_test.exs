defmodule Arbiter.Reviews.ConflictResolutionTest do
  # Real git: the property under test is what `git merge-tree` and a rebased or
  # merged head actually look like, so every case builds a repository.
  use ExUnit.Case, async: true

  alias Arbiter.Reviews.ConflictResolution

  @body Enum.map_join(1..12, "", &"line #{&1}\n")

  setup do
    dir = Path.join(System.tmp_dir!(), "cr" <> Base.encode16(:crypto.strong_rand_bytes(4)))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git(dir, ["init", "-q", "-b", "main"])
    git(dir, ["config", "user.email", "t@example.com"])
    git(dir, ["config", "user.name", "T"])
    File.write!(Path.join(dir, "f.txt"), @body)
    File.write!(Path.join(dir, "g.txt"), "g\n")
    commit(dir, "base")

    # The approved branch: edits f.txt line 4.
    git(dir, ["checkout", "-q", "-b", "feat"])
    edit(dir, "f.txt", "line 4", "line 4 (feature)")
    commit(dir, "feature work")
    approved = head(dir)
    git(dir, ["checkout", "-q", "main"])

    {:ok, dir: dir, approved: approved}
  end

  describe "classify/4 — clean integrations" do
    test "a conflict-free rebase onto a moved target is :clean", %{dir: dir, approved: approved} do
      main_moves(dir, "line 10", "line 10 (main)")
      rebased = rebase(dir)

      assert {:clean, info} = ConflictResolution.classify(dir, [approved], rebased, "main")
      assert info.approved == approved
      assert info.head == rebased
      assert info.files == []
      refute info.base_old == info.base_new
    end

    test "a conflict-free merge of the target is :clean", %{dir: dir, approved: approved} do
      main_moves(dir, "line 10", "line 10 (main)")
      git(dir, ["checkout", "-q", "-b", "merged", "feat"])
      git(dir, ["merge", "-q", "--no-edit", "main"])

      assert {:clean, _} = ConflictResolution.classify(dir, [approved], head(dir), "main")
    end

    test "a rebase whose context lines moved (net diff would differ) is still :clean", %{
      dir: dir,
      approved: approved
    } do
      # Main inserts lines right above the feature's hunk, so the hunk's
      # numbers and context change — but nothing conflicts.
      main_moves(dir, "line 2", "line 2\ninserted a\ninserted b")
      rebased = rebase(dir)

      assert {:clean, _} = ConflictResolution.classify(dir, [approved], rebased, "main")
    end

    test "the newest covered head that classifies wins", %{dir: dir, approved: approved} do
      main_moves(dir, "line 10", "line 10 (main)")
      rebased = rebase(dir)

      assert {:clean, info} =
               ConflictResolution.classify(dir, [rebased, approved, "0000000"], rebased, "main")

      assert info.approved == approved
    end
  end

  describe "classify/4 — hand-resolved conflicts" do
    test "a resolved collision is :resolution, with both sides and the resolution", %{
      dir: dir,
      approved: approved
    } do
      main_moves(dir, "line 4", "line 4 (main)")
      rebased = rebase_resolving(dir, "f.txt", "line 4 (main + feature)\n")

      assert {:resolution, info} = ConflictResolution.classify(dir, [approved], rebased, "main")
      assert [%{path: "f.txt", regions: [region]}] = info.files
      assert region.ours == ["line 4 (main)"]
      assert region.theirs == ["line 4 (feature)"]
      assert region.base == ["line 4"]
      assert region.resolution == ["line 4 (main + feature)"]
    end

    test "render/2 shows only the conflicted hunk, not the rest of the file", %{
      dir: dir,
      approved: approved
    } do
      main_moves(dir, "line 4", "line 4 (main)")
      rebased = rebase_resolving(dir, "f.txt", "line 4 (main + feature)\n")
      {:resolution, info} = ConflictResolution.classify(dir, [approved], rebased, "main")

      packet = ConflictResolution.render(info)

      assert packet =~ "line 4 (main)"
      assert packet =~ "line 4 (feature)"
      assert packet =~ "line 4 (main + feature)"
      refute packet =~ "line 9"
    end

    test "a resolution that also merges clean main changes elsewhere stays :resolution", %{
      dir: dir,
      approved: approved
    } do
      main_moves(dir, "line 4", "line 4 (main)")
      main_moves(dir, "line 11", "line 11 (main)")
      rebased = rebase_resolving(dir, "f.txt", "line 4 (both)\n", keep: "line 11 (main)")

      assert {:resolution, %{files: [%{path: "f.txt"}]}} =
               ConflictResolution.classify(dir, [approved], rebased, "main")
    end
  end

  describe "classify/4 — authored content is never covered" do
    test "a hunk smuggled into a clean merge commit is :authored", %{dir: dir, approved: approved} do
      main_moves(dir, "line 10", "line 10 (main)")
      git(dir, ["checkout", "-q", "-b", "sneaky", "feat"])
      git(dir, ["merge", "-q", "--no-edit", "--no-commit", "main"])
      File.write!(Path.join(dir, "g.txt"), "g\nsmuggled\n")
      git(dir, ["add", "."])
      git(dir, ["commit", "-q", "-m", "Merge main"])

      assert {:authored, {:outside_conflict, ["g.txt"]}} =
               ConflictResolution.classify(dir, [approved], head(dir), "main")
    end

    test "a smuggled hunk in a file the merge touched cleanly is :authored", %{
      dir: dir,
      approved: approved
    } do
      main_moves(dir, "line 10", "line 10 (main)")
      git(dir, ["checkout", "-q", "-b", "sneaky", "feat"])
      git(dir, ["merge", "-q", "--no-edit", "--no-commit", "main"])
      edit(dir, "f.txt", "line 8", "line 8 (smuggled)")
      git(dir, ["add", "."])
      git(dir, ["commit", "-q", "-m", "Merge main"])

      assert {:authored, {:outside_conflict, ["f.txt"]}} =
               ConflictResolution.classify(dir, [approved], head(dir), "main")
    end

    test "a smuggled hunk in a conflicted file, outside its conflict region, is :authored", %{
      dir: dir,
      approved: approved
    } do
      main_moves(dir, "line 4", "line 4 (main)")

      rebased =
        rebase_resolving(dir, "f.txt", "line 4 (both)\n", also: {"line 8", "line 8 (smuggled)"})

      assert {:authored, {:outside_conflict, ["f.txt"]}} =
               ConflictResolution.classify(dir, [approved], rebased, "main")
    end

    test "a new file added in the integration is :authored", %{dir: dir, approved: approved} do
      main_moves(dir, "line 10", "line 10 (main)")
      git(dir, ["checkout", "-q", "-b", "sneaky", "feat"])
      git(dir, ["merge", "-q", "--no-edit", "--no-commit", "main"])
      File.write!(Path.join(dir, "new.txt"), "hello\n")
      git(dir, ["add", "."])
      git(dir, ["commit", "-q", "-m", "Merge main"])

      assert {:authored, {:outside_conflict, ["new.txt"]}} =
               ConflictResolution.classify(dir, [approved], head(dir), "main")
    end

    test "a fix commit on top of the approved head (no base change) is :authored", %{
      dir: dir,
      approved: approved
    } do
      git(dir, ["checkout", "-q", "feat"])
      edit(dir, "f.txt", "line 6", "line 6 (ci fix)")
      commit(dir, "fix credo")

      assert {:authored, {:outside_conflict, ["f.txt"]}} =
               ConflictResolution.classify(dir, [approved], head(dir), "main")
    end

    test "a fix commit stacked on a merge of the target is :authored", %{
      dir: dir,
      approved: approved
    } do
      main_moves(dir, "line 10", "line 10 (main)")
      git(dir, ["checkout", "-q", "-b", "later", "feat"])
      git(dir, ["merge", "-q", "--no-edit", "main"])
      edit(dir, "f.txt", "line 6", "line 6 (ci fix)")
      commit(dir, "fix credo")

      assert {:authored, _} = ConflictResolution.classify(dir, [approved], head(dir), "main")
    end

    test "committing the conflict markers is not a resolution", %{dir: dir, approved: approved} do
      main_moves(dir, "line 4", "line 4 (main)")

      rebased =
        rebase_resolving(
          dir,
          "f.txt",
          "<<<<<<< HEAD\nline 4 (main)\n=======\nline 4 (feature)\n>>>>>>> feature\n"
        )

      assert {:authored, {:conflict_markers_left, "f.txt"}} =
               ConflictResolution.classify(dir, [approved], rebased, "main")
    end

    test "a conflicted file deleted by the resolution is :authored", %{
      dir: dir,
      approved: approved
    } do
      main_moves(dir, "line 4", "line 4 (main)")

      git(dir, ["checkout", "-q", "-b", "head", "feat"])
      git(dir, ["rebase", "main"], allow_failure: true)
      git(dir, ["rm", "-q", "-f", "f.txt"])
      git(dir, ["-c", "core.editor=true", "rebase", "--continue"])

      assert {:authored, _} = ConflictResolution.classify(dir, [approved], head(dir), "main")
    end
  end

  describe "classify/4 — unanswerable questions fail closed" do
    test "an unknown approved commit is not :clean", %{dir: dir} do
      assert {:unknown, _} =
               ConflictResolution.classify(dir, [String.duplicate("a", 40)], head(dir), "main")
    end

    test "an unknown target is not :clean", %{dir: dir, approved: approved} do
      assert {:unknown, _} = ConflictResolution.classify(dir, [approved], approved, "nope")
    end

    test "an option-shaped ref is refused", %{dir: dir, approved: approved} do
      assert {:unknown, _} = ConflictResolution.classify(dir, [approved], approved, "--all")
    end

    test "no approved commit other than the head answers :unknown", %{dir: dir} do
      assert {:unknown, :no_approved_commit} =
               ConflictResolution.classify(dir, [head(dir)], head(dir), "main")
    end

    test "a non-repository answers :unknown, never raising" do
      assert {:unknown, _} =
               ConflictResolution.classify("/nonexistent-dir", ["abc1234"], "def5678", "main")
    end
  end

  # ---- fixture helpers ------------------------------------------------------

  defp git(dir, args, opts \\ []) do
    {out, code} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

    if code != 0 and not Keyword.get(opts, :allow_failure, false),
      do: flunk("git #{Enum.join(args, " ")} failed (#{code}): #{out}")

    out
  end

  defp head(dir), do: dir |> git(["rev-parse", "HEAD"]) |> String.trim()

  defp commit(dir, message) do
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", message])
  end

  defp edit(dir, file, from, to) do
    path = Path.join(dir, file)
    File.write!(path, path |> File.read!() |> String.replace(from, to, global: false))
  end

  # A commit on main (always checks main out first).
  defp main_moves(dir, from, to) do
    git(dir, ["checkout", "-q", "main"])
    edit(dir, "f.txt", from, to)
    commit(dir, "main: #{to}")
  end

  # Replays `feat` onto the current `main` on a new branch; the rebase must be
  # conflict-free.
  defp rebase(dir) do
    git(dir, ["checkout", "-q", "-b", "rebased#{System.unique_integer([:positive])}", "feat"])
    git(dir, ["rebase", "main"])
    head(dir)
  end

  # Replays `feat` onto `main`, expecting a conflict in `file`, and resolves it
  # by writing `content` for the region.
  #
  # `:keep` — the full-file line the resolved file must still carry, asserted
  # so a fixture mistake cannot pass silently. `:also` — `{from, to}` extra edit
  # made while resolving (the smuggled hunk).
  defp rebase_resolving(dir, file, content, opts \\ []) do
    git(dir, ["checkout", "-q", "-b", "res#{System.unique_integer([:positive])}", "feat"])
    git(dir, ["rebase", "main"], allow_failure: true)

    path = Path.join(dir, file)
    current = File.read!(path)
    assert current =~ "<<<<<<<", "the fixture expected a conflict in #{file}"

    resolved = Regex.replace(~r/<<<<<<<.*?>>>>>>>[^\n]*\n/s, current, content, global: false)

    resolved =
      case Keyword.get(opts, :also) do
        {from, to} -> String.replace(resolved, from, to, global: false)
        nil -> resolved
      end

    case Keyword.get(opts, :keep) do
      nil -> :ok
      line -> assert resolved =~ line
    end

    File.write!(path, resolved)
    git(dir, ["add", file])
    git(dir, ["-c", "core.editor=true", "rebase", "--continue"])
    head(dir)
  end
end
