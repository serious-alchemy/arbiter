defmodule Arbiter.Worker.WorktreeThinCloneTest do
  @moduledoc """
  RW11 (`docs/design/remote-workers.md` §9): `seed: false` makes a **thin** home clone,
  the checkout of record for a run on a node. The container never sees it (the node's
  shadow clone does the work), so there is nothing to seed: no `deps`/`_build` copy
  and no `mix deps.get`.
  """
  # async: false — the fixture points the worktree root at a private directory and
  # the test puts a stub `mix` first on PATH.
  use ExUnit.Case, async: false

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.Worktree

  import GitFixture, only: [git!: 2]

  @branch "feature/bd-rw11-thin"

  setup do
    ctx = GitFixture.forge_and_checkout(%{"mix.exs" => "# mix\n", "lib/a.ex" => "a\n"})

    # a compiled-deps tree in the source checkout, and a `mix` that leaves a marker
    File.mkdir_p!(Path.join(ctx.checkout, "deps/dep_a"))
    File.write!(Path.join(ctx.checkout, "deps/dep_a/f.ex"), "x\n")
    bin = Path.join(ctx.root, "bin")
    marker = Path.join(ctx.root, "MIX_RAN")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "mix"), "#!/bin/sh\necho \"$@\" >> #{marker}\n")
    File.chmod!(Path.join(bin, "mix"), 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    Map.put(ctx, :marker, marker)
  end

  test "the default clone seeds deps and runs deps.get (the control)", ctx do
    assert {:ok, path} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone)
    assert File.exists?(Path.join(path, "deps/dep_a/f.ex"))
    assert File.exists?(ctx.marker)
  end

  test "seed: false builds the clone without seeding deps or fetching them", ctx do
    assert {:ok, path} =
             Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone, seed: false)

    assert File.read!(Path.join(path, "lib/a.ex")) == "a\n"
    refute File.exists?(Path.join(path, "deps"))
    refute File.exists?(ctx.marker)
    assert git!(path, ["status", "--porcelain"]) == ""
    assert Worktree.seeded_paths(path) == []
  end

  test "seed: false applies to attach/2 too", ctx do
    {:ok, _} = Worktree.create(ctx.checkout, @branch, "main", layout: :private_clone, seed: false)
    path = Worktree.worktree_path(@branch)
    :ok = Arbiter.Worker.PrivateClone.remove(path)

    assert {:ok, path} =
             Worktree.attach(ctx.checkout, @branch,
               layout: :private_clone,
               base: "main",
               seed: false
             )

    refute File.exists?(Path.join(path, "deps"))
    refute File.exists?(ctx.marker)
  end
end
