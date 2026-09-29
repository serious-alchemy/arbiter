defmodule Arbiter.Worker.WorktreeLeftoversTest do
  @moduledoc """
  bd-9iv4qd: the close-time judgement of what a task's worktree still holds
  (`Worktree.leftover_work/2`), the merged-branch reap
  (`Worktree.delete_merged_branch/3`), and the orphan-leaf scan
  (`Worktree.orphaned_leaves/2`).
  """

  use ExUnit.Case, async: false

  import Arbiter.Test.GitFixture, only: [origin_and_clone: 0, git!: 2]

  alias Arbiter.Worker.Worktree

  setup do
    fx = origin_and_clone()
    root = Path.join(fx.root, "wt")
    File.mkdir_p!(root)

    prior = Application.fetch_env(:arbiter, :worktree_root)
    Application.put_env(:arbiter, :worktree_root, root)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbiter, :worktree_root, value)
        :error -> Application.delete_env(:arbiter, :worktree_root)
      end
    end)

    Map.put(fx, :wt_root, root)
  end

  defp worktree!(%{clone: clone}, branch \\ "feature/lo-1-thing") do
    {:ok, path} = Worktree.create(clone, branch, "main")
    configure!(path)
    path
  end

  defp configure!(path) do
    git!(path, ["config", "user.email", "t@example.com"])
    git!(path, ["config", "user.name", "t"])
    git!(path, ["config", "commit.gpgsign", "false"])
  end

  defp commit_in!(path, file, content) do
    File.mkdir_p!(Path.dirname(Path.join(path, file)))
    File.write!(Path.join(path, file), content)
    git!(path, ["add", file])
    git!(path, ["commit", "-q", "-m", "change #{file}"])
    git!(path, ["rev-parse", "HEAD"])
  end

  describe "leftover_work/2" do
    test "a fresh worktree holds nothing", fx do
      path = worktree!(fx)
      assert {:ok, nil} = Worktree.leftover_work(path)
    end

    test "untracked build junk is not work", fx do
      path = worktree!(fx)
      File.mkdir_p!(Path.join(path, "scripts/__pycache__"))
      File.write!(Path.join(path, "scripts/__pycache__/x.cpython-312.pyc"), "bytecode")
      File.mkdir_p!(Path.join(path, "_build/test"))
      File.write!(Path.join(path, "_build/test/x"), "x")
      File.mkdir_p!(Path.join(path, "deps/jason"))
      File.write!(Path.join(path, "deps/jason/mix.exs"), "x")
      File.write!(Path.join(path, ".mcp.json"), ~s({"token":"secret"}))

      assert {:ok, nil} = Worktree.leftover_work(path)
    end

    test "a modified tracked .mcp.json is not work", %{origin: origin, clone: clone} = fx do
      Arbiter.Test.GitFixture.commit!(origin, %{".mcp.json" => "{}\n"}, "add mcp")
      git!(clone, ["fetch", "-q", "origin"])
      path = worktree!(fx)
      File.write!(Path.join(path, ".mcp.json"), ~s({"token":"secret"}\n))

      assert {:ok, nil} = Worktree.leftover_work(path)
    end

    test "staged and modified tracked changes are work, captured as a patch", fx do
      path = worktree!(fx)
      File.write!(Path.join(path, "README.md"), "readme\nstaged line\n")
      git!(path, ["add", "README.md"])
      File.write!(Path.join(path, ".mcp.json"), ~s({"token":"never-in-a-patch"}))

      assert {:ok, %{} = work} = Worktree.leftover_work(path)
      assert work.path == path
      assert work.unpushed == 0
      assert Enum.any?(work.changes, &String.contains?(&1, "README.md"))
      assert work.patch =~ "+staged line"
      refute work.patch =~ "never-in-a-patch"
    end

    test "an untracked source file is work, and named", fx do
      path = worktree!(fx)
      File.write!(Path.join(path, "new_module.ex"), "defmodule New do\nend\n")

      assert {:ok, %{} = work} = Worktree.leftover_work(path)
      assert Enum.any?(work.changes, &String.contains?(&1, "new_module.ex"))
      assert work.patch =~ "new_module.ex"
    end

    test "a commit on no remote is unpushed work", fx do
      path = worktree!(fx)
      commit_in!(path, "lib/a.ex", "local only\n")

      assert {:ok, %{} = work} = Worktree.leftover_work(path)
      assert work.unpushed == 1
      assert work.changes == []
      assert work.patch =~ "+local only"
    end

    test "a pushed commit is not work", fx do
      path = worktree!(fx)
      commit_in!(path, "lib/a.ex", "pushed\n")
      {:ok, _} = Worktree.push(path)

      assert {:ok, nil} = Worktree.leftover_work(path)
    end

    # A squash-merged PR whose remote branch was deleted (and pruned locally):
    # its commits are on no remote ref, but they ARE the head the forge merged.
    test "commits up to a known pushed head are not work", fx do
      path = worktree!(fx)
      head = commit_in!(path, "lib/a.ex", "merged\n")

      assert {:ok, %{unpushed: 1}} = Worktree.leftover_work(path)
      assert {:ok, nil} = Worktree.leftover_work(path, pushed_shas: [head])
    end

    test "a commit after the known pushed head is still work", fx do
      path = worktree!(fx)
      head = commit_in!(path, "lib/a.ex", "merged\n")
      commit_in!(path, "lib/b.ex", "follow-up never pushed\n")

      assert {:ok, %{unpushed: 1} = work} = Worktree.leftover_work(path, pushed_shas: [head])
      assert work.patch =~ "+follow-up never pushed"
      refute work.patch =~ "+merged"
    end

    test "an unknown pushed sha is ignored rather than failing the probe", fx do
      path = worktree!(fx)
      commit_in!(path, "lib/a.ex", "x\n")

      assert {:ok, %{unpushed: 1}} =
               Worktree.leftover_work(path, pushed_shas: [String.duplicate("a", 40), nil])
    end
  end

  describe "delete_merged_branch/3" do
    test "deletes a branch whose tip is on origin", %{clone: clone} = fx do
      branch = "feature/lo-2-pushed"
      path = worktree!(fx, branch)
      commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)
      :ok = Worktree.cleanup(path)

      assert :ok = Worktree.delete_merged_branch(clone, branch)
      refute branch in local_branches(clone)
    end

    test "keeps a branch holding a commit on no remote", %{clone: clone} = fx do
      branch = "feature/lo-3-local"
      path = worktree!(fx, branch)
      commit_in!(path, "lib/a.ex", "x\n")
      :ok = Worktree.cleanup(path)

      assert {:error, :unpushed} = Worktree.delete_merged_branch(clone, branch)
      assert branch in local_branches(clone)
    end

    test "deletes a squash-merged branch whose remote ref is gone when its tip is the merged head",
         %{clone: clone} = fx do
      branch = "feature/lo-4-squashed"
      path = worktree!(fx, branch)
      head = commit_in!(path, "lib/a.ex", "x\n")
      :ok = Worktree.cleanup(path)

      assert {:error, :unpushed} = Worktree.delete_merged_branch(clone, branch)
      assert :ok = Worktree.delete_merged_branch(clone, branch, pushed_shas: [head])
      refute branch in local_branches(clone)
    end

    test "is :ok when the branch does not exist", %{clone: clone} do
      assert :ok = Worktree.delete_merged_branch(clone, "feature/never-existed")
    end
  end

  describe "orphaned_leaves/2" do
    test "names a leaf whose .git file points at missing metadata", %{wt_root: root} do
      orphan = Path.join(root, "feature-VR-1-orphan")
      File.mkdir_p!(Path.join(orphan, "_build"))
      File.write!(Path.join(orphan, ".git"), "gitdir: /nonexistent/repo/.git/worktrees/x\n")

      assert Worktree.orphaned_leaves(root, min_age_ms: 0) == [orphan]
    end

    test "resolves a relative gitdir against the leaf", %{wt_root: root} do
      leaf = Path.join(root, "relative-ok")
      File.mkdir_p!(Path.join(leaf, "meta"))
      File.write!(Path.join(leaf, ".git"), "gitdir: meta\n")

      assert Worktree.orphaned_leaves(root, min_age_ms: 0) == []
    end

    test "never names a live registered worktree", %{wt_root: root} = fx do
      live = worktree!(fx, "feature/lo-5-live")
      orphan = Path.join(root, "orphan")
      File.mkdir_p!(orphan)
      File.write!(Path.join(orphan, ".git"), "gitdir: /nonexistent/x\n")

      leaves = Worktree.orphaned_leaves(root, min_age_ms: 0)
      assert leaves == [orphan]
      refute live in leaves
    end

    # The live worktree root on a dev box also holds things Arbiter never made —
    # a Postgres socket dir, a database data dir, a plain clone. Without a .git
    # *file* there is nothing proving the directory was ever a worktree of ours.
    test "leaves directories with no .git file alone", %{wt_root: root, clone: clone} do
      File.mkdir_p!(Path.join(root, "db_socket"))
      File.mkdir_p!(Path.join([root, "feature-1-shell", "data"]))
      File.mkdir_p!(Path.join(root, "empty"))
      File.cp_r!(clone, Path.join(root, "a-plain-clone"))
      File.write!(Path.join(root, "a-file"), "x")

      assert Worktree.orphaned_leaves(root, min_age_ms: 0) == []
    end

    test "leaves a .git file it cannot parse alone", %{wt_root: root} do
      leaf = Path.join(root, "garbled")
      File.mkdir_p!(leaf)
      File.write!(Path.join(leaf, ".git"), "not a gitdir line\n")

      assert Worktree.orphaned_leaves(root, min_age_ms: 0) == []
    end

    test "spares an orphan younger than min_age_ms", %{wt_root: root} do
      orphan = Path.join(root, "young")
      File.mkdir_p!(orphan)
      File.write!(Path.join(orphan, ".git"), "gitdir: /nonexistent/x\n")

      assert Worktree.orphaned_leaves(root, min_age_ms: 3_600_000) == []
    end

    test "is [] for a missing root" do
      assert Worktree.orphaned_leaves("/nonexistent/worktree/root") == []
    end
  end

  defp local_branches(repo) do
    repo
    |> git!(["branch", "--format=%(refname:short)"])
    |> String.split("\n", trim: true)
  end
end
