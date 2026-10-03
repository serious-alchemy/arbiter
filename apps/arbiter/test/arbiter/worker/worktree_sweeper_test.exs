defmodule Arbiter.Worker.WorktreeSweeperTest do
  @moduledoc """
  bd-9iv4qd: the periodic sweep that reclaims worktree-root directories whose
  gitdir is gone — and never touches a live worktree or anything that was not
  provably a worktree.
  """

  use ExUnit.Case, async: false

  import Arbiter.Test.GitFixture, only: [origin_and_clone: 0]

  alias Arbiter.Worker.PrivateClone
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

  # bd-4wy1w1: git layout B. A private clone has a `.git` *directory*, so the
  # gitdir-file rule above never names one; it is dead when the main repo it
  # borrows its objects from is gone. Its gc pins in a main repo that is still
  # there are dead once no clone at their leaf is left.
  describe "private clones" do
    setup ctx do
      main2 = Path.join(ctx.root, "../main2") |> Path.expand()
      {_, 0} = System.cmd("git", ["clone", "-q", ctx.origin, main2])
      {:ok, live} = PrivateClone.create(ctx.clone, "feature/sw-b-live", "main")
      {:ok, doomed} = PrivateClone.create(main2, "feature/sw-b-doomed", "main")
      %{main2: main2, live_clone: live, doomed: doomed}
    end

    test "a clone whose main repo is gone is swept; a live clone is untouched", ctx do
      File.rm_rf!(ctx.main2)

      assert %{removed: removed, failed: []} = WorktreeSweeper.sweep_once(min_age_ms: 0)

      assert ctx.doomed in removed
      refute File.exists?(ctx.doomed)
      refute ctx.live_clone in removed
      assert PrivateClone.clone?(ctx.live_clone)
    end

    test "min_age_ms spares a fresh dead clone", ctx do
      File.rm_rf!(ctx.main2)

      assert %{removed: removed} = WorktreeSweeper.sweep_once(min_age_ms: 3_600_000)
      refute ctx.doomed in removed
      assert File.dir?(ctx.doomed)
    end

    test "pins whose clone is gone are dropped; a live clone keeps its pins", ctx do
      {:ok, vanished} = PrivateClone.create(ctx.clone, "feature/sw-b-vanished", "main")
      vanished_pins = PrivateClone.pin_prefix(Path.basename(vanished))
      live_pins = PrivateClone.pin_prefix(Path.basename(ctx.live_clone))
      # Removed out of band: nothing ran PrivateClone.remove/1 to unpin it.
      File.rm_rf!(vanished)

      assert %{unpinned: unpinned} = WorktreeSweeper.sweep_once(min_age_ms: 0)

      assert Enum.all?(unpinned, &String.starts_with?(&1, vanished_pins))
      assert unpinned != []
      assert pins(ctx.clone, vanished_pins) == ""
      refute pins(ctx.clone, live_pins) == ""
    end
  end

  defp pins(repo, prefix) do
    {out, 0} = System.cmd("git", ["-C", repo, "for-each-ref", "--format=%(refname)", prefix])
    String.trim(out)
  end
end
