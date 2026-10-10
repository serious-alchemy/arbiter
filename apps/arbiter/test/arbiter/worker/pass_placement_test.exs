defmodule Arbiter.Worker.PassPlacementTest do
  @moduledoc """
  bd-bg87oz — what a pass placed on a node is seeded with. A fix round, a CI fix
  pass or a conflict pass writes commits, so the node's shadow clone must start
  from the ticket's branch at its CURRENT `origin` head and `origin/<target>` at
  the forge tip: never the stale refs the home clone (or the main repo behind it)
  last saw (bd-cccm1k, bd-4axlg0). Real git, a real forge.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Nodes.Checkout, as: NodeCheckout
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.PassPlacement
  alias Arbiter.Worker.PrivateClone

  import GitFixture, only: [git!: 2, commit!: 3]

  @branch "feature/bd-pass-seed"

  setup do
    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n", "a.txt" => "a\n"})

    # The PR branch, pushed once by the implementer, then cut as a private clone
    # (what the pass's `Worktree.attach/3` returns).
    git!(ctx.checkout, ["checkout", "-q", "-b", @branch])
    commit!(ctx.checkout, %{"feature.txt" => "v1\n"}, "feature v1")
    git!(ctx.checkout, ["push", "-q", "origin", @branch])
    git!(ctx.checkout, ["checkout", "-q", "main"])

    {:ok, clone} = PrivateClone.attach(ctx.checkout, @branch, "main")
    Map.put(ctx, :clone, clone)
  end

  # Someone else moves the forge on: a commit to the PR branch and one to main,
  # neither of which the checkout or the clone has fetched.
  defp third_party_push!(ctx) do
    git!(ctx.seed, ["fetch", "-q", "origin"])
    git!(ctx.seed, ["checkout", "-q", "-B", @branch, "origin/" <> @branch])
    branch_head = commit!(ctx.seed, %{"feature.txt" => "v2\n"}, "third party on the branch")
    git!(ctx.seed, ["push", "-q", "origin", @branch])

    git!(ctx.seed, ["checkout", "-q", "main"])
    main_tip = commit!(ctx.seed, %{"a.txt" => "a2\n"}, "main moved")
    git!(ctx.seed, ["push", "-q", "origin", "main"])

    {branch_head, main_tip}
  end

  describe "seed/3" do
    test "moves a stale branch and a stale origin/<target> to what the forge has now", ctx do
      stale_head = git!(ctx.clone, ["rev-parse", "refs/heads/" <> @branch])
      {branch_head, main_tip} = third_party_push!(ctx)
      refute stale_head == branch_head

      # Nothing has fetched: the clone and the main repo both still see the old refs.
      refute git!(ctx.clone, ["rev-parse", "refs/remotes/origin/main"]) == main_tip

      assert {:ok, seed} = PassPlacement.seed(ctx.clone, @branch, "main")

      assert seed.remote_head == branch_head
      assert seed.target_tip == main_tip
      assert seed.alignment == :fast_forwarded

      assert git!(ctx.clone, ["rev-parse", "refs/heads/" <> @branch]) == branch_head
      assert git!(ctx.clone, ["rev-parse", "HEAD"]) == branch_head
      assert git!(ctx.clone, ["rev-parse", "refs/remotes/origin/main"]) == main_tip
      assert File.read!(Path.join(ctx.clone, "feature.txt")) == "v2\n"
    end

    test "an up-to-date clone is left as it is", ctx do
      head = git!(ctx.clone, ["rev-parse", "HEAD"])

      assert {:ok, %{remote_head: ^head, alignment: :equal}} =
               PassPlacement.seed(ctx.clone, @branch, "main")
    end

    test "a clone ahead of the forge keeps its commits, and the seed names the forge head",
         ctx do
      forge_head = git!(ctx.clone, ["rev-parse", "HEAD"])
      local = commit!(ctx.clone, %{"feature.txt" => "local\n"}, "unpushed fix")

      assert {:ok, seed} = PassPlacement.seed(ctx.clone, @branch, "main")

      assert seed.alignment == :ahead
      assert seed.remote_head == forge_head
      assert git!(ctx.clone, ["rev-parse", "HEAD"]) == local
    end

    test "a clone that diverged from the forge is refused, nothing is discarded", ctx do
      {branch_head, _main} = third_party_push!(ctx)
      local = commit!(ctx.clone, %{"other.txt" => "mine\n"}, "diverging local commit")

      assert {:error, {:seed_diverged, ^local, ^branch_head}} =
               PassPlacement.seed(ctx.clone, @branch, "main")

      assert git!(ctx.clone, ["rev-parse", "HEAD"]) == local
    end

    test "a branch the forge does not have cannot be seeded", ctx do
      git!(ctx.forge, ["update-ref", "-d", "refs/heads/" <> @branch])

      assert {:error, {:seed_fetch_failed, _}} = PassPlacement.seed(ctx.clone, @branch, "main")
    end
  end

  describe "a target that is not the workspace's merge base" do
    test "is what the node is seeded with as origin/<target>, at the forge's tip", ctx do
      target = "integration/x"

      # The pass merges into an integration branch of its own; a third party moves
      # it on after the clone was cut.
      git!(ctx.seed, ["checkout", "-q", "-b", target])
      commit!(ctx.seed, %{"int.txt" => "v1\n"}, "integration v1")
      git!(ctx.seed, ["push", "-q", "origin", target])
      {:ok, clone} = PrivateClone.attach(ctx.checkout, @branch, "main")
      tip = commit!(ctx.seed, %{"int.txt" => "v2\n"}, "integration v2")
      git!(ctx.seed, ["push", "-q", "origin", target])

      assert {:ok, %{target_tip: ^tip}} = PassPlacement.seed(clone, @branch, target)

      # What the production handoff (`ConflictResolver`/`FixPassDispatcher`/the gate ->
      # `ClaudeSession` -> `ContainerSpawn`) builds the node's checkout from: the
      # pass's target, not `merge.base` (unset here, so "main").
      assert {:ok, %{base: ^target} = checkout} =
               ContainerSpawn.remote_checkout([base_branch: target], clone, ctx.root)

      assert {:ok, %{base: "main"}} = ContainerSpawn.remote_checkout([], clone, ctx.root)

      dest = Path.join(ctx.root, "seed.bundle")

      assert {:ok, %{refs: refs}} =
               NodeCheckout.seed_bundle(clone,
                 run: "run-1",
                 branch: @branch,
                 base: checkout.base,
                 dest: dest
               )

      assert refs["refs/remotes/origin/" <> target] == tip
    end
  end
end
