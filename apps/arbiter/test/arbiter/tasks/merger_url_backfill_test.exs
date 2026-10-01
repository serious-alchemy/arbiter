defmodule Arbiter.Tasks.MergerUrlBackfillTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, MergerUrlBackfill, Workspace}

  @env_var "MUB_GITLAB_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "tok")
    on_exit(fn -> System.delete_env(@env_var) end)

    for {:gitlab_project_path, _, _} = key <- Enum.map(:persistent_term.get(), &elem(&1, 0)) do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp ws! do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mub-#{System.unique_integer([:positive])}",
        prefix: "mub",
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => "gitlab.com",
              "project_id" => 68_258_632,
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    ws
  end

  defp issue!(ws, url) do
    issue = issue_without_repo!(%{title: "t", workspace_id: ws.id})

    issue
    |> Ash.Changeset.for_update(:record_pr, %{pr_ref: "!298", merger_url: url})
    |> Ash.update!()
  end

  test "rewrites numeric-id links via the resolved path, and is idempotent" do
    Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
      Req.Test.json(conn, %{"path_with_namespace" => "grp/proj"})
    end)

    ws = ws!()
    bad = issue!(ws, "https://gitlab.com/68258632/-/merge_requests/298")
    good = issue!(ws, "https://gitlab.com/grp/proj/-/merge_requests/1")

    plan = MergerUrlBackfill.plan()
    assert [%{issue_id: id, new_url: new}] = Enum.filter(plan, &(&1.issue_id == bad.id))
    assert id == bad.id
    assert new == "https://gitlab.com/grp/proj/-/merge_requests/298"

    {updated, []} = MergerUrlBackfill.apply!(plan)
    assert bad.id in updated

    assert Ash.get!(Issue, bad.id).merger_url ==
             "https://gitlab.com/grp/proj/-/merge_requests/298"

    assert Ash.get!(Issue, good.id).merger_url == "https://gitlab.com/grp/proj/-/merge_requests/1"
    assert MergerUrlBackfill.plan() == []
  end

  test "leaves the row alone when the path cannot be resolved" do
    Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn -> Plug.Conn.send_resp(conn, 500, "x") end)
    ws = ws!()
    bad = issue!(ws, "https://gitlab.com/68258632/-/merge_requests/298")

    ExUnit.CaptureLog.capture_log(fn ->
      assert [%{new_url: nil}] = MergerUrlBackfill.plan()
      assert {[], []} = MergerUrlBackfill.apply!(MergerUrlBackfill.plan())
    end)

    assert Ash.get!(Issue, bad.id).merger_url ==
             "https://gitlab.com/68258632/-/merge_requests/298"
  end
end
