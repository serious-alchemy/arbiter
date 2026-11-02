defmodule Arbiter.Mergers.TrainCarTest do
  @moduledoc """
  bd-6dyva0 — the git side of a speculative merge-train car: a merge commit on
  an Arbiter-owned ref, built with plumbing in the repo's own checkout (never on
  an MR branch or a worktree), and the landing-tree prediction that lets a car's
  green pipeline authorise the MR's own forge merge. Real repositories: a bare
  `origin`, a seed clone that plays the developers and the forge, and the
  `repo_paths` checkout the train builds in.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.TrainCar

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    origin = Path.join(dir, "origin.git")
    seed = Path.join(dir, "seed")
    repo = Path.join(dir, "repo")

    git!(dir, ["init", "--bare", "--initial-branch=main", origin])
    git!(dir, ["clone", origin, seed])
    configure(seed)
    write(seed, "base.txt", "one\ntwo\nthree\n")
    commit!(seed, "base")
    git!(seed, ["push", "origin", "main"])

    # The checkout the train builds in is cloned before any MR exists, so every
    # MR head has to be fetched by sha, as in production.
    git!(dir, ["clone", origin, repo])
    configure(repo)

    a = branch!(seed, "feature/a", "a.txt", "from a\n")
    b = branch!(seed, "feature/b", "b.txt", "from b\n")

    %{origin: origin, seed: seed, repo: repo, dir: dir, a: a, b: b}
  end

  describe "build/4" do
    test "a car is a two-parent merge of its base and the MR head, tree = merge-tree", ctx do
      main = remote(ctx.origin, "main")

      assert {:ok, car} = TrainCar.build(ctx.repo, main, ctx.a)

      assert car.base == main
      assert car.mr_head == ctx.a
      assert parents(ctx.repo, car.sha) == [main, ctx.a]
      assert tree(ctx.repo, car.sha) == car.tree
      assert files(ctx.repo, car.sha) == ["a.txt", "base.txt"]
    end

    test "cars stack: main + A, then main + A + B", ctx do
      main = remote(ctx.origin, "main")
      {:ok, c1} = TrainCar.build(ctx.repo, main, ctx.a)

      assert {:ok, c2} = TrainCar.build(ctx.repo, c1.sha, ctx.b)
      assert parents(ctx.repo, c2.sha) == [c1.sha, ctx.b]
      assert files(ctx.repo, c2.sha) == ["a.txt", "b.txt", "base.txt"]
    end

    test "the same base and head build the same car (a rebuild is a no-op)", ctx do
      main = remote(ctx.origin, "main")
      {:ok, first} = TrainCar.build(ctx.repo, main, ctx.a)
      {:ok, again} = TrainCar.build(ctx.repo, main, ctx.a)

      assert again.sha == first.sha
    end

    test "a merge that conflicts builds nothing and names the files", ctx do
      main = remote(ctx.origin, "main")
      x = branch!(ctx.seed, "feature/x", "a.txt", "x wrote this instead\n")
      {:ok, c1} = TrainCar.build(ctx.repo, main, ctx.a)

      assert {:error, {:conflict, ["a.txt"]}} = TrainCar.build(ctx.repo, c1.sha, x)
    end

    test "an unknown commit is an error, never a car", ctx do
      main = remote(ctx.origin, "main")

      assert {:error, _} =
               TrainCar.build(ctx.repo, main, "0123456789abcdef0123456789abcdef01234567")

      assert {:error, :no_repo_path} = TrainCar.build(nil, main, ctx.a)
    end
  end

  describe "landing_tree/3 — what the forge's merge of the MR will land" do
    test "after car 1's MR merges, car 2's MR lands exactly car 2's tree", ctx do
      main = remote(ctx.origin, "main")
      {:ok, c1} = TrainCar.build(ctx.repo, main, ctx.a)
      {:ok, c2} = TrainCar.build(ctx.repo, c1.sha, ctx.b)

      # Nothing has merged: B alone on main is not what car 2 tested.
      {:ok, tip} = TrainCar.target_tip(ctx.repo, "main")
      assert {:ok, landing} = TrainCar.landing_tree(ctx.repo, tip, ctx.b)
      refute landing == c2.tree

      # The forge merges A (its own merge commit, not the car): same tree as car 1.
      merged_a = forge_merge!(ctx, "feature/a")
      assert tree(ctx.seed, merged_a) == c1.tree

      {:ok, tip} = TrainCar.target_tip(ctx.repo, "main")
      assert tip == merged_a
      assert {:ok, landing_b} = TrainCar.landing_tree(ctx.repo, tip, ctx.b)
      assert landing_b == c2.tree

      # …and the forge's merge of B lands that very tree on main.
      merged_b = forge_merge!(ctx, "feature/b")
      assert tree(ctx.seed, merged_b) == c2.tree
    end

    test "a target that moved under the car predicts a different tree", ctx do
      main = remote(ctx.origin, "main")
      {:ok, c1} = TrainCar.build(ctx.repo, main, ctx.a)

      git!(ctx.seed, ["checkout", "main"])
      write(ctx.seed, "hotfix.txt", "pushed straight to main\n")
      commit!(ctx.seed, "hotfix")
      git!(ctx.seed, ["push", "origin", "main"])

      {:ok, tip} = TrainCar.target_tip(ctx.repo, "main")
      refute tip == main
      assert {:ok, landing} = TrainCar.landing_tree(ctx.repo, tip, ctx.a)
      refute landing == c1.tree
    end
  end

  describe "verify/2 — a car commit is a non-authored merge" do
    test "a car built here proves out", ctx do
      {:ok, car} = TrainCar.build(ctx.repo, remote(ctx.origin, "main"), ctx.a)
      assert :ok = TrainCar.verify(ctx.repo, car)
    end

    test "a commit that adds anything beyond the merge is refused", ctx do
      main = remote(ctx.origin, "main")
      {:ok, car} = TrainCar.build(ctx.repo, main, ctx.a)

      # Same parents, but a tree carrying a smuggled file.
      smuggled = smuggle!(ctx.repo, car.sha, "smuggled.txt", "nobody reviewed this\n")
      forged = commit_tree!(ctx.repo, smuggled, [main, ctx.a])

      assert {:error, :tree_differs_from_merge} =
               TrainCar.verify(ctx.repo, %{car | sha: forged, tree: smuggled})

      # The recorded tree is checked too, not just the commit's own.
      assert {:error, :tree_differs_from_record} =
               TrainCar.verify(ctx.repo, %{car | tree: smuggled})
    end

    test "parents other than the recorded base and MR head are refused", ctx do
      main = remote(ctx.origin, "main")
      {:ok, car} = TrainCar.build(ctx.repo, main, ctx.a)

      assert {:error, :parents_differ} = TrainCar.verify(ctx.repo, %{car | mr_head: ctx.b})
    end
  end

  describe "push/4, delete/2 and landed/4" do
    test "a car is pushed to its Arbiter-owned ref, replaced on rebuild, then deleted", ctx do
      main = remote(ctx.origin, "main")
      ref = TrainCar.ref_name("bd-abc123")
      assert ref == "arbiter/train/bd-abc123"

      {:ok, c1} = TrainCar.build(ctx.repo, main, ctx.a)
      assert :ok = TrainCar.push(ctx.repo, c1.sha, ref, [])
      assert remote(ctx.origin, ref) == c1.sha

      # The MR branch itself is never touched.
      assert remote(ctx.origin, "feature/a") == ctx.a

      {:ok, rebuilt} = TrainCar.build(ctx.repo, ctx.b, ctx.a)
      assert :ok = TrainCar.push(ctx.repo, rebuilt.sha, ref, [])
      assert remote(ctx.origin, ref) == rebuilt.sha

      assert :ok = TrainCar.delete(ctx.repo, ref)

      assert {_, code} =
               System.cmd(
                 "git",
                 ["-C", ctx.origin, "rev-parse", "--verify", "refs/heads/" <> ref],
                 stderr_to_stdout: true
               )

      refute code == 0
      # Deleting a ref that is already gone is fine.
      assert :ok = TrainCar.delete(ctx.repo, ref)
    end

    test "ref names are sanitised and take a prefix" do
      assert TrainCar.ref_name("bd-x/../y", "trains/") == "trains/bd-x-y"
      assert TrainCar.ref_name("bd-1", nil) == "arbiter/train/bd-1"
    end

    test "landed/4 finds the target commit that landed the car's tree", ctx do
      main = remote(ctx.origin, "main")
      {:ok, c1} = TrainCar.build(ctx.repo, main, ctx.a)
      assert {:error, :not_landed} = TrainCar.landed(ctx.repo, "main", c1)

      merged = forge_merge!(ctx, "feature/a")
      assert {:ok, ^merged} = TrainCar.landed(ctx.repo, "main", c1)
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp configure(path) do
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@example.invalid"])
    git!(path, ["config", "commit.gpgsign", "false"])
  end

  defp write(dir, file, content), do: File.write!(Path.join(dir, file), content)

  defp commit!(dir, message) do
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-m", message])
    git!(dir, ["rev-parse", "HEAD"])
  end

  # An MR branch off the current main, pushed; returns its head.
  defp branch!(seed, name, file, content) do
    git!(seed, ["checkout", "main"])
    git!(seed, ["pull", "--ff-only", "origin", "main"])
    git!(seed, ["checkout", "-b", name])
    write(seed, file, content)
    head = commit!(seed, "work on #{name}")
    git!(seed, ["push", "origin", name])
    git!(seed, ["checkout", "main"])
    head
  end

  # What a forge's merge-commit merge does: main gets a new merge commit of its
  # tip and the MR head. Returns the merge commit.
  defp forge_merge!(ctx, branch) do
    git!(ctx.seed, ["checkout", "main"])
    git!(ctx.seed, ["pull", "--ff-only", "origin", "main"])
    git!(ctx.seed, ["fetch", "origin", branch])
    git!(ctx.seed, ["merge", "--no-ff", "--no-edit", "origin/" <> branch])
    git!(ctx.seed, ["push", "origin", "main"])
    git!(ctx.seed, ["rev-parse", "HEAD"])
  end

  defp smuggle!(repo, sha, file, content) do
    tmp_index = Path.join(System.tmp_dir!(), "idx-#{System.unique_integer([:positive])}")
    env = [{"GIT_INDEX_FILE", tmp_index}]
    {_, 0} = System.cmd("git", ["-C", repo, "read-tree", sha], env: env)
    blob_path = Path.join(System.tmp_dir!(), "blob-#{System.unique_integer([:positive])}")
    File.write!(blob_path, content)
    {blob, 0} = System.cmd("git", ["-C", repo, "hash-object", "-w", blob_path])

    {_, 0} =
      System.cmd(
        "git",
        [
          "-C",
          repo,
          "update-index",
          "--add",
          "--cacheinfo",
          "100644,#{String.trim(blob)},#{file}"
        ],
        env: env
      )

    {tree, 0} = System.cmd("git", ["-C", repo, "write-tree"], env: env)
    File.rm(tmp_index)
    File.rm(blob_path)
    String.trim(tree)
  end

  defp commit_tree!(repo, tree, parents) do
    args = Enum.flat_map(parents, &["-p", &1])
    git!(repo, ["commit-tree", tree | args] ++ ["-m", "forged"])
  end

  defp remote(origin, branch), do: git!(origin, ["rev-parse", "refs/heads/" <> branch])
  defp tree(repo, sha), do: git!(repo, ["rev-parse", sha <> "^{tree}"])

  defp parents(repo, sha) do
    [^sha | parents] = repo |> git!(["rev-list", "--parents", "-n", "1", sha]) |> String.split()
    parents
  end

  defp files(repo, sha),
    do: repo |> git!(["ls-tree", "--name-only", sha]) |> String.split("\n", trim: true)

  defp git!(cd, args) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    String.trim(out)
  end
end
