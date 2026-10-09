defmodule Arbiter.Worker.PrivateCloneTest do
  @moduledoc """
  bd-4wy1w1 (P5): git layout B — a worker's private clone that borrows the
  main repo's objects through `objects/info/alternates` and owns everything
  else (refs, index, config) itself.

  Host-side only; the container half (what a podman worker can and cannot
  write) is `private_clone_podman_test.exs` (`@moduletag :podman`).
  """
  # async: false — the fixture points the worktree root (Application env) at
  # a private directory.
  use ExUnit.Case, async: false

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Worktree

  import GitFixture, only: [git!: 2, commit!: 3]

  @branch "feature/bd-p5-layout-b"

  setup do
    GitFixture.forge_and_checkout(%{"README.md" => "readme\n", "lib/a.ex" => "a\n"})
  end

  defp git(dir, args), do: System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp pins(repo, leaf) do
    repo
    |> git!(["for-each-ref", "--format=%(refname)", "refs/arbiter/workers/#{leaf}/"])
    |> String.split("\n", trim: true)
  end

  defp commit_in(path, files, message) do
    Enum.each(files, fn {file, content} ->
      full = Path.join(path, file)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      git!(path, ["add", file])
    end)

    git!(path, ["-c", "user.email=w@t", "-c", "user.name=w", "commit", "-q", "-m", message])
    git!(path, ["rev-parse", "HEAD"])
  end

  describe "create/3" do
    test "builds a clone at the branch's worktree leaf that borrows main's objects", ctx do
      assert {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")

      # Same leaf a linked worktree would use, so every consumer that derives
      # the path from the branch name finds it.
      assert path == Worktree.worktree_path(@branch)
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(path, ".git"))
      assert {:ok, @branch} = Worktree.current_branch(path)

      upstream = git!(ctx.checkout, ["rev-parse", "refs/remotes/origin/main"])
      assert git!(path, ["rev-parse", "HEAD"]) == upstream
      assert File.read!(Path.join(path, "lib/a.ex")) == "a\n"

      # Objects are borrowed, not copied.
      common = git!(ctx.checkout, ["rev-parse", "--path-format=absolute", "--git-common-dir"])

      assert File.read!(Path.join(path, ".git/objects/info/alternates")) ==
               Path.join(common, "objects") <> "\n"

      assert git!(path, ["count-objects", "-v"]) =~ ~r/^count: 0$/m
      assert git!(path, ["count-objects", "-v"]) =~ ~r/^packs: 0$/m

      # `origin` is the forge, exactly as in a linked worktree (shared config),
      # and the base is there both as `origin/<base>` and as a local branch.
      assert git!(path, ["remote", "get-url", "origin"]) == ctx.forge
      assert git!(path, ["rev-parse", "refs/remotes/origin/main"]) == upstream
      assert git!(path, ["rev-parse", "refs/heads/main"]) == upstream

      # Not registered with the main repo, and the branch is not there yet.
      refute git!(ctx.checkout, ["worktree", "list", "--porcelain"]) =~ path
      assert {_, code} = git(ctx.checkout, ["rev-parse", "--verify", "refs/heads/" <> @branch])
      assert code != 0
    end

    test "cuts from upstream, not from main's stale local base", ctx do
      fresh = commit!(ctx.seed, %{"new.txt" => "upstream\n"}, "upstream moved")
      git!(ctx.seed, ["push", "-q", "origin", "main"])

      assert {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")

      assert git!(path, ["rev-parse", "HEAD"]) == fresh
      assert File.read!(Path.join(path, "new.txt")) == "upstream\n"
      # Main's own branch never moved.
      refute git!(ctx.checkout, ["rev-parse", "refs/heads/main"]) == fresh
    end

    test "starts from the branch main already has (a redispatch after sync-back)", ctx do
      git!(ctx.checkout, ["checkout", "-q", "-b", @branch])
      tip = commit!(ctx.checkout, %{"work.txt" => "earlier round\n"}, "earlier round")
      git!(ctx.checkout, ["checkout", "-q", "main"])

      assert {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")

      assert git!(path, ["rev-parse", "HEAD"]) == tip
      assert File.read!(Path.join(path, "work.txt")) == "earlier round\n"
    end

    test "is idempotent for a clone already on the branch", ctx do
      assert {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      head = commit_in(path, %{"w.txt" => "w\n"}, "work")

      assert {:ok, ^path} = PrivateClone.create(ctx.checkout, @branch, "main")
      assert git!(path, ["rev-parse", "HEAD"]) == head
    end

    test "refuses a leaf that holds a linked worktree", ctx do
      assert {:ok, path} = Worktree.create(ctx.checkout, @branch, "main")

      assert {:error, {:layout_mismatch, ^path}} =
               PrivateClone.create(ctx.checkout, @branch, "main")
    end

    test "aborts on a missing base without leaving a clone behind", ctx do
      assert {:error, reason} = PrivateClone.create(ctx.checkout, @branch, "does-not-exist")
      assert match?({:fetch_failed, _}, reason) or match?({:missing_origin_ref, _}, reason)
      refute File.exists?(Worktree.worktree_path(@branch))
    end

    test "pins its start commit in main and confines alternate refs to its pins", ctx do
      assert {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      leaf = Path.basename(path)
      start = git!(path, ["rev-parse", "HEAD"])

      assert git!(ctx.checkout, ["rev-parse", "refs/arbiter/workers/#{leaf}/base"]) == start

      assert git!(path, ["config", "--get", "core.alternateRefsPrefixes"]) ==
               "refs/arbiter/workers/#{leaf}/"
    end

    # A container sees no global git config, so the clone carries the
    # identity itself: the main repo's effective value, once, so a worker's own
    # `git config user.email ...` still works (two entries would make that a
    # "multiple values" error).
    test "carries the main repo's effective commit identity as a single value", ctx do
      # A global value as well as the main repo's own, whatever this host has.
      global = Path.join(ctx.root, "gitconfig-global")
      File.write!(global, "[user]\n\temail = global@example.com\n")
      prior = System.get_env("GIT_CONFIG_GLOBAL")
      System.put_env("GIT_CONFIG_GLOBAL", global)

      on_exit(fn ->
        if prior,
          do: System.put_env("GIT_CONFIG_GLOBAL", prior),
          else: System.delete_env("GIT_CONFIG_GLOBAL")
      end)

      git!(ctx.checkout, ["config", "user.email", "local@example.com"])

      assert {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")

      assert git!(path, ["config", "--local", "--get-all", "user.email"]) == "local@example.com"
      assert {_, 0} = git(path, ["config", "user.email", "worker@example.com"])
    end

    test "names its main repo and branch, and carries a commondir guard git ignores", ctx do
      assert {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")

      assert PrivateClone.clone?(path)
      assert PrivateClone.main_repo(path) == ctx.checkout
      refute PrivateClone.clone?(ctx.checkout)

      # A `commondir` of "." is the gitdir itself: a container can then be
      # given it read-only, so a worker cannot plant one that points host git
      # at a config it wrote.
      assert File.read!(Path.join(path, ".git/commondir")) == ".\n"

      assert git!(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) ==
               Path.join(path, ".git")
    end
  end

  describe "sync_back/1" do
    setup ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      %{path: path, leaf: Path.basename(path)}
    end

    test "copies the clone's branch, ref and objects, into main", ctx do
      head = commit_in(ctx.path, %{"lib/b.ex" => "b\n"}, "worker commit")

      assert {:ok, ^head} = PrivateClone.sync_back(ctx.path)
      assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == head

      # The objects were copied, not borrowed back: main reads the commit with
      # the clone gone.
      File.rm_rf!(ctx.path)
      assert git!(ctx.checkout, ["show", "#{head}:lib/b.ex"]) == "b"
    end

    test "follows a rewritten clone branch, as a shared ref would", ctx do
      commit_in(ctx.path, %{"lib/b.ex" => "b\n"}, "first")
      {:ok, _} = PrivateClone.sync_back(ctx.path)

      git!(ctx.path, [
        "-c",
        "user.email=w@t",
        "-c",
        "user.name=w",
        "commit",
        "-q",
        "--amend",
        "-m",
        "amended"
      ])

      amended = git!(ctx.path, ["rev-parse", "HEAD"])

      assert {:ok, ^amended} = PrivateClone.sync_back(ctx.path)
      assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == amended
    end

    test "pins the synced head", ctx do
      head = commit_in(ctx.path, %{"lib/b.ex" => "b\n"}, "worker commit")
      {:ok, _} = PrivateClone.sync_back(ctx.path)

      assert git!(ctx.checkout, ["rev-parse", "refs/arbiter/workers/#{ctx.leaf}/head"]) == head
    end

    test "carries what the clone pushed into main's origin/<branch>", ctx do
      head = commit_in(ctx.path, %{"lib/b.ex" => "b\n"}, "worker commit")
      git!(ctx.path, ["push", "-q", "origin", @branch])

      {:ok, _} = PrivateClone.sync_back(ctx.path)

      assert git!(ctx.checkout, ["rev-parse", "refs/remotes/origin/" <> @branch]) == head
    end

    test "never rolls back a newer origin/<branch> the main repo fetched itself", ctx do
      commit_in(ctx.path, %{"lib/b.ex" => "b\n"}, "worker commit")
      git!(ctx.path, ["push", "-q", "origin", @branch])

      # Someone else (a review fix round) moved the forge branch on; the main
      # repo fetched it, the clone did not.
      git!(ctx.seed, ["fetch", "-q", "origin", @branch])
      git!(ctx.seed, ["checkout", "-q", "-b", @branch, "FETCH_HEAD"])
      newer = commit!(ctx.seed, %{"fix.txt" => "fix\n"}, "fix round")
      git!(ctx.seed, ["push", "-q", "origin", @branch])
      git!(ctx.checkout, ["fetch", "-q", "origin", @branch])

      {:ok, _} = PrivateClone.sync_back(ctx.path)

      assert git!(ctx.checkout, ["rev-parse", "refs/remotes/origin/" <> @branch]) == newer
    end

    test "a branch the worker deleted is an error, not a deleted main branch", ctx do
      git!(ctx.path, ["checkout", "-q", "--detach"])
      git!(ctx.path, ["branch", "-q", "-D", @branch])

      assert {:error, {:sync_back_failed, _}} = PrivateClone.sync_back(ctx.path)
    end

    test "is not for linked worktrees", ctx do
      {:ok, linked} = Worktree.create(ctx.checkout, "feature/linked", "main")
      assert {:error, :not_a_private_clone} = PrivateClone.sync_back(linked)
    end
  end

  describe "attach/4 on a clone that already exists (bd-cccm1k)" do
    test "copies the main repo's current origin/<base> into the reused clone", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      stale = git!(path, ["rev-parse", "refs/remotes/origin/main"])

      # The target moves on the forge; the host fetches it into the main repo.
      moved = commit!(ctx.seed, %{"lib/b.ex" => "b\n"}, "main moves on")
      git!(ctx.seed, ["push", "-q", "origin", "main"])
      :ok = Worktree.fetch_origin(ctx.checkout, "main")
      assert git!(ctx.checkout, ["rev-parse", "refs/remotes/origin/main"]) == moved
      assert git!(path, ["rev-parse", "refs/remotes/origin/main"]) == stale

      assert {:ok, ^path} = PrivateClone.attach(ctx.checkout, @branch, "main")

      assert git!(path, ["rev-parse", "refs/remotes/origin/main"]) == moved
    end

    test "a base the main repo has no origin ref for leaves the reused clone as it was", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      stale = git!(path, ["rev-parse", "refs/remotes/origin/main"])

      assert {:ok, ^path} = PrivateClone.attach(ctx.checkout, @branch, "no-such-base")

      assert git!(path, ["rev-parse", "refs/remotes/origin/main"]) == stale
    end
  end

  describe "refresh_base/2" do
    test "copies in (and pins) the main repo's current origin/<base> for the base asked about",
         ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      git!(ctx.seed, ["checkout", "-q", "-b", "release"])
      release = commit!(ctx.seed, %{"rel.txt" => "r\n"}, "release line")
      git!(ctx.seed, ["push", "-q", "origin", "release"])
      git!(ctx.checkout, ["fetch", "-q", "origin", "release"])

      assert :ok = PrivateClone.refresh_base(path, "release")

      assert git!(path, ["rev-parse", "refs/remotes/origin/release"]) == release

      assert git!(ctx.checkout, [
               "rev-parse",
               "refs/arbiter/workers/#{Path.basename(path)}/target"
             ]) ==
               release
    end
  end

  describe "create_review/3 (bd-7ays3v: a reviewer's read-only clone of the PR head)" do
    setup ctx do
      head = commit!(ctx.seed, %{"lib/pr.ex" => "pr\n"}, "the PR head")
      git!(ctx.seed, ["push", "-q", "origin", "main:feature/pr"])
      git!(ctx.checkout, ["fetch", "-q", "origin", "feature/pr"])
      %{head: head, review_path: Path.join(ctx.worktree_root, "gate-review-abc-1")}
    end

    test "checks the head out in a clone of its own, at the path it is given", ctx do
      assert {:ok, path} =
               PrivateClone.create_review(ctx.checkout, ctx.head,
                 path: ctx.review_path,
                 base: "main"
               )

      assert path == ctx.review_path
      assert PrivateClone.clone?(path)
      assert PrivateClone.main_repo(path) == Path.expand(ctx.checkout)
      assert git!(path, ["rev-parse", "HEAD"]) == ctx.head
      assert File.read!(Path.join(path, "lib/pr.ex")) == "pr\n"
      assert git!(path, ["rev-parse", "refs/remotes/origin/main"])
      assert :ok = PrivateClone.verify(path)
      assert {:ok, _mounts} = PrivateClone.mounts(path)

      # The implementer's branch is neither created nor registered by it.
      refute git!(ctx.checkout, ["worktree", "list", "--porcelain"]) =~ path
    end

    test "is marked read-only, and nothing in it ever reaches the main repo's branches", ctx do
      {:ok, path} =
        PrivateClone.create_review(ctx.checkout, ctx.head, path: ctx.review_path, base: "main")

      assert PrivateClone.read_only?(path)
      refute PrivateClone.read_only?(ctx.checkout)

      before =
        git!(ctx.checkout, ["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"])

      commit_in(path, %{"lib/x.ex" => "x\n"}, "reviewer scribble")

      assert {:error, :read_only_clone} = PrivateClone.sync_back(path)
      assert :ok = PrivateClone.remove(path)
      refute File.exists?(path)

      assert git!(ctx.checkout, [
               "for-each-ref",
               "--format=%(refname) %(objectname)",
               "refs/heads"
             ]) ==
               before
    end

    test "has no way to push: origin is read from the forge but pushes go nowhere", ctx do
      {:ok, path} =
        PrivateClone.create_review(ctx.checkout, ctx.head, path: ctx.review_path, base: "main")

      assert git!(path, ["remote", "get-url", "origin"]) == ctx.forge
      assert {out, code} = git(path, ["push", "origin", "HEAD:refs/heads/hijack"])
      assert code != 0, out

      assert {_, code} =
               System.cmd("git", ["-C", ctx.forge, "rev-parse", "refs/heads/hijack"],
                 stderr_to_stdout: true
               )

      assert code != 0
    end

    test "pins the head against gc in the main repo while it lives", ctx do
      {:ok, path} =
        PrivateClone.create_review(ctx.checkout, ctx.head, path: ctx.review_path, base: "main")

      assert pins(ctx.checkout, Path.basename(path)) != []
      assert :ok = PrivateClone.remove(path)
      assert pins(ctx.checkout, Path.basename(path)) == []
    end

    test "refuses a sha the main repo does not have", ctx do
      assert {:error, _} =
               PrivateClone.create_review(ctx.checkout, String.duplicate("a", 40),
                 path: ctx.review_path
               )

      refute File.exists?(ctx.review_path)
    end
  end

  describe "remove/1" do
    test "syncs back, removes the clone and drops its pins", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      leaf = Path.basename(path)
      head = commit_in(path, %{"lib/b.ex" => "b\n"}, "worker commit")
      assert pins(ctx.checkout, leaf) != []

      assert :ok = PrivateClone.remove(path)

      refute File.exists?(path)
      assert pins(ctx.checkout, leaf) == []
      # The branch outlives its checkout, as a linked worktree's does.
      assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == head
    end

    test "an already-removed clone is :ok", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      assert :ok = PrivateClone.remove(path)
      assert :ok = PrivateClone.remove(path)
    end
  end

  describe "mounts/1" do
    test "is the hardened layout-B container mount set", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      common = git!(ctx.checkout, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
      dot_git = Path.join(path, ".git")

      assert {:ok, mounts} = PrivateClone.mounts(path)
      assert mounts[:worktree] == path
      assert mounts[:git_dir] == dot_git
      assert mounts[:objects] == Path.join(common, "objects")

      assert Enum.sort(mounts[:readonly_paths]) ==
               Enum.sort(
                 Enum.map(
                   ~w(config hooks commondir objects/info/alternates),
                   &Path.join(dot_git, &1)
                 )
               )

      assert Enum.all?(mounts[:readonly_paths], &File.exists?/1)
    end

    test "refuses anything that is not a private clone", ctx do
      {:ok, linked} = Worktree.create(ctx.checkout, "feature/linked", "main")
      assert {:error, :not_a_private_clone} = PrivateClone.mounts(linked)
      assert {:error, :not_a_private_clone} = PrivateClone.mounts(ctx.checkout)
    end

    test "refuses a clone whose alternates no longer name its main repo's objects", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      File.write!(Path.join(path, ".git/objects/info/alternates"), "/elsewhere/objects\n")

      assert {:error, {:tampered, _}} = PrivateClone.mounts(path)
    end
  end

  describe "refs outside the clone (the spike's sibling-ref probe, inverted)" do
    test "a ref written in the clone never reaches main", ctx do
      git!(ctx.checkout, ["branch", "feature/sibling"])
      sibling = git!(ctx.checkout, ["rev-parse", "refs/heads/feature/sibling"])

      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      head = commit_in(path, %{"evil.txt" => "x\n"}, "worker commit")

      # Layout A let this rewrite the sibling's branch in the shared ref store.
      git!(path, ["update-ref", "refs/heads/feature/sibling", head])
      git!(path, ["update-ref", "refs/heads/main", head])

      assert git!(ctx.checkout, ["rev-parse", "refs/heads/feature/sibling"]) == sibling
      refute git!(ctx.checkout, ["rev-parse", "refs/heads/main"]) == head

      # And sync-back carries only the task branch.
      {:ok, _} = PrivateClone.sync_back(path)
      assert git!(ctx.checkout, ["rev-parse", "refs/heads/feature/sibling"]) == sibling
      refute git!(ctx.checkout, ["rev-parse", "refs/heads/main"]) == head
    end
  end

  describe "gc in main against a live clone" do
    # Make every ref in main that reaches the clone's base go away, then gc
    # with no grace period: only the pin keeps the base alive.
    defp rewrite_and_prune!(checkout) do
      git!(checkout, ["checkout", "-q", "--orphan", "rewritten"])
      git!(checkout, ["rm", "-rq", "--cached", "."])

      git!(checkout, [
        "-c",
        "user.email=t@t",
        "-c",
        "user.name=t",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "orphan"
      ])

      git!(checkout, ["branch", "-q", "-D", "main"])
      git!(checkout, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      _ = git(checkout, ["update-ref", "-d", "refs/remotes/origin/HEAD"])
      git!(checkout, ["reflog", "expire", "--expire=now", "--all"])
      git!(checkout, ["gc", "-q", "--prune=now"])
    end

    test "cannot prune the history a live clone borrows: its base is pinned", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      start = git!(path, ["rev-parse", "HEAD"])
      commit_in(path, %{"lib/b.ex" => "b\n"}, "worker commit")

      rewrite_and_prune!(ctx.checkout)

      assert {_, 0} = git(ctx.checkout, ["cat-file", "-e", start <> "^{commit}"])
      assert {log, 0} = git(path, ["log", "--format=%s"])
      assert log =~ "worker commit"
      assert log =~ "init"
      assert {_, 0} = git(path, ["fsck", "--connectivity-only", "--no-dangling"])
    end

    test "control: without its pins the same gc breaks the clone", ctx do
      {:ok, path} = PrivateClone.create(ctx.checkout, @branch, "main")
      leaf = Path.basename(path)
      start = git!(path, ["rev-parse", "HEAD"])

      for ref <- pins(ctx.checkout, leaf), do: git!(ctx.checkout, ["update-ref", "-d", ref])
      rewrite_and_prune!(ctx.checkout)

      assert {_, code} = git(ctx.checkout, ["cat-file", "-e", start <> "^{commit}"])
      assert code != 0
      assert {_, code} = git(path, ["log", "--format=%s"])
      assert code != 0
    end
  end
end
