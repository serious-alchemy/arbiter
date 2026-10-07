defmodule Arbiter.Nodes.CheckoutTest do
  @moduledoc """
  RW11 (`docs/design/remote-workers.md` §9): seed bundle -> shadow clone -> snapshot
  bundle -> quarantine ingest -> home clone, on fixture repos with plain `git`.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.CheckoutFixture

  alias Arbiter.NodeAgent.Checkout, as: Node
  alias Arbiter.Nodes.Checkout

  @moduletag :tmp_dir

  @run "r1"
  @branch "arbiter/run"

  setup %{tmp_dir: tmp} do
    %{home: home, base: base} = home!(tmp)
    node = Path.join(tmp, "node")
    File.mkdir_p!(node)

    ctx = %{
      run: @run,
      branch: @branch,
      base: "main",
      home: home,
      scratch: Path.join(tmp, "scratch")
    }

    %{home: home, base: base, node: node, ctx: ctx, tmp: tmp}
  end

  # The node half: pull the seed bundle for `home`, build the shadow.
  defp seed!(%{home: home, node: node, tmp: tmp}, have \\ []) do
    {:ok, seed} =
      Checkout.seed_bundle(home,
        run: @run,
        branch: @branch,
        base: "main",
        have: have,
        dest: Path.join(tmp, "seed-#{System.unique_integer([:positive])}.bundle")
      )

    shadow = Path.join(node, "shadow")

    {:ok, info} =
      Node.seed(%{
        store: Path.join(node, "repos/r.git"),
        shadow: shadow,
        bundle: seed.path,
        run: @run,
        branch: @branch,
        base: "main"
      })

    %{seed: seed, shadow: shadow, info: info}
  end

  defp package!(shadow, info, tmp, opts \\ []) do
    dest = Path.join(tmp, "up-#{System.unique_integer([:positive])}.bundle")

    Node.package(
      Map.merge(
        %{shadow: shadow, run: @run, branch: @branch, known: info.known, dest: dest},
        Map.new(opts)
      )
    )
  end

  defp edit_shadow!(shadow) do
    git!(shadow, ["rm", "-q", "lib/gone.txt"])
    git!(shadow, ["mv", "lib/a.txt", "lib/renamed.txt"])
    f = Path.join(shadow, "lib/renamed.txt")
    File.write!(f, String.replace(File.read!(f), "line 1 ", "line ONE "))
    File.chmod!(Path.join(shadow, "bin/run.sh"), 0o644)
    File.chmod!(Path.join(shadow, "lib/keep.txt"), 0o755)
    File.rm!(Path.join(shadow, "link.txt"))
    File.ln_s!("lib/renamed.txt", Path.join(shadow, "link.txt"))
    File.write!(Path.join(shadow, "lib/new.txt"), "new\n")
    git!(shadow, ["add", "-A"])
    git!(shadow, ["commit", "-q", "-m", "run commit"])
    # uncommitted + untracked work at the moment of the snapshot
    File.write!(Path.join(shadow, "lib/new.txt"), "new, then edited and uncommitted\n")
    File.write!(Path.join(shadow, "untracked.sh"), "#!/bin/sh\n")
    File.chmod!(Path.join(shadow, "untracked.sh"), 0o755)
  end

  describe "round trip" do
    test "exec bits, symlinks, deletions, renames and uncommitted work survive", c do
      %{shadow: shadow, info: info} = seed!(c)

      # the shadow is what the primary's home was
      assert modes(shadow) == modes(c.home)

      edit_shadow!(shadow)
      expected = modes(shadow)
      assert {:ok, up} = package!(shadow, info, c.tmp)

      assert {:ok, result} = Checkout.ingest(up.path, c.ctx)

      assert modes(c.home) == expected
      assert modes(c.home)["abs-link"] == {:symlink, "/etc/passwd"}
      assert modes(c.home)["dangling"] == {:symlink, "nonexistent"}
      refute File.exists?(Path.join(c.home, "lib/gone.txt"))

      diff = git!(c.home, ["diff", "--raw", "-M", c.base, @branch])
      assert diff =~ ~r/R\d+\s+lib\/a\.txt\s+lib\/renamed\.txt/

      # the committed work is the branch tip; the rest reads as uncommitted
      assert git!(c.home, ["rev-parse", @branch]) == result.head
      status = git!(c.home, ["status", "--porcelain"])
      assert status =~ "lib/new.txt"
      assert status =~ "untracked.sh"
      refute status =~ "lib/renamed.txt"
      assert result.status_hash == :crypto.hash(:sha256, status) |> Base.encode16(case: :lower)
    end

    test "a run with no commits and no changes ingests as a no-op", c do
      %{shadow: shadow, info: info} = seed!(c)
      assert {:ok, up} = package!(shadow, info, c.tmp)
      assert {:ok, result} = Checkout.ingest(up.path, c.ctx)
      assert result.head == c.base
      assert git!(c.home, ["status", "--porcelain"]) == ""
    end

    test "the upload is thin: it needs the objects the primary already has", c do
      %{shadow: shadow, info: info} = seed!(c)
      edit_shadow!(shadow)
      {:ok, up} = package!(shadow, info, c.tmp)

      empty = Path.join(c.tmp, "empty.git")
      git!(c.tmp, ["init", "-q", "--bare", empty])
      assert {out, code} = git(empty, ["bundle", "verify", up.path])
      assert code != 0
      assert out =~ "prerequisite"
    end
  end

  describe "seed bundle" do
    test "is thin against `have` and falls back to full for unknown shas", c do
      full = seed!(c)
      assert full.seed.thin? == false

      File.write!(Path.join(c.home, "lib/more.txt"), "more\n")
      tip = commit_all!(c.home, "more")

      # the same node, which already holds the base
      thin = seed!(c, [c.base])

      assert thin.seed.thin?
      assert thin.seed.bytes < full.seed.bytes
      assert thin.seed.refs["refs/heads/#{@branch}"] == tip

      unknown = String.duplicate("a", 40)
      fallback = seed!(%{c | node: Path.join(c.tmp, "node3")}, [unknown])
      refute fallback.seed.thin?
    end

    test "when the node already has every tip it still gets a usable bundle", c do
      assert %{seed: %{thin?: false, refs: refs}} = seed!(c, [c.base])
      assert refs["refs/heads/#{@branch}"] == c.base
    end
  end

  describe "ingest quarantine" do
    test "executes no hooks, in the quarantine or the home clone", c do
      marker = Path.join(c.tmp, "HOOK_RAN")

      for hook <- ~w(reference-transaction post-checkout post-merge post-index-change pre-auto-gc) do
        path = Path.join(c.home, ".git/hooks/#{hook}")
        File.write!(path, "#!/bin/sh\necho #{hook} >> #{marker}\n")
        File.chmod!(path, 0o755)
      end

      %{shadow: shadow, info: info} = seed!(c)
      edit_shadow!(shadow)
      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:ok, _} = Checkout.ingest(up.path, c.ctx)
      refute File.exists?(marker)
    end

    test "strips excluded paths from the snapshot on the primary, whatever the node excluded",
         c do
      %{shadow: shadow, info: info} = seed!(c)
      # a compromised node edits its own exclude file, so the node-side filter hides nothing
      File.write!(Path.join(shadow, ".git/info/exclude"), "")
      File.mkdir_p!(Path.join(shadow, "deps/x"))
      File.write!(Path.join(shadow, "deps/x/mod.ex"), "injected\n")
      File.write!(Path.join(shadow, ".mcp.json"), ~s({"mcpServers":{}}))
      File.mkdir_p!(Path.join(shadow, ".codex"))
      File.write!(Path.join(shadow, ".codex/config.toml"), "x\n")
      File.write!(Path.join(shadow, "lib/real.txt"), "real\n")

      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:ok, result} = Checkout.ingest(up.path, c.ctx)

      assert File.exists?(Path.join(c.home, "lib/real.txt"))
      refute File.exists?(Path.join(c.home, "deps"))
      refute File.exists?(Path.join(c.home, ".mcp.json"))
      refute File.exists?(Path.join(c.home, ".codex"))
      assert Enum.sort(result.filtered) == [".codex/config.toml", ".mcp.json", "deps/x/mod.ex"]
      # nor does the checkpoint ref keep them
      refute git!(c.home, ["ls-tree", "-r", "--name-only", result.snapshot]) =~ "deps/x"
    end

    test "a path the primary's own base tracks is not stripped when unchanged", c do
      # the base branch itself tracks `.mcp.json`
      git!(c.home, ["checkout", "-q", "main"])
      File.write!(Path.join(c.home, ".mcp.json"), "{}\n")
      base = commit_all!(c.home, "tracked mcp")
      git!(c.home, ["checkout", "-q", @branch])
      git!(c.home, ["merge", "-q", "--ff-only", "main"])
      c = %{c | base: base}
      %{shadow: shadow, info: info} = seed!(c)
      File.write!(Path.join(shadow, "lib/real.txt"), "real\n")
      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:ok, %{filtered: []}} = Checkout.ingest(up.path, c.ctx)
      assert File.exists?(Path.join(c.home, ".mcp.json"))
    end

    test "run-specific seeded paths are stripped too", c do
      %{shadow: shadow, info: info} = seed!(c)
      File.mkdir_p!(Path.join(shadow, "priv/plts"))
      File.write!(Path.join(shadow, "priv/plts/x.plt"), "plt\n")
      {:ok, up} = package!(shadow, info, c.tmp)
      ctx = Map.put(c.ctx, :seeded_paths, ["priv/plts"])
      assert {:ok, %{filtered: ["priv/plts/x.plt"]}} = Checkout.ingest(up.path, ctx)
      refute File.exists?(Path.join(c.home, "priv/plts"))
    end

    test "rejects a tree that carries .git/config or hooks (fsck is the gate)", c do
      for parts <- [
            [".git", "config"],
            [".git", "hooks", "pre-commit"],
            ["sub", ".git", "config"]
          ] do
        bundle = evil_bundle!(c, parts)
        assert {:error, {:fsck, _}} = Checkout.ingest(bundle, c.ctx)
        # nothing landed in the home clone
        assert git!(c.home, ["rev-parse", @branch]) == c.base
        assert git!(c.home, ["for-each-ref", "refs/arbiter"]) == ""
      end
    end

    test "rejects refs outside the allowlist, tags included", c do
      %{shadow: shadow, info: info} = seed!(c)
      File.write!(Path.join(shadow, "f"), "x\n")
      git!(shadow, ["add", "-A"])
      git!(shadow, ["commit", "-q", "-m", "x"])
      _ = info

      for extra <- ["refs/heads/other", "refs/tags/sneaky", "refs/remotes/origin/evil"] do
        git!(shadow, ["update-ref", extra, "HEAD"])
        git!(shadow, ["update-ref", "refs/arbiter/snapshot/#{@run}", "HEAD"])
        bundle = Path.join(c.tmp, "extra-#{String.replace(extra, "/", "_")}.bundle")
        snap = "refs/arbiter/snapshot/#{@run}"
        git!(shadow, ["bundle", "create", bundle, @branch, snap, extra, "^" <> c.base])
        assert {:error, {:ref_not_allowed, ^extra}} = Checkout.ingest(bundle, c.ctx)
      end
    end

    test "rejects a snapshot that is not a child of the run branch tip", c do
      %{shadow: shadow, info: info} = seed!(c)
      File.write!(Path.join(shadow, "f"), "x\n")
      git!(shadow, ["add", "-A"])
      git!(shadow, ["commit", "-q", "-m", "tip"])
      # a snapshot whose parent is an unrelated root commit
      stray = raw_commit!(shadow, ["ok.txt"], "x\n", nil, c.tmp)
      git!(shadow, ["update-ref", "refs/arbiter/snapshot/#{@run}", stray])
      bundle = Path.join(c.tmp, "stray.bundle")

      git!(shadow, [
        "bundle",
        "create",
        bundle,
        @branch,
        "refs/arbiter/snapshot/#{@run}",
        "^" <> hd(info.known)
      ])

      assert {:error, :snapshot_not_on_branch} = Checkout.ingest(bundle, c.ctx)
    end

    test "enforces the bundle size cap", c do
      %{shadow: shadow, info: info} = seed!(c)
      File.write!(Path.join(shadow, "big.txt"), :crypto.strong_rand_bytes(20_000))
      {:ok, up} = package!(shadow, info, c.tmp)

      assert {:error, {:too_large, _}} =
               Checkout.ingest(up.path, Map.put(c.ctx, :max_bytes, 5_000))

      assert {:ok, _} = Checkout.ingest(up.path, Map.put(c.ctx, :max_bytes, 5_000_000))
    end

    test "enforces the object-count cap", c do
      %{shadow: shadow, info: info} = seed!(c)
      for i <- 1..30, do: File.write!(Path.join(shadow, "f#{i}.txt"), "file #{i}\n")
      {:ok, up} = package!(shadow, info, c.tmp)

      assert {:error, {:too_many_objects, _}} =
               Checkout.ingest(up.path, Map.put(c.ctx, :max_objects, 10))
    end

    test "a bundle whose prerequisites the primary lacks is refused", c do
      %{shadow: shadow, info: info} = seed!(c)
      File.write!(Path.join(shadow, "f"), "x\n")
      {:ok, up} = package!(shadow, info, c.tmp)
      other = init_repo!(Path.join(c.tmp, "other"))
      File.write!(Path.join(other, "unrelated"), "x\n")
      commit_all!(other, "unrelated")
      git!(other, ["checkout", "-q", "-b", @branch])
      ctx = %{c.ctx | home: other}
      assert {:error, {:prerequisites_missing, _}} = Checkout.ingest(up.path, ctx)
    end
  end

  describe "vetoes" do
    test "a submodule (gitlink) in the snapshot is vetoed", c do
      %{shadow: shadow, info: info} = seed!(c)

      git!(shadow, [
        "update-index",
        "--add",
        "--cacheinfo",
        "160000,#{String.duplicate("a", 40)},vendor/dep"
      ])

      git!(shadow, ["commit", "-q", "-m", "submodule"])
      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:error, {:veto, :submodule, _}} = Checkout.ingest(up.path, c.ctx)
      assert git!(c.home, ["rev-parse", @branch]) == c.base
    end

    test ".gitmodules is vetoed", c do
      %{shadow: shadow, info: info} = seed!(c)

      File.write!(
        Path.join(shadow, ".gitmodules"),
        "[submodule \"x\"]\n\tpath = x\n\turl = ../x\n"
      )

      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:error, {:veto, :submodule, _}} = Checkout.ingest(up.path, c.ctx)
    end

    test "LFS: a filter=lfs attribute, or a pointer blob, is vetoed", c do
      %{shadow: shadow, info: info} = seed!(c)

      File.write!(
        Path.join(shadow, ".gitattributes"),
        "*.bin filter=lfs diff=lfs merge=lfs -text\n"
      )

      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:error, {:veto, :lfs, _}} = Checkout.ingest(up.path, c.ctx)

      File.rm!(Path.join(shadow, ".gitattributes"))

      File.write!(
        Path.join(shadow, "big.dat"),
        "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12345\n"
      )

      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:error, {:veto, :lfs, _}} = Checkout.ingest(up.path, c.ctx)
    end

    test "untracked files over the cap are vetoed on the node and again on the primary", c do
      %{shadow: shadow, info: info} = seed!(c)
      File.write!(Path.join(shadow, "huge.bin"), :binary.copy(<<0>>, 4_000))

      assert {:error, {:veto, :untracked_size, _}} =
               package!(shadow, info, c.tmp, max_untracked_bytes: 1_000)

      # a node that skips its own check is still refused by the primary
      {:ok, up} = package!(shadow, info, c.tmp)
      ctx = Map.put(c.ctx, :max_untracked_bytes, 1_000)
      assert {:error, {:veto, :untracked_size, _}} = Checkout.ingest(up.path, ctx)
      assert {:ok, _} = Checkout.ingest(up.path, Map.put(c.ctx, :max_untracked_bytes, 50_000_000))
    end

    test "Checkout.veto/2 is the placement check on a base ref", c do
      assert :ok = Checkout.veto(c.home, "main")
      File.write!(Path.join(c.home, ".gitattributes"), "*.bin filter=lfs\n")
      sha = commit_all!(c.home, "lfs")
      assert {:error, {:veto, :lfs, _}} = Checkout.veto(c.home, sha)
    end
  end

  describe "checkpoint" do
    test "a checkpoint is kept as a ref and can be restored into the home clone and a new shadow",
         c do
      %{shadow: shadow, info: info} = seed!(c)
      edit_shadow!(shadow)
      expected = modes(shadow)
      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:ok, %{checkpoint_ref: ref}} = Checkout.ingest(up.path, c.ctx)
      assert ref == "refs/arbiter/checkpoint/#{@run}"

      # the home clone is wiped back to the branch tip (a re-dispatch after the node was lost)
      git!(c.home, ["reset", "--hard", "-q"])
      git!(c.home, ["clean", "-fdq"])
      refute File.exists?(Path.join(c.home, "untracked.sh"))

      assert {:ok, _} = Checkout.restore(c.home, @run, @branch)
      assert modes(c.home) == expected
      assert git!(c.home, ["status", "--porcelain"]) =~ "untracked.sh"

      # a fresh node is seeded from the checkpoint: same tree, same uncommitted state
      fresh = seed!(%{c | node: Path.join(c.tmp, "node-fresh")})
      assert modes(fresh.shadow) == expected
      assert git!(fresh.shadow, ["status", "--porcelain"]) =~ "untracked.sh"
    end

    test "a later checkpoint drops files the earlier one added but never committed", c do
      %{shadow: shadow, info: info} = seed!(c)
      edit_shadow!(shadow)
      {:ok, up1} = package!(shadow, info, c.tmp)
      assert {:ok, _} = Checkout.ingest(up1.path, c.ctx)
      assert File.exists?(Path.join(c.home, "untracked.sh"))

      # the agent abandons its scratch file and the uncommitted edit, then checkpoints again
      File.rm!(Path.join(shadow, "untracked.sh"))
      git!(shadow, ["checkout", "--", "lib/new.txt"])
      expected = modes(shadow)
      {:ok, up2} = package!(shadow, info, c.tmp)
      assert {:ok, _} = Checkout.ingest(up2.path, c.ctx)

      refute File.exists?(Path.join(c.home, "untracked.sh"))
      assert modes(c.home) == expected
      assert git!(c.home, ["status", "--porcelain"]) == ""
    end

    test "restoring over the state the checkpoint already left is idempotent", c do
      %{shadow: shadow, info: info} = seed!(c)
      edit_shadow!(shadow)
      expected = modes(shadow)
      {:ok, up} = package!(shadow, info, c.tmp)
      assert {:ok, ingested} = Checkout.ingest(up.path, c.ctx)

      assert {:ok, restored} = Checkout.restore(c.home, @run, @branch)
      assert restored.status_hash == ingested.status_hash
      assert modes(c.home) == expected
    end
  end

  # -- helpers -----------------------------------------------------------------

  # A bundle whose snapshot commit (child of the run tip) holds `parts` as a path.
  defp evil_bundle!(c, parts) do
    %{shadow: shadow, info: _} =
      seed!(%{c | node: Path.join(c.tmp, "evil-node-#{System.unique_integer([:positive])}")})

    commit = raw_commit!(shadow, parts, "[core]\n\tfsmonitor = touch /tmp/pwned\n", c.base, c.tmp)
    git!(shadow, ["update-ref", "refs/arbiter/snapshot/#{@run}", commit])
    bundle = Path.join(c.tmp, "evil-#{System.unique_integer([:positive])}.bundle")
    git!(shadow, ["bundle", "create", bundle, "refs/arbiter/snapshot/#{@run}", "^" <> c.base])
    bundle
  end
end
