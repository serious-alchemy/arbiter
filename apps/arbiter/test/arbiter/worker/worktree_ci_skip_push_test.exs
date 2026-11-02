defmodule Arbiter.Worker.WorktreeCiSkipPushTest do
  @moduledoc """
  bd-4y9dno — a push for a merge-train MR that is not the head asks the forge not
  to start a pipeline: GitLab takes a push option (`-o ci.skip`), GitHub reads a
  `[skip ci]` marker in the head commit. Real git, a bare forge that advertises
  push options and records the ones it receives.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.Worktree

  import GitFixture, only: [git!: 2, commit!: 3]

  @branch "feature/bd-ci-skip"

  setup do
    fx = GitFixture.forge_and_checkout()
    git!(fx.forge, ["config", "receive.advertisePushOptions", "true"])

    log = Path.join(fx.root, "push-options.log")
    hook = Path.join([fx.forge, "hooks", "pre-receive"])

    File.write!(
      hook,
      "#!/bin/sh\necho \"opts=${GIT_PUSH_OPTION_COUNT:-0} ${GIT_PUSH_OPTION_0}\" >> #{log}\n"
    )

    File.chmod!(hook, 0o755)

    {:ok, clone} = Worktree.create(fx.checkout, @branch, "main", layout: :private_clone)
    git!(clone, ["config", "commit.gpgsign", "false"])
    Map.merge(fx, %{clone: clone, log: log})
  end

  defp received(log), do: if(File.exists?(log), do: File.read!(log) |> String.trim(), else: "")

  defp remote_subject(forge, branch), do: git!(forge, ["log", "-1", "--format=%B", branch])

  test "a push-option mechanism sends the option with the push", %{clone: clone, log: log} do
    commit!(clone, %{"lib/a.ex" => "a\n"}, "work")

    assert {:ok, _} =
             Worktree.push(clone, branch: @branch, ci_skip: {:push_option, "ci.skip"})

    assert received(log) == "opts=1 ci.skip"
  end

  test "no ci_skip sends no push option", %{clone: clone, log: log} do
    commit!(clone, %{"lib/a.ex" => "a\n"}, "work")
    assert {:ok, _} = Worktree.push(clone, branch: @branch)
    assert received(log) == "opts=0"
  end

  test "a commit-marker mechanism puts the marker on the unpushed tip", %{
    clone: clone,
    forge: forge
  } do
    commit!(clone, %{"lib/a.ex" => "a\n"}, "work")

    assert {:ok, _} =
             Worktree.push(clone, branch: @branch, ci_skip: {:commit_marker, "[skip ci]"})

    assert remote_subject(forge, @branch) =~ "[skip ci]"
    assert remote_subject(forge, @branch) =~ "work"
  end

  test "a commit-marker mechanism never rewrites a tip the remote already has", %{
    clone: clone,
    forge: forge
  } do
    sha = commit!(clone, %{"lib/a.ex" => "a\n"}, "work")
    assert {:ok, _} = Worktree.push(clone, branch: @branch)

    assert {:ok, _} =
             Worktree.push(clone, branch: @branch, ci_skip: {:commit_marker, "[skip ci]"})

    assert git!(forge, ["rev-parse", @branch]) == sha
    assert git!(clone, ["rev-parse", "HEAD"]) == sha
  end

  test "a tip that already carries the marker is left alone", %{clone: clone, forge: forge} do
    sha = commit!(clone, %{"lib/a.ex" => "a\n"}, "work [skip ci]")

    assert {:ok, _} =
             Worktree.push(clone, branch: @branch, ci_skip: {:commit_marker, "[skip ci]"})

    assert git!(forge, ["rev-parse", @branch]) == sha
  end
end
