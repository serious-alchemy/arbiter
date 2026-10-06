defmodule Arbiter.Spike.BundleRoundtripTest do
  @moduledoc """
  RW2 spike (bd-6tx1xv), docs/design/remote-workers.md **U7**: the §9 checkout
  sync, exercised with plain `git` on throwaway repos. **Prototype, not product
  code.** Excluded by default: `mix test --include spike_rw <this file>`.

  Pipeline under test (§9): on the node, snapshot the shadow with a temporary
  index -> `git bundle create` with `^<known>` prerequisites -> on the primary,
  `git bundle verify`, `list-heads` allowlist, fetch into a throwaway bare repo
  with `fetch.fsckObjects` -> inspect -> hand off.
  """
  use ExUnit.Case, async: false

  @moduletag :spike_rw
  @moduletag :tmp_dir

  defp git!(dir, args, env \\ []) do
    case System.cmd("git", args,
           cd: dir,
           env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}] ++ env,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim_trailing(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} (#{code}) in #{dir}:\n#{out}")
    end
  end

  defp git(dir, args, env \\ []) do
    System.cmd("git", args,
      cd: dir,
      env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}] ++ env,
      stderr_to_stdout: true
    )
  end

  defp init_repo(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "spike@example.com"])
    git!(dir, ["config", "user.name", "spike"])
    dir
  end

  defp commit_all(dir, msg) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", msg])
    git!(dir, ["rev-parse", "HEAD"])
  end

  defp modes(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        not String.contains?(path, "/.git/"),
        not String.ends_with?(path, "/.git"),
        into: %{} do
      {:ok, st} = File.lstat(path)
      rel = Path.relative_to(path, dir)

      case st.type do
        :symlink -> {rel, {:symlink, File.read_link!(path)}}
        :regular -> {rel, {:file, Bitwise.band(st.mode, 0o111) != 0}}
        :directory -> {rel, :dir}
      end
    end
  end

  defp quarantine(dir) do
    q = Path.join(dir, "quarantine.git")
    git!(dir, ["init", "-q", "--bare", q])
    git!(q, ["config", "fetch.fsckObjects", "true"])
    git!(q, ["config", "transfer.fsckObjects", "true"])
    git!(q, ["config", "core.hooksPath", "/dev/null"])
    q
  end

  defp snapshot!(shadow, run) do
    idx = Path.join(shadow, ".git/spike-index")
    env = [{"GIT_INDEX_FILE", idx}]
    git!(shadow, ["add", "-A"], env)
    tree = git!(shadow, ["write-tree"], env)
    snap = git!(shadow, ["commit-tree", "-p", "HEAD", "-m", "snapshot", tree], env)
    git!(shadow, ["update-ref", "refs/arbiter/snapshot/#{run}", snap])
    File.rm!(idx)
    snap
  end

  test "exec bits, symlinks, deletions, renames and untracked files survive the thin-bundle round trip",
       %{tmp_dir: tmp} do
    # --- the primary's home clone at the seed point ---------------------------
    shadow = init_repo(Path.join(tmp, "shadow"))
    File.mkdir_p!(Path.join(shadow, "bin"))
    File.mkdir_p!(Path.join(shadow, "lib"))
    File.write!(Path.join(shadow, "bin/run.sh"), "#!/bin/sh\necho hi\n")
    File.chmod!(Path.join(shadow, "bin/run.sh"), 0o755)

    File.write!(
      Path.join(shadow, "lib/a.txt"),
      Enum.map_join(1..40, "", &"content line #{&1} of the file to rename\n")
    )

    File.write!(Path.join(shadow, "lib/gone.txt"), "gone\n")
    File.write!(Path.join(shadow, "lib/keep.txt"), "keep\n")
    File.write!(Path.join(shadow, "weird name é.txt"), "unicode + space\n")
    File.ln_s!("lib/a.txt", Path.join(shadow, "link.txt"))
    File.ln_s!("/etc/passwd", Path.join(shadow, "abs-link"))
    File.ln_s!("nonexistent", Path.join(shadow, "dangling"))
    base = commit_all(shadow, "base")

    # --- what the run does in the shadow ---------------------------------------
    git!(shadow, ["checkout", "-q", "-b", "arbiter/run"])
    git!(shadow, ["rm", "-q", "lib/gone.txt"])
    git!(shadow, ["mv", "lib/a.txt", "lib/renamed.txt"])

    File.write!(
      Path.join(shadow, "lib/renamed.txt"),
      String.replace(File.read!(Path.join(shadow, "lib/renamed.txt")), "line 1 ", "line ONE ")
    )

    File.chmod!(Path.join(shadow, "bin/run.sh"), 0o644)
    File.chmod!(Path.join(shadow, "lib/keep.txt"), 0o755)
    File.rm!(Path.join(shadow, "link.txt"))
    File.ln_s!("lib/renamed.txt", Path.join(shadow, "link.txt"))
    File.write!(Path.join(shadow, "lib/new.txt"), "new\n")
    commit_all(shadow, "run commit")
    # uncommitted + untracked work at the moment of the snapshot
    File.write!(Path.join(shadow, "lib/new.txt"), "new, then edited and uncommitted\n")
    File.write!(Path.join(shadow, "untracked.sh"), "#!/bin/sh\n")
    File.chmod!(Path.join(shadow, "untracked.sh"), 0o755)
    File.mkdir_p!(Path.join(shadow, "empty_dir"))
    snap = snapshot!(shadow, "r1")

    expected = modes(shadow)

    # --- node side: thin bundle against what the primary already has -----------
    bundle = Path.join(tmp, "thin.bundle")

    git!(shadow, [
      "bundle",
      "create",
      bundle,
      "arbiter/run",
      "refs/arbiter/snapshot/r1",
      "^" <> base
    ])

    # --- primary side: quarantine, allowlist, fetch with fsck -------------------
    q = quarantine(tmp)
    git!(q, ["fetch", "-q", shadow, "+refs/heads/main:refs/heads/main"])
    git!(q, ["bundle", "verify", bundle])

    heads =
      git!(q, ["bundle", "list-heads", bundle])
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.split(" ", parts: 2) |> List.last()))

    assert Enum.sort(heads) == ["refs/arbiter/snapshot/r1", "refs/heads/arbiter/run"]

    git!(q, [
      "fetch",
      "-q",
      bundle,
      "+refs/heads/arbiter/run:refs/heads/arbiter/run",
      "+refs/arbiter/snapshot/r1:refs/arbiter/snapshot/r1"
    ])

    assert git!(q, ["rev-parse", "refs/arbiter/snapshot/r1"]) == snap
    # An explicit fsck pass after the fetch is clean too.
    assert {_, 0} = git(q, ["fsck", "--strict"])

    # --- hand-off: materialise the snapshot like read-tree -u --reset -----------
    home = Path.join(tmp, "home")
    git!(tmp, ["clone", "-q", q, home])

    git!(home, [
      "fetch",
      "-q",
      "--no-tags",
      q,
      "+refs/arbiter/snapshot/r1:refs/arbiter/snapshot/r1"
    ])

    git!(home, ["checkout", "-q", "arbiter/run"])
    git!(home, ["read-tree", "-u", "--reset", "refs/arbiter/snapshot/r1"])
    git!(home, ["reset", "--mixed", "arbiter/run"])

    got = modes(home) |> Map.delete("empty_dir")
    want = Map.delete(expected, "empty_dir")
    assert got == want

    # deletions arrive as deletions, the rename as a rename
    refute File.exists?(Path.join(home, "lib/gone.txt"))
    diff = git!(home, ["diff", "--raw", "-M", "origin/main", "arbiter/run"])
    assert diff =~ ~r/R\d+\s+lib\/a\.txt\s+lib\/renamed\.txt/
    # the uncommitted edit reads as uncommitted after the handoff
    assert git!(home, ["status", "--porcelain"]) =~ "lib/new.txt"
    assert git!(home, ["status", "--porcelain"]) =~ "untracked.sh"
    # absolute and dangling symlinks were carried verbatim, not followed
    assert got["abs-link"] == {:symlink, "/etc/passwd"}
    assert got["dangling"] == {:symlink, "nonexistent"}
    # known gap: an empty directory is not representable in git (the design's snapshot drops it)
    refute File.exists?(Path.join(home, "empty_dir"))
  end

  test "a thin bundle needs its prerequisites; the primary can detect that and fall back to a full bundle",
       %{tmp_dir: tmp} do
    repo = init_repo(Path.join(tmp, "repo"))
    File.write!(Path.join(repo, "f"), "1\n")
    base = commit_all(repo, "base")
    File.write!(Path.join(repo, "f"), "2\n")
    commit_all(repo, "next")

    thin = Path.join(tmp, "thin.bundle")
    git!(repo, ["bundle", "create", thin, "main", "^" <> base])

    empty = Path.join(tmp, "empty.git")
    git!(tmp, ["init", "-q", "--bare", empty])
    assert {out, code} = git(empty, ["bundle", "verify", thin])
    assert code != 0
    assert out =~ "prerequisite"
    assert {_, code} = git(empty, ["fetch", thin, "main:main"])
    assert code != 0

    # With the base present (the node's `have`), the same bundle verifies and fetches.
    git!(empty, ["fetch", "-q", repo, "+#{base}:refs/heads/seed"])
    git!(empty, ["bundle", "verify", thin])
    git!(empty, ["fetch", "-q", thin, "+refs/heads/main:refs/heads/main"])
    assert git!(empty, ["rev-parse", "main"]) == git!(repo, ["rev-parse", "main"])
  end

  # Build a commit whose tree contains `.git/config` -- the classic checkout-time
  # RCE shape -- without `git add` (which refuses). Objects are written raw.
  defp evil_dotgit_commit(repo, tmp) do
    write_object = fn type, content ->
      path = Path.join(tmp, "raw-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      git!(repo, ["hash-object", "-w", "-t", type, "--literally", path])
    end

    raw = &Base.decode16!(&1, case: :lower)
    blob = write_object.("blob", "[core]\n\tfsmonitor = touch /tmp/pwned\n")
    inner = write_object.("tree", "100644 config\0" <> raw.(blob))
    outer = write_object.("tree", "40000 .git\0" <> raw.(inner))
    commit = git!(repo, ["commit-tree", "-m", "evil", outer])
    git!(repo, ["update-ref", "refs/heads/evil", commit])
    commit
  end

  test "fetch.fsckObjects applies to a bundle fetch and rejects a tree containing .git", %{
    tmp_dir: tmp
  } do
    repo = init_repo(Path.join(tmp, "evilrepo"))
    File.write!(Path.join(repo, "f"), "x\n")
    commit_all(repo, "base")
    evil = evil_dotgit_commit(repo, tmp)

    bundle = Path.join(tmp, "evil.bundle")
    git!(repo, ["bundle", "create", bundle, "evil"])
    # bundle verify checks connectivity, not content: it is NOT the gate.
    git!(tmp, ["init", "-q", "--bare", Path.join(tmp, "v.git")])
    assert {_, 0} = git(Path.join(tmp, "v.git"), ["bundle", "verify", bundle])

    # Control: without fsckObjects the object is accepted into the quarantine.
    lax = Path.join(tmp, "lax.git")
    git!(tmp, ["init", "-q", "--bare", lax])
    assert {_, 0} = git(lax, ["fetch", "-q", bundle, "+refs/heads/evil:refs/heads/evil"])
    assert git!(lax, ["rev-parse", "evil"]) == evil

    # The design's quarantine: fsckObjects on -> the fetch fails and no ref lands.
    strict = quarantine(tmp)
    assert {out, code} = git(strict, ["fetch", "-q", bundle, "+refs/heads/evil:refs/heads/evil"])
    assert code != 0
    assert out =~ ~r/hasDotgit|\.git|fsck/i
    assert {_, 1} = git(strict, ["rev-parse", "--verify", "-q", "refs/heads/evil"])
  end

  test "list-heads lets the primary reject a bundle that carries refs outside the allowlist", %{
    tmp_dir: tmp
  } do
    repo = init_repo(Path.join(tmp, "r"))
    File.write!(Path.join(repo, "f"), "1\n")
    commit_all(repo, "base")
    git!(repo, ["branch", "other"])
    git!(repo, ["update-ref", "refs/tags/sneaky", "HEAD"])
    bundle = Path.join(tmp, "multi.bundle")
    git!(repo, ["bundle", "create", bundle, "main", "other", "refs/tags/sneaky"])

    allowed = MapSet.new(["refs/heads/main"])

    heads =
      git!(tmp, ["bundle", "list-heads", bundle])
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.split(" ", parts: 2) |> List.last()))

    assert Enum.sort(heads) == ["refs/heads/main", "refs/heads/other", "refs/tags/sneaky"]
    assert Enum.reject(heads, &MapSet.member?(allowed, &1)) != []

    # A refspec-limited fetch imports only what is named (defence in depth) -- but ONLY with
    # --no-tags: without it git's tag auto-following imports refs/tags/sneaky anyway.
    q = quarantine(tmp)
    git!(q, ["fetch", "-q", bundle, "+refs/heads/main:refs/heads/main"])
    assert git!(q, ["for-each-ref", "--format=%(refname)"]) == "refs/heads/main\nrefs/tags/sneaky"
    q2 = Path.join(tmp, "quarantine2.git")
    git!(tmp, ["init", "-q", "--bare", q2])
    git!(q2, ["fetch", "-q", "--no-tags", bundle, "+refs/heads/main:refs/heads/main"])
    assert git!(q2, ["for-each-ref", "--format=%(refname)"]) == "refs/heads/main"
  end

  test "submodules and LFS are detectable from the quarantine without a checkout", %{tmp_dir: tmp} do
    repo = init_repo(Path.join(tmp, "sub"))
    File.write!(Path.join(repo, "f"), "x\n")
    File.write!(Path.join(repo, ".gitattributes"), "*.bin filter=lfs diff=lfs merge=lfs -text\n")

    File.write!(
      Path.join(repo, "big.bin"),
      "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12345\n"
    )

    git!(repo, ["add", "-A"])
    # a gitlink (submodule) entry, added without a real submodule
    git!(repo, [
      "update-index",
      "--add",
      "--cacheinfo",
      "160000,#{String.duplicate("a", 40)},vendor/dep"
    ])

    git!(repo, ["commit", "-q", "-m", "with submodule + lfs"])
    bundle = Path.join(tmp, "s.bundle")
    git!(repo, ["bundle", "create", bundle, "main"])

    q = Path.join(tmp, "q.git")
    git!(tmp, ["init", "-q", "--bare", q])
    git!(q, ["config", "fetch.fsckObjects", "false"])
    # a gitlink needs no object in the repo, but a strict connectivity fetch would still pass:
    {_, code} = git(q, ["fetch", "-q", bundle, "+refs/heads/main:refs/heads/main"])
    assert code == 0

    tree = git!(q, ["ls-tree", "-r", "main"])
    assert tree =~ ~r/^160000 commit /m
    assert git!(q, ["show", "main:.gitattributes"]) =~ "filter=lfs"
    assert git!(q, ["show", "main:big.bin"]) =~ "git-lfs.github.com/spec/v1"
  end
end
