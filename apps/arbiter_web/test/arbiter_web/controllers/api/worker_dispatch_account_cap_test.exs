defmodule ArbiterWeb.Api.WorkerDispatchAccountCapTest do
  @moduledoc """
  bd-8suxac on `POST /api/workers/dispatch` — the endpoint behind
  `arb dispatch`. A dispatch onto a provider account with no free slot is a
  409 naming the account, its cap and the holders; `"over_cap": true`
  (`--over-cap`) goes over and records the override.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker

  require Ash.Query

  setup %{conn: conn} do
    ResumeSlotFixture.setup_repo!()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "api-account-cap-#{System.unique_integer([:positive])}",
        prefix: "aac#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "aac-#{System.unique_integer([:positive])}",
        max_concurrent: 1
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    {:ok, holder} = Ash.create(Issue, %{title: "holder", workspace_id: ws.id})
    test = self()

    pid =
      spawn(fn ->
        send(test, {:held, Admission.admit(holder, :claude)})

        receive do
          :release -> :ok
        end
      end)

    on_exit(fn -> send(pid, :release) end)
    assert_receive {:held, {:ok, :admitted}}, 5_000

    {:ok, task} = Ash.create(Issue, %{title: "to dispatch", workspace_id: ws.id})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      ws: ws,
      account: account,
      holder: holder,
      task: task
    }
  end

  defp params(ctx, extra) do
    Map.merge(
      %{
        "task_id" => ctx.task.id,
        "repo" => ResumeSlotFixture.repo(),
        "force" => true,
        "no_agent" => true
      },
      extra
    )
  end

  test "a dispatch onto a full account is a 409 naming the account, the cap and the holder",
       ctx do
    conn = post(ctx.conn, ~p"/api/workers/dispatch", params(ctx, %{}))

    body = json_response(conn, 409)
    assert body["error"]["message"] =~ "claude:#{ctx.account.slug}"
    assert body["error"]["message"] =~ "--over-cap"
    assert body["error"]["details"]["cap"] == 1
    assert body["error"]["details"]["holders"] == [ctx.holder.id]
    assert body["error"]["details"]["account"] == "claude:#{ctx.account.slug}"

    assert Worker.whereis(ctx.task.id) == nil
  end

  test "over_cap: true goes over the cap and records the override", ctx do
    conn = post(ctx.conn, ~p"/api/workers/dispatch", params(ctx, %{"over_cap" => true}))

    assert json_response(conn, 201)
    assert is_pid(Worker.whereis(ctx.task.id))

    assert [event] =
             Arbiter.Events.Record
             |> Ash.Query.filter(workspace_id == ^ctx.ws.id and topic == "account_cap_override")
             |> Ash.read!()

    assert event.payload["task_id"] == ctx.task.id
    assert event.payload["actor"] == "coordinator"
  end
end
