defmodule Arbiter.Mergers.GitlabCiQueueTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Gitlab
  alias Arbiter.Mergers.Gitlab.Config

  @env_var "GTE_GITLAB_CI_QUEUE_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => "gitlab.com",
      "project_id" => 12_345,
      "credentials_ref" => "env:#{@env_var}"
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp json(conn, body), do: conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)

  test "ci_queue/0 counts the project's MR pipelines that have not started, and dates the oldest" do
    Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
      assert conn.request_path == "/api/v4/projects/12345/pipelines"
      query = URI.decode_query(conn.query_string)
      assert query["source"] == "merge_request_event"

      case query["status"] do
        "pending" ->
          json(conn, [
            %{"id" => 11, "created_at" => "2026-10-29T10:00:00.000Z"},
            %{"id" => 12, "created_at" => "2026-10-29T11:30:00.000Z"}
          ])

        "waiting_for_resource" ->
          json(conn, [%{"id" => 13, "created_at" => "2026-10-29T09:45:00.500Z"}])

        "created" ->
          json(conn, [])
      end
    end)

    assert {:ok, %{pending: 3, oldest_at: oldest}} = Gitlab.ci_queue()
    assert DateTime.compare(oldest, ~U[2026-10-29 09:45:00.500Z]) == :eq
  end

  test "an empty queue is zero pending with no oldest" do
    Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn -> json(conn, []) end)
    assert {:ok, %{pending: 0, oldest_at: nil}} = Gitlab.ci_queue()
  end

  test "a pipeline listed under two statuses is counted once" do
    Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
      json(conn, [%{"id" => 7, "created_at" => "2026-10-29T10:00:00Z"}])
    end)

    assert {:ok, %{pending: 1}} = Gitlab.ci_queue()
  end

  test "a forge error is an error, not a zero" do
    Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
    end)

    assert {:error, _} = Gitlab.ci_queue()
  end
end
