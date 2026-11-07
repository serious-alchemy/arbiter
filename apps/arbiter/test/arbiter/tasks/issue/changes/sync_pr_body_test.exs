defmodule Arbiter.Tasks.Issue.Changes.SyncPrBodyTest do
  @moduledoc """
  A `pr_body` change on an open ticket with a `pr_ref` is pushed to the forge
  MR/PR description through the merger adapter, with the merger's own credential.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  defp workspace(merge) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "spb-#{System.unique_integer([:positive])}",
        prefix: "pb",
        config: %{"merge" => merge}
      })

    ws
  end

  defp gitlab_ws do
    workspace(%{
      "strategy" => "gitlab",
      "config" => %{
        "host" => "gitlab.com",
        "project_id" => 7,
        "credentials_ref" => "lit-gl-token"
      }
    })
  end

  defp github_ws do
    workspace(%{
      "strategy" => "github",
      "config" => %{"owner" => "octo", "repo" => "widget", "credentials_ref" => "lit-gh-token"}
    })
  end

  defp ticket(ws, attrs \\ %{}) do
    {:ok, t} =
      Ash.create(
        Issue,
        %{title: "t", workspace_id: ws.id}
      )

    if attrs[:pr_ref] do
      {:ok, t} = Ash.update(t, %{pr_ref: attrs[:pr_ref]}, action: :update)
      t
    else
      t
    end
  end

  defp set_body(t, body), do: Ash.update(t, %{pr_body: body}, action: :update)

  defp stub(mod, test_pid, status \\ 200, resp \\ %{}) do
    Req.Test.stub(mod, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:req, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "private-token"),
         Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)}
      )

      conn |> Plug.Conn.put_status(status) |> Req.Test.json(resp)
    end)
  end

  test "GitLab: PUTs the MR description" do
    ws = gitlab_ws()
    t = ticket(ws, %{pr_ref: "!42"})
    stub(Arbiter.Mergers.Gitlab.HTTP, self(), 200, %{"iid" => 42})

    assert {:ok, _} = set_body(t, "new body")

    assert_receive {:req, "PUT", path, ["lit-gl-token"], _, %{"description" => "new body"}}
    assert path == "/api/v4/projects/7/merge_requests/42"
  end

  test "GitHub: PATCHes the PR body" do
    ws = github_ws()
    t = ticket(ws, %{pr_ref: "57"})
    stub(Arbiter.Mergers.Github.HTTP, self(), 200, %{"number" => 57})

    assert {:ok, _} = set_body(t, "gh body")

    assert_receive {:req, "PATCH", "/repos/octo/widget/pulls/57", _, ["Bearer lit-gh-token"],
                    %{"body" => "gh body"}}
  end

  test "no pr_ref: nothing is called" do
    ws = gitlab_ws()
    t = ticket(ws)
    stub(Arbiter.Mergers.Gitlab.HTTP, self())

    assert {:ok, _} = set_body(t, "body")
    refute_receive {:req, _, _, _, _, _}, 50
  end

  test "unchanged pr_body: nothing is called" do
    ws = gitlab_ws()
    t = ticket(ws, %{pr_ref: "!42"})
    stub(Arbiter.Mergers.Gitlab.HTTP, self(), 200, %{})
    {:ok, t} = set_body(t, "same")
    assert_receive {:req, "PUT", _, _, _, _}

    assert {:ok, _} = set_body(t, "same")
    refute_receive {:req, _, _, _, _, _}, 50
  end

  test "API error: failure recorded on the ticket, update still succeeds, one credential only" do
    ws = gitlab_ws()
    t = ticket(ws, %{pr_ref: "!42"})
    # attention is only raised on a live (open) ticket
    t =
      t
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:state, :active)
      |> Ash.update!()

    stub(Arbiter.Mergers.Gitlab.HTTP, self(), 403, %{"message" => "403 Forbidden"})

    assert {:ok, updated} = set_body(t, "body")
    assert updated.pr_body == "body"

    assert_receive {:req, "PUT", _, ["lit-gl-token"], _, _}
    refute_receive {:req, _, _, _, _, _}, 50

    reloaded = Ash.get!(Issue, t.id)
    assert reloaded.attention_cause == :tracker_sync_failed
    assert reloaded.attention_detail =~ "pr_body"
    assert reloaded.attention_detail =~ "403"
  end
end
