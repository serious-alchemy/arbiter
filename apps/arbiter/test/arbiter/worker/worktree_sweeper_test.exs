defmodule Arbiter.Worker.WorktreeSweeperTest do
  @moduledoc """
  bd-9iv4qd: the periodic sweep that reclaims worktree-root directories whose
  gitdir is gone — and never touches a live worktree or anything that was not
  provably a worktree.
  """

  use ExUnit.Case, async: false

  import Arbiter.Test.GitFixture, only: [origin_and_clone: 0]

  alias Arbiter.Worker.Worktree
  alias Arbiter.Worker.WorktreeSweeper

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

    {:ok, live} = Worktree.create(fx.clone, "feature/sw-1-live", "main")
    File.write!(Path.join(live, "uncommitted.txt"), "live work\n")

    orphan = Path.join(root, "feature-VR-18208-orphan")
    File.mkdir_p!(Path.join([orphan, "_build", "test"]))
    File.write!(Path.join(orphan, ".git"), "gitdir: #{fx.clone}/.git/worktrees/pruned-long-ago\n")

    ext_review = Path.join(root, "ext-review-85f385e63616-24387")
    File.mkdir_p!(ext_review)
    File.write!(Path.join(ext_review, ".git"), "gitdir: /tmp/dbg-gone/clone/.git/worktrees/x\n")

    db_socket = Path.join(root, "db_socket")
    File.mkdir_p!(db_socket)
    File.write!(Path.join(db_socket, ".s.PGSQL.5432.lock"), "1\n")

    Map.merge(fx, %{root: root, live: live, orphan: orphan, ext: ext_review, db: db_socket})
  end

  test "sweep_once removes gitdir-less leaves and nothing else", ctx do
    assert %{removed: removed, failed: []} = WorktreeSweeper.sweep_once(min_age_ms: 0)

    assert Enum.sort(removed) == Enum.sort([ctx.orphan, ctx.ext])
    refute File.exists?(ctx.orphan)
    refute File.exists?(ctx.ext)

    # A live registered worktree — uncommitted work included — is untouched.
    assert File.read!(Path.join(ctx.live, "uncommitted.txt")) == "live work\n"
    assert Enum.any?(Worktree.list(ctx.clone), &(&1.path == ctx.live))
    # So is a directory that was never a worktree.
    assert File.exists?(Path.join(ctx.db, ".s.PGSQL.5432.lock"))
  end

  test "sweep_once honours min_age_ms", ctx do
    assert %{removed: []} = WorktreeSweeper.sweep_once(min_age_ms: 3_600_000)
    assert File.dir?(ctx.orphan)
  end

  test "sweep_once accepts an explicit root", ctx do
    other = Path.join(ctx.root, "..") |> Path.join("other-root") |> Path.expand()
    File.mkdir_p!(Path.join(other, "x"))
    File.write!(Path.join([other, "x", ".git"]), "gitdir: /nonexistent\n")

    assert %{removed: [removed]} = WorktreeSweeper.sweep_once(root: other, min_age_ms: 0)
    assert removed == Path.join(other, "x")
    assert File.dir?(ctx.orphan)
  end

  test "the GenServer sweeps on its tick", ctx do
    pid =
      start_supervised!(
        {WorktreeSweeper, name: nil, enabled: true, interval_ms: 3_600_000, min_age_ms: 0}
      )

    send(pid, :sweep)
    _ = :sys.get_state(pid)

    refute File.exists?(ctx.orphan)
    assert File.dir?(ctx.live)
  end

  test "sweep_now/1 runs one sweep and reports it", ctx do
    pid = start_supervised!({WorktreeSweeper, name: nil, enabled: false, min_age_ms: 0})

    assert %{removed: removed} = WorktreeSweeper.sweep_now(pid)
    assert ctx.orphan in removed
  end
end
