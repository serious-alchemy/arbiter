defmodule ArbiterWeb.Api.MessageUtf8Test do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Repo
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.{PrepushSteps, Run}

  @bad <<"cut at ", 0xB1, " mid">>

  setup %{conn: conn} do
    ws = Ash.create!(Workspace, %{name: "ws-u8-#{System.unique_integer([:positive])}"})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  test "GET /api/messages and /api/messages/:id serialize a legacy invalid row", %{
    conn: conn,
    ws: ws
  } do
    m =
      Ash.create!(Message, %{
        kind: :mailbox,
        from_ref: "coordinator",
        to_ref: "bd-u8",
        body: "ok",
        workspace_id: ws.id
      })

    Repo.query!("UPDATE messages SET body = ?1, subject = ?1 WHERE id = ?2", [@bad, m.id])

    assert %{"data" => [%{"body" => body}]} =
             json_response(get(conn, ~p"/api/messages", %{to_ref: "bd-u8"}), 200)

    assert String.valid?(body)

    assert %{"body" => shown} = json_response(get(conn, ~p"/api/messages/#{m.id}"), 200)
    assert String.valid?(shown)
  end

  test "GET /api/workers/:task_id serializes legacy invalid prepush output", %{conn: conn, ws: ws} do
    task_id = "bd-u8-#{System.unique_integer([:positive])}"

    run =
      Ash.create!(Run, %{
        task_id: task_id,
        repo: "arbiter",
        workspace_id: ws.id,
        state: :finished,
        outcome: :failed,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    :ok =
      PrepushSteps.record(run.id, task_id, 1, [
        %{
          name: "f",
          cmd: "c",
          scope: :all,
          status: :failed,
          exit_status: 1,
          duration_ms: 1,
          output: "x",
          reason: nil
        }
      ])

    Repo.query!("UPDATE worker_prepush_steps SET output = ?1 WHERE run_id = ?2", [@bad, run.id])

    body = json_response(get(conn, ~p"/api/workers/#{task_id}"), 200)
    assert [%{"output" => out}] = body["pre_push_checks"]
    assert String.valid?(out)
  end
end
