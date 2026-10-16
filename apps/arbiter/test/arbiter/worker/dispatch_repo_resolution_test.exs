defmodule Arbiter.Worker.DispatchRepoResolutionTest do
  @moduledoc """
  bd-7u1b6n: dispatch and resume resolve a ticket's `repo` through the same
  `Arbiter.Tasks.IssueRepo` resolver. A ticket whose stored repo is a forge slug
  (`acme/tonic`) used to dispatch (a git-remote fallback) and then be refused on
  resume with `:repo_unknown`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, IssueRepo, Workspace}
  alias Arbiter.Worker.Dispatch

  setup do
    prior = Application.get_env(:arbiter, :repo_paths)
    Application.delete_env(:arbiter, :repo_paths)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, :repo_paths, prior),
        else: Application.delete_env(:arbiter, :repo_paths)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "drr-#{System.unique_integer([:positive])}",
        prefix: "drr#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"tonic" => System.tmp_dir!(), "tonic_device" => System.tmp_dir!()}
        }
      })

    %{ws: ws}
  end

  defp ticket_with_repo!(ws, repo) do
    {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, repo: "tonic"})
    issue |> Ecto.Changeset.change(repo: repo) |> Arbiter.Repo.update!()
  end

  test "IssueRepo.canonical_repo/2 maps a slug onto its key and keeps unknown values" do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "drr-c-#{System.unique_integer([:positive])}",
        prefix: "drc#{System.unique_integer([:positive])}",
        config: %{"repo_paths" => %{"tonic" => "/srv/tonic"}}
      })

    assert IssueRepo.canonical_repo(ws.id, "acme/tonic") == "tonic"
    assert IssueRepo.canonical_repo(ws.id, "tonic") == "tonic"
    assert IssueRepo.canonical_repo(ws.id, "acme/other") == "acme/other"
  end

  test "resume resolves a slug-shaped stored repo the way dispatch does", %{ws: ws} do
    issue = ticket_with_repo!(ws, "acme/tonic")

    # No run on record and no `repo:` opt: the repo comes from the ticket. It
    # resolves to a checkout (no worktree yet), not `:repo_unknown`.
    assert {:error, reason} = Dispatch.resume(issue.id, [])
    refute reason == :repo_unknown
  end
end
