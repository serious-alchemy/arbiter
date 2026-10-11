defmodule Arbiter.Loop.Replay.SandboxTest do
  @moduledoc """
  bd-c7lx65 (R15, `docs/design/paced-quota-routing-signals.md` §7.2): a replay
  runs in an isolated checkout at the task's base commit. It is a repository of
  its own that borrows the main repo's objects read-only: one branch at the
  base, no remote, nothing after the base reachable, so the merged change is
  not in it and nothing done in it can reach the main repo or its remote.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Loop.Replay.Sandbox
  alias Arbiter.Test.GitFixture

  import GitFixture, only: [git!: 2, commit!: 3]

  setup do
    %{root: root, origin: origin, clone: repo} =
      GitFixture.origin_and_clone(%{
        "README.md" => "readme\n",
        "lib/app.ex" => "defmodule App do\nend\n"
      })

    base = git!(repo, ["rev-parse", "HEAD"])

    known_good =
      commit!(
        repo,
        %{"lib/feature.ex" => "defmodule Feature do\n  def answer, do: 42\nend\n"},
        "the merged change"
      )

    %{root: root, origin: origin, repo: repo, base: base, known_good: known_good}
  end

  defp refs(repo), do: git!(repo, ["for-each-ref", "--format=%(refname) %(objectname)"])

  defp sandbox!(ctx) do
    dir = Path.join(ctx.root, "replay-#{System.unique_integer([:positive])}")
    assert {:ok, ^dir} = Sandbox.create(ctx.repo, ctx.base, dir)
    dir
  end

  defp run(dir, args), do: System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  describe "create/3" do
    test "checks out the base commit in a repository of its own: one branch, no remote", ctx do
      dir = sandbox!(ctx)

      assert git!(dir, ["rev-parse", "HEAD"]) == ctx.base
      assert git!(dir, ["remote"]) == ""
      assert git!(dir, ["for-each-ref", "--format=%(refname)"]) == "refs/heads/work"
      assert File.read!(Path.join(dir, "lib/app.ex")) =~ "defmodule App"
      assert git!(dir, ["status", "--porcelain"]) == ""

      # Its own git dir, not a linked worktree of the main repo.
      assert File.dir?(Path.join(dir, ".git"))
    end

    test "nothing after the base is in it: the merged change is not there to find", ctx do
      dir = sandbox!(ctx)

      refute File.exists?(Path.join(dir, "lib/feature.ex"))
      refute git!(dir, ["log", "--all", "--format=%H"]) =~ ctx.known_good
      refute git!(dir, ["log", "--all", "--format=%s"]) =~ "the merged change"

      # Not even by its id: the sandbox holds its own copy of the base's
      # history and borrows nothing from the main repo.
      refute File.exists?(Path.join(dir, ".git/objects/info/alternates"))
      assert {_, status} = run(dir, ["cat-file", "-e", ctx.known_good])
      assert status != 0

      refute git!(dir, ["cat-file", "--batch-all-objects", "--batch-check"]) =~ ctx.known_good
    end

    test "it reads the base without the main repo: a jail that hides the main repo still works",
         ctx do
      dir = sandbox!(ctx)
      hidden = ctx.repo <> ".hidden"
      File.rename!(ctx.repo, hidden)

      try do
        assert git!(dir, ["log", "--format=%H", "-1"]) == ctx.base
        commit!(dir, %{"lib/replayed.ex" => "defmodule Replayed do\nend\n"}, "replayed work")
      after
        File.rename!(hidden, ctx.repo)
      end
    end

    test "refuses a base the main repo does not have", ctx do
      dir = Path.join(ctx.root, "replay-missing")
      missing = String.duplicate("d", 40)

      assert {:error, {:unknown_commit, ^missing}} = Sandbox.create(ctx.repo, missing, dir)
      refute File.exists?(dir)
    end

    test "refuses a directory that already exists", ctx do
      dir = Path.join(ctx.root, "replay-taken")
      File.mkdir_p!(dir)

      assert {:error, {:exists, ^dir}} = Sandbox.create(ctx.repo, ctx.base, dir)
    end
  end

  describe "isolation" do
    test "work committed in the sandbox never reaches the main repo or its remote", ctx do
      main_refs = refs(ctx.repo)
      origin_refs = refs(ctx.origin)
      dir = sandbox!(ctx)

      File.write!(Path.join(dir, "lib/replayed.ex"), "defmodule Replayed do\nend\n")
      git!(dir, ["add", "lib/replayed.ex"])
      git!(dir, ["commit", "-q", "-m", "replayed work"])

      assert {_out, status} = run(dir, ["push"])
      assert status != 0
      assert {_out, status} = run(dir, ["push", "origin", "HEAD:main"])
      assert status != 0

      assert refs(ctx.repo) == main_refs
      assert refs(ctx.origin) == origin_refs
      assert git!(ctx.repo, ["status", "--porcelain"]) == ""
    end

    test "remove/1 deletes the sandbox and leaves the main repo as it was", ctx do
      main_refs = refs(ctx.repo)
      dir = sandbox!(ctx)
      commit!(dir, %{"lib/replayed.ex" => "defmodule Replayed do\nend\n"}, "replayed work")

      assert :ok = Sandbox.remove(dir)

      refute File.exists?(dir)
      assert refs(ctx.repo) == main_refs
      assert git!(ctx.repo, ["rev-parse", "HEAD"]) == ctx.known_good
      assert {_, 0} = run(ctx.repo, ["fsck", "--connectivity-only", "--no-dangling"])
    end
  end

  describe "change/2" do
    test "is everything the replay did against the base, without touching its index", ctx do
      dir = sandbox!(ctx)
      commit!(dir, %{"lib/committed.ex" => "defmodule Committed do\nend\n"}, "committed")
      File.write!(Path.join(dir, "lib/staged.ex"), "defmodule Staged do\nend\n")
      git!(dir, ["add", "lib/staged.ex"])
      File.write!(Path.join(dir, "lib/untracked.ex"), "defmodule Untracked do\nend\n")
      File.write!(Path.join(dir, "README.md"), "readme, edited in place\n")

      assert {:ok, %{files: files, patch: patch}} = Sandbox.change(dir, ctx.base)

      assert files == ["README.md", "lib/committed.ex", "lib/staged.ex", "lib/untracked.ex"]
      assert patch =~ "+defmodule Untracked do"
      assert patch =~ "+readme, edited in place"

      assert git!(dir, ["diff", "--cached", "--name-only"]) == "lib/staged.ex"
      assert git!(dir, ["status", "--porcelain"]) =~ "?? lib/untracked.ex"
    end

    test "leaves out what the sandbox's own excludes name (seeded deps)", ctx do
      dir = sandbox!(ctx)
      File.mkdir_p!(Path.join(dir, "deps/somedep"))
      File.write!(Path.join(dir, "deps/somedep/mix.exs"), "seeded\n")
      :ok = Sandbox.exclude(dir, ["deps"])
      File.write!(Path.join(dir, "lib/new.ex"), "defmodule New do\nend\n")

      assert {:ok, %{files: ["lib/new.ex"]}} = Sandbox.change(dir, ctx.base)
    end

    test "an untouched sandbox has no change", ctx do
      assert {:ok, %{files: [], patch: ""}} = Sandbox.change(sandbox!(ctx), ctx.base)
    end

    test "writes nothing into the sandbox: a .git/objects the replay pointed elsewhere is only read",
         ctx do
      dir = sandbox!(ctx)
      outside = Path.join(ctx.root, "outside-objects")
      File.cp_r!(Path.join(dir, ".git/objects"), outside)
      File.rm_rf!(Path.join(dir, ".git/objects"))
      File.ln_s!(outside, Path.join(dir, ".git/objects"))
      File.write!(Path.join(dir, "lib/new.ex"), "defmodule New do\nend\n")
      listing = fn -> Path.wildcard(Path.join(outside, "**"), match_dot: true) end
      before = listing.()
      dot_git = File.ls!(Path.join(dir, ".git"))

      assert {:ok, %{files: ["lib/new.ex"], patch: patch}} = Sandbox.change(dir, ctx.base)
      assert patch =~ "+defmodule New do"

      assert listing.() == before
      assert File.ls!(Path.join(dir, ".git")) == dot_git
    end
  end

  describe "seal/1 and verify/2: host git only in a sandbox the replay left alone" do
    test "an untouched sandbox, and one with ordinary work in it, verify", ctx do
      dir = sandbox!(ctx)
      seal = Sandbox.seal(dir)

      assert :ok = Sandbox.verify(dir, seal)

      commit!(dir, %{"lib/replayed.ex" => "defmodule Replayed do\nend\n"}, "replayed work")
      File.write!(Path.join(dir, "notes.txt"), "scratch\n")
      assert :ok = Sandbox.verify(dir, seal)
    end

    test "git config the replayed model wrote (a program git would run) is refused", ctx do
      for {key, value} <- [
            {"diff.external", "/tmp/evil.sh"},
            {"filter.x.clean", "/tmp/evil.sh"},
            {"include.path", "/tmp/evil.config"}
          ] do
        dir = sandbox!(ctx)
        seal = Sandbox.seal(dir)
        git!(dir, ["config", key, value])

        assert {:error, {:tampered, why}} = Sandbox.verify(dir, seal), key
        assert why =~ "config"
      end
    end

    test "a commondir redirect, or a .git that is no longer a directory, is refused", ctx do
      dir = sandbox!(ctx)
      seal = Sandbox.seal(dir)
      File.write!(Path.join(dir, ".git/commondir"), "/tmp/elsewhere\n")
      assert {:error, {:tampered, _}} = Sandbox.verify(dir, seal)

      dir = sandbox!(ctx)
      seal = Sandbox.seal(dir)
      File.rename!(Path.join(dir, ".git"), Path.join(dir, ".git.moved"))
      File.write!(Path.join(dir, ".git"), "gitdir: /tmp/elsewhere\n")
      assert {:error, {:tampered, _}} = Sandbox.verify(dir, seal)
    end

    test "change/2 never runs an external diff or a textconv, even if one is configured", ctx do
      dir = sandbox!(ctx)
      marker = Path.join(ctx.root, "ext-diff-ran")
      script = Path.join(ctx.root, "ext-diff.sh")
      File.write!(script, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(script, 0o755)
      git!(dir, ["config", "diff.external", script])
      File.write!(Path.join(dir, "lib/app.ex"), "changed\n")

      assert {:ok, %{files: ["lib/app.ex"], patch: patch}} = Sandbox.change(dir, ctx.base)
      assert patch =~ "+changed"
      refute File.exists?(marker)
    end
  end

  describe "committed_empty?/2" do
    test "whether the committed change nets to nothing against the base", ctx do
      dir = sandbox!(ctx)
      assert {:ok, true} = Sandbox.committed_empty?(dir, ctx.base)

      File.write!(Path.join(dir, "lib/uncommitted.ex"), "defmodule Uncommitted do\nend\n")
      assert {:ok, true} = Sandbox.committed_empty?(dir, ctx.base)

      commit!(dir, %{"lib/uncommitted.ex" => "defmodule Uncommitted do\nend\n"}, "commit it")
      assert {:ok, false} = Sandbox.committed_empty?(dir, ctx.base)

      git!(dir, ["revert", "--no-edit", "HEAD"])
      assert {:ok, true} = Sandbox.committed_empty?(dir, ctx.base)
    end
  end

  describe "disconnect/1 and current_branch/1" do
    test "a checkout whose origin is the forge can no longer fetch from it", ctx do
      # The workspace checkout fixture is a clone whose origin is the forge.
      assert {_, 0} = run(ctx.repo, ["fetch", "-q", "origin"])

      assert :ok = Sandbox.disconnect(ctx.repo)

      assert {_, status} = run(ctx.repo, ["fetch", "-q", "origin"])
      assert status != 0
      assert git!(ctx.repo, ["remote", "get-url", "origin"]) =~ "file:///dev/null/"
    end

    test "the branch a checkout is on", ctx do
      assert {:ok, "work"} = Sandbox.current_branch(sandbox!(ctx))
      assert {:ok, "main"} = Sandbox.current_branch(ctx.repo)
    end
  end

  describe "known_good/3" do
    test "is the merged change in the main repo, base to head", ctx do
      assert {:ok, %{files: ["lib/feature.ex"], patch: patch}} =
               Sandbox.known_good(ctx.repo, ctx.base, ctx.known_good)

      assert patch =~ "+  def answer, do: 42"
    end
  end
end
