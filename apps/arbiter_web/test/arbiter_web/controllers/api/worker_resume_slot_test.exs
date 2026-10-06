defmodule ArbiterWeb.Api.WorkerResumeSlotTest do
  @moduledoc """
  bd-92mx1m acceptance 2/4 on `POST /api/workers/:task_id/resume` — the
  endpoint behind `arb worker resume` (and `arb resume`). A resume of a task
  that released its slot, at a full cap, is refused with a 409 naming the cap
  and the slot-holding tasks; `"force": true` (`--force`) admits it and
  records the override.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "api-resume-slot-#{System.unique_integer([:positive])}",
        prefix: "ars#{System.unique_integer([:positive])}"
      })

    incident = ResumeSlotFixture.setup_incident(ws)

    # The endpoint is a *session* resume: it needs a captured session id.
    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: incident.a.id,
        workspace_id: ws.id,
        repo: ResumeSlotFixture.repo(),
        step: :work,
        provider: "claude",
        session_id: "sess-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

    Map.merge(%{conn: put_req_header(conn, "accept", "application/json"), ws: ws}, incident)
  end

  test "a resume at a full cap is a 409 naming the cap and the holder", ctx do
    conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{})

    body = json_response(conn, 409)
    assert body["error"]["message"] =~ "cap is 1"
    assert body["error"]["message"] =~ ctx.b.id
    assert body["error"]["message"] =~ "--force"
    assert body["error"]["details"]["cap"] == 1
    assert body["error"]["details"]["holders"] == [ctx.b.id]

    assert Worker.whereis(ctx.a.id) == ctx.first.worker_pid
    assert ResumeSlotFixture.overrides(ctx.ws) == []
  end

  test "force: true admits it over the cap and records the override", ctx do
    conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{"force" => true})

    assert json_response(conn, 201)
    assert Worker.whereis(ctx.a.id) != ctx.first.worker_pid

    assert [event] = ResumeSlotFixture.overrides(ctx.ws)
    assert event.payload["task_id"] == ctx.a.id
    assert event.payload["holders"] == [ctx.b.id]
    assert event.payload["actor"] == "api"
  end

  describe "refusals the endpoint used to answer with a generic 500 (bd-5fc29i)" do
    test "a resume while migrations are pending is a 503 busy naming the count", ctx do
      Application.put_env(:arbiter, :migrations_module, ArbiterWeb.Test.PendingMigrations)
      on_exit(fn -> Application.delete_env(:arbiter, :migrations_module) end)

      conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{"force" => true})

      assert %{"error" => %{"type" => "busy", "message" => message, "details" => details}} =
               json_response(conn, 503)

      assert message =~ "pending migration"
      assert details["pending_migrations"] == 3
    end

    test "a resume when the migration check itself fails is a 503 busy, not a 500", ctx do
      Application.put_env(:arbiter, :migrations_module, ArbiterWeb.Test.UnreachableMigrations)
      on_exit(fn -> Application.delete_env(:arbiter, :migrations_module) end)

      conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{"force" => true})

      assert %{"error" => %{"type" => "busy", "details" => %{"reason" => ":unreachable"}}} =
               json_response(conn, 503)
    end
  end
end
