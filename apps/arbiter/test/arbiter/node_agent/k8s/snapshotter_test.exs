defmodule Arbiter.NodeAgent.K8s.SnapshotterTest do
  @moduledoc """
  bd-g9sh0j: the pod's `snapshotter` (`priv/k8s_pod/snapshotter`) packages the worktree
  that comes back to the primary. Its `take_snapshot` function is run here against a
  real repo, with the upload stubbed out, and the snapshot it bundles is read back.

  The regression: the snapshot was built from an *empty* index, and the pod's
  `info/exclude` names `.arbiter/`, so `git add -A` skipped the tracked
  `.arbiter/Containerfile` and the primary read it as deleted (a false commit-gate trip).
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PodRuntimeHarness, as: H

  @moduletag :tmp_dir

  @run "r1"
  @branch "arbiter/run"

  # The functions from `ref_sha` to just before `upload_transcripts`, so the real
  # `take_snapshot` runs and the daemon loop and its network calls do not.
  defp functions do
    text = File.read!(H.script("snapshotter"))
    [_, from_ref_sha] = String.split(text, "# -- the tree's refs, read as files", parts: 2)
    [body, _] = String.split(from_ref_sha, "# The CLI's transcripts", parts: 2)
    body |> String.split("\n", parts: 2) |> List.last()
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp worktree!(tmp, exclude) do
    wt = Path.join(tmp, "wt")
    File.mkdir_p!(wt)
    git!(wt, ["init", "-q", "-b", @branch])
    git!(wt, ["config", "user.email", "t@example.com"])
    git!(wt, ["config", "user.name", "t"])
    File.mkdir_p!(Path.join(wt, ".arbiter"))
    File.write!(Path.join(wt, ".arbiter/Containerfile"), "FROM scratch\n")
    File.write!(Path.join(wt, "README.md"), "hi\n")
    git!(wt, ["add", "-f", "."])
    git!(wt, ["commit", "-q", "-m", "base"])
    File.write!(Path.join(wt, ".git/info/exclude"), exclude)
    # what the pod has on disk beside the tracked files
    File.write!(Path.join(wt, ".arbiter/INBOX"), "direction\n")
    File.write!(Path.join(wt, "work.txt"), "work\n")
    wt
  end

  defp snapshot_files!(tmp, wt) do
    out = Path.join(tmp, "out.bundle")
    script = Path.join(tmp, "snap.sh")

    File.write!(script, """
    set -u
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
    wt='#{wt}'
    run=#{@run}
    branch=#{@branch}
    known=
    untracked_cap=50000000
    work='#{tmp}/work'
    mkdir -p "$work"
    say() { :; }
    #{functions()}
    put_retry() { cp "$1" '#{out}'; }
    take_snapshot 1
    """)

    {log, status} =
      System.cmd(H.shell(), [script], stderr_to_stdout: true, env: [{"TMPDIR", tmp}])

    assert status == 0, log

    verify = Path.join(tmp, "verify")
    File.mkdir_p!(verify)
    git!(verify, ["init", "-q"])
    git!(verify, ["fetch", "-q", out, "refs/arbiter/snapshot/#{@run}:refs/snap"])
    git!(verify, ["ls-tree", "-r", "--name-only", "refs/snap"]) |> String.split("\n", trim: true)
  end

  for {label, exclude} <- [
        {"the pod exclude with the Containerfile negation",
         ".arbiter/*\n!.arbiter/Containerfile\n"},
        {"a bare .arbiter/ exclude", ".arbiter/\n"}
      ] do
    test "the snapshot keeps a tracked .arbiter/Containerfile under #{label}", %{tmp_dir: tmp} do
      wt = worktree!(tmp, unquote(exclude))
      files = snapshot_files!(tmp, wt)

      assert ".arbiter/Containerfile" in files
      assert "work.txt" in files
      refute ".arbiter/INBOX" in files
    end
  end
end
