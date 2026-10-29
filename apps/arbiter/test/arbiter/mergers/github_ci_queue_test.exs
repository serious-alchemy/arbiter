defmodule Arbiter.Mergers.GithubCiQueueTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.Github.Config

  @env_var "GTE_GITHUB_CI_QUEUE_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-github-token")

    Config.put_active(%{
      "owner" => "octo",
      "repo" => "widget",
      "credentials_ref" => "env:#{@env_var}"
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp json(conn, body), do: conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)

  test "ci_queue/0 counts the repo's queued pull-request workflow runs and dates the oldest" do
    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      assert conn.request_path == "/repos/octo/widget/actions/runs"
      query = URI.decode_query(conn.query_string)
      assert query["status"] == "queued"
      assert query["event"] == "pull_request"

      json(conn, %{
        "total_count" => 2,
        "workflow_runs" => [
          %{"id" => 1, "created_at" => "2026-10-29T11:30:00Z"},
          %{"id" => 2, "created_at" => "2026-10-29T10:15:00Z"}
        ]
      })
    end)

    assert {:ok, %{pending: 2, oldest_at: oldest}} = Github.ci_queue()
    assert DateTime.compare(oldest, ~U[2026-10-29 10:15:00Z]) == :eq
  end

  test "total_count wins over the page when more runs are queued than one page lists" do
    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      json(conn, %{
        "total_count" => 250,
        "workflow_runs" => [%{"id" => 1, "created_at" => "2026-10-29T11:30:00Z"}]
      })
    end)

    assert {:ok, %{pending: 250}} = Github.ci_queue()
  end

  test "an empty queue is zero pending with no oldest" do
    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      json(conn, %{"total_count" => 0, "workflow_runs" => []})
    end)

    assert {:ok, %{pending: 0, oldest_at: nil}} = Github.ci_queue()
  end

  test "a forge error is an error, not a zero" do
    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
    end)

    assert {:error, _} = Github.ci_queue()
  end
end
