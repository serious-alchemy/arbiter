defmodule Arbiter.Worker.PrivateCloneGitSwapTest do
  @moduledoc """
  bd-6t7u81 (#390): a worker that gets `mv .git .git2` through (the parent
  directory is writable) and recreates `.git` with its own `config` and
  `hooks` must not get anything of its own run by a host-side git.

  Under the podman backend the checkout's `.git` is itself a mount point
  (`PrivateClone.mounts/1`'s `:git_dir`), so the rename fails `EBUSY`
  (`private_clone_podman_test.exs`). These tests are for when it does not: a
  layout without that mount (a node-side or cluster shadow clone, a regression
  in the mount set), where the host is the only thing between the swapped
  `.git` and its own git. They swap the directory on the host, as the worker
  would have, and plant every config-driven execution vector a git command in
  that tree could reach: `core.fsmonitor`, `core.hooksPath`, a hook,
  `core.alternateRefsCommand` (run by the upload-pack a sync-back starts) and
  a clean filter.
  """
  # async: false — the fixture points the worktree root (Application env) at
  # a private directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Worktree

  import GitFixture, only: [git!: 2]

  @branch "feature/bd-6t7u81-git-swap"

  setup do
    fixture = GitFixture.forge_and_checkout(%{"README.md" => "readme\n", "lib/a.ex" => "a\n"})
    {:ok, path} = PrivateClone.create(fixture.checkout, @branch, "main")

    marker_dir = Path.join(System.tmp_dir!(), "arb-swap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(marker_dir)
    on_exit(fn -> File.rm_rf!(marker_dir) end)

    Map.merge(fixture, %{path: path, marker_dir: marker_dir})
  end

  defp reclaim(path) do
    log = capture_log(fn -> send(self(), {:reclaimed, PrivateClone.reclaim(path)}) end)
    assert log =~ "PrivateClone:"
    assert_received {:reclaimed, result}
    result
  end

  defp marker(ctx, name), do: Path.join(ctx.marker_dir, name)

  defp fired(ctx), do: ctx.marker_dir |> File.ls!() |> Enum.sort()

  # What the worker does: rename the real `.git`, recreate one that keeps the
  # clone's markers, alternates and `commondir` (so every identity check that
  # reads the config alone is satisfied) and adds the payloads.
  defp swap_git!(ctx, extra_config \\ nil) do
    dot_git = Path.join(ctx.path, ".git")
    File.rename!(dot_git, dot_git <> "2")
    File.mkdir_p!(Path.join(dot_git, "objects/info"))
    File.mkdir_p!(Path.join(dot_git, "refs/heads"))
    File.mkdir_p!(Path.join(dot_git, "hooks"))

    for file <- ~w(HEAD index commondir objects/info/alternates) do
      File.cp!(Path.join(dot_git <> "2", file), Path.join(dot_git, file))
    end

    File.cp_r!(Path.join(dot_git <> "2", "refs"), Path.join(dot_git, "refs"))

    File.write!(
      Path.join(dot_git, "config"),
      File.read!(Path.join(dot_git <> "2", "config")) <> (extra_config || payload_config(ctx))
    )

    hook = Path.join([dot_git, "hooks", "reference-transaction"])
    File.write!(hook, "#!/bin/sh\ntouch #{marker(ctx, "hook")}\n")
    File.chmod!(hook, 0o755)
    File.mkdir_p!(Path.join(dot_git, "info"))
    File.write!(Path.join(dot_git, "info/attributes"), "* filter=pwn\n")
    dot_git
  end

  defp payload_config(ctx) do
    """
    [core]
    \tfsmonitor = touch #{marker(ctx, "fsmonitor")}; echo
    \talternateRefsCommand = touch #{marker(ctx, "alternate_refs")}
    [filter "pwn"]
    \tclean = touch #{marker(ctx, "filter")}; cat
    """
  end

  defp swap_with_hooks_path!(ctx) do
    hooks = ctx.marker_dir <> "-hooks"
    File.mkdir_p!(hooks)
    on_exit(fn -> File.rm_rf!(hooks) end)

    for name <- ~w(reference-transaction post-checkout pre-push) do
      File.write!(Path.join(hooks, name), "#!/bin/sh\ntouch #{marker(ctx, "hooks_path")}\n")
      File.chmod!(Path.join(hooks, name), 0o755)
    end

    swap_git!(ctx, "[core]\n\thooksPath = #{hooks}\n")
  end

  describe "a clone the worker has not touched" do
    test "verifies, including after the worker's own commits and the host's pushes", ctx do
      assert :ok = PrivateClone.verify(ctx.path)

      File.write!(Path.join(ctx.path, "w.txt"), "w\n")
      git!(ctx.path, ["add", "w.txt"])
      git!(ctx.path, ["-c", "user.email=w@t", "-c", "user.name=w", "commit", "-qm", "w"])
      git!(ctx.path, ["config", "--local", "branch.#{@branch}.remote", "origin"])
      git!(ctx.path, ["config", "--local", "branch.#{@branch}.merge", "refs/heads/#{@branch}"])

      assert :ok = PrivateClone.verify(ctx.path)
      assert {:ok, _} = PrivateClone.sync_back(ctx.path)
      assert {:ok, _} = PrivateClone.mounts(ctx.path)
    end
  end

  describe "a .git the worker renamed and recreated" do
    test "is not trusted: nothing refuses to run on it but nothing runs it either", ctx do
      swap_git!(ctx)

      assert {:error, {:tampered, _}} = PrivateClone.verify(ctx.path)
      assert {:error, {:tampered, _}} = PrivateClone.mounts(ctx.path)
      assert {:error, {:tampered, _}} = PrivateClone.refresh_base(ctx.path)
      assert {:error, {:tampered, _}} = PrivateClone.sync_back(ctx.path)
      assert {:error, {:tampered, _}} = Worktree.sync_back(ctx.path)

      assert fired(ctx) == []
    end

    test "is not trusted even with the clone's own identity markers copied in", ctx do
      swap_git!(ctx)
      # The marker the host reads to recognise a clone is the worker's to copy.
      assert PrivateClone.main_repo(ctx.path) == Path.expand(ctx.checkout)
      assert PrivateClone.clone?(ctx.path)

      assert {:error, {:tampered, _}} = PrivateClone.sync_back(ctx.path)
      assert fired(ctx) == []
    end

    test "Worktree's own git calls refuse to run in it", ctx do
      swap_git!(ctx)

      assert {:error, _} = Worktree.current_branch(ctx.path)
      assert {:error, _} = Worktree.push(ctx.path, branch: @branch)
      assert fired(ctx) == []
    end

    test "re-dispatching onto the checkout restores the real .git first", ctx do
      swap_git!(ctx)

      log =
        capture_log(fn ->
          send(self(), {:created, PrivateClone.create(ctx.checkout, @branch, "main")})
        end)

      assert log =~ "the recorded .git is back"
      assert_received {:created, {:ok, path}}
      assert path == ctx.path
      assert :ok = PrivateClone.verify(ctx.path)
      assert fired(ctx) == []
    end

    test "reclaim/1 puts the real .git back and sets the impostor aside", ctx do
      original = File.lstat!(Path.join(ctx.path, ".git")).inode
      swap_git!(ctx)

      assert {:error, {:tampered, _}} = reclaim(ctx.path)
      assert File.lstat!(Path.join(ctx.path, ".git")).inode == original
      assert File.dir?(Path.join(ctx.path, ".git.tampered"))
      refute File.exists?(Path.join(ctx.path, ".git2"))
      assert :ok = PrivateClone.verify(ctx.path)

      # Host-side git, run the way the rest of the control plane runs it,
      # now reads the real config and hooks.
      git!(ctx.path, ["status", "--porcelain"])
      git!(ctx.path, ["diff", "--stat"])
      git!(ctx.path, ["update-ref", "refs/heads/#{@branch}", "HEAD"])
      File.write!(Path.join(ctx.path, "n.txt"), "n\n")
      git!(ctx.path, ["add", "n.txt"])
      assert {:ok, _} = PrivateClone.sync_back(ctx.path)

      assert fired(ctx) == []
    end

    test "reclaim/1 on an untouched clone is :ok and changes nothing", ctx do
      assert :ok = PrivateClone.reclaim(ctx.path)
      refute File.exists?(Path.join(ctx.path, ".git.tampered"))
      assert :ok = PrivateClone.verify(ctx.path)
    end

    test "reclaim/1 when the real .git is gone sets the impostor aside and leaves none", ctx do
      swap_git!(ctx)
      File.rm_rf!(Path.join(ctx.path, ".git2"))

      assert {:error, {:tampered, _}} = reclaim(ctx.path)
      refute File.exists?(Path.join(ctx.path, ".git"))
      assert File.dir?(Path.join(ctx.path, ".git.tampered"))
    end

    test "a core.hooksPath in the recreated config is not trusted either", ctx do
      swap_with_hooks_path!(ctx)

      assert {:error, {:tampered, _}} = PrivateClone.sync_back(ctx.path)
      assert {:error, {:tampered, _}} = reclaim(ctx.path)
      git!(ctx.path, ["update-ref", "refs/heads/#{@branch}", "HEAD"])
      assert fired(ctx) == []
    end
  end

  describe "host-side git run through PrivateClone.cmd/3" do
    test "refuses a swapped tree for the commands that read the config", ctx do
      swap_git!(ctx)

      for args <- [["status", "--porcelain"], ["diff", "main..HEAD"], ["rev-parse", "HEAD"]] do
        assert {out, 128} = PrivateClone.cmd(ctx.path, args, stderr_to_stdout: true)
        assert out =~ "refusing to run git"
      end

      assert fired(ctx) == []
    end

    test "runs in an untouched clone and in a path that is not a private clone", ctx do
      assert {"", 0} = PrivateClone.cmd(ctx.path, ["status", "--porcelain"])
      assert {_, 0} = PrivateClone.cmd(ctx.checkout, ["status", "--porcelain"])
    end
  end

  describe "settle/1 (the completion-time check)" do
    test "is :ok for an untouched clone and a path that is not a checkout leaf", ctx do
      assert :ok = PrivateClone.settle(ctx.path)
      assert :ok = PrivateClone.settle(ctx.checkout)
      assert :ok = PrivateClone.settle(nil)
    end

    test "reports a swapped .git, restores the real one, and nothing fires", ctx do
      original = File.lstat!(Path.join(ctx.path, ".git")).inode
      swap_git!(ctx)

      log = capture_log(fn -> send(self(), {:settled, PrivateClone.settle(ctx.path)}) end)

      assert_received {:settled, {:error, {:tampered, _}}}
      assert log =~ "the recorded .git is back"
      assert File.lstat!(Path.join(ctx.path, ".git")).inode == original
      assert :ok = PrivateClone.verify(ctx.path)
      assert fired(ctx) == []
    end

    test "reports a clone left with no .git at all, and puts the real one back", ctx do
      dot_git = Path.join(ctx.path, ".git")
      File.rename!(dot_git, dot_git <> "2")

      capture_log(fn -> send(self(), {:settled, PrivateClone.settle(ctx.path)}) end)

      assert_received {:settled, {:error, {:tampered, _}}}
      assert :ok = PrivateClone.verify(ctx.path)
    end
  end

  describe "a config edited in place (no rename)" do
    test "is not trusted: a fsmonitor, hooksPath or alternateRefsCommand added to it", ctx do
      dot_git = Path.join(ctx.path, ".git")

      File.write!(
        Path.join(dot_git, "config"),
        File.read!(Path.join(dot_git, "config")) <> payload_config(ctx)
      )

      assert {:error, {:tampered, _}} = PrivateClone.verify(ctx.path)
      assert {:error, {:tampered, _}} = PrivateClone.sync_back(ctx.path)
      assert fired(ctx) == []
    end

    test "a hook dropped into hooks/ is not trusted", ctx do
      hook = Path.join(ctx.path, ".git/hooks/pre-push")
      File.write!(hook, "#!/bin/sh\ntouch #{marker(ctx, "hook")}\n")
      File.chmod!(hook, 0o755)

      assert {:error, {:tampered, _}} = PrivateClone.verify(ctx.path)
    end

    test "a remote url that is a transport helper is not trusted", ctx do
      git!(ctx.path, ["config", "remote.origin.url", "ext::touch #{marker(ctx, "ext")}"])

      assert {:error, {:tampered, _}} = PrivateClone.verify(ctx.path)
    end

    test "a symlinked config or hooks is not trusted", ctx do
      dot_git = Path.join(ctx.path, ".git")
      File.rename!(Path.join(dot_git, "hooks"), Path.join(ctx.marker_dir, "hooks"))
      File.ln_s!(Path.join(ctx.marker_dir, "hooks"), Path.join(dot_git, "hooks"))

      assert {:error, {:tampered, _}} = PrivateClone.verify(ctx.path)
    end
  end
end
