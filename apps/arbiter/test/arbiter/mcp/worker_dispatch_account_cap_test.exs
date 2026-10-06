defmodule Arbiter.MCP.WorkerDispatchAccountCapTest do
  @moduledoc """
  bd-8suxac on the MCP surface: `worker_dispatch` onto a provider account with
  no free slot is refused with a message naming the account, its cap and the
  holders; `over_cap: true` goes over and records the override.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker

  require Ash.Query

  setup do
    ResumeSlotFixture.setup_repo!()
    Application.put_env(:arbiter, :conductor_system_max_concurrent, 10)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-account-cap-#{System.unique_integer([:positive])}",
        prefix: "mac#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "mac-#{System.unique_integer([:positive])}",
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
    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    %{ws: ws, account: account, holder: holder, task: task, coordinator: coordinator}
  end

  defp args(ctx, extra) do
    Map.merge(
      %{
        "task_id" => ctx.task.id,
        "force" => true,
        "no_agent" => true,
        "repo" => ResumeSlotFixture.repo()
      },
      extra
    )
  end

  test "refuses on a full account, naming the account, the cap and the holder", ctx do
    assert {:error, {:conflict, message}} = Tools.worker_dispatch(ctx.coordinator, args(ctx, %{}))

    assert message =~ "claude:#{ctx.account.slug}"
    assert message =~ "cap is 1"
    assert message =~ ctx.holder.id
    assert message =~ "over_cap"
    assert Worker.whereis(ctx.task.id) == nil
    assert Ash.get!(Issue, ctx.task.id).state == :backlog
  end

  test "over_cap: true goes over the cap and records the override", ctx do
    assert {:ok, data} =
             Tools.worker_dispatch(ctx.coordinator, args(ctx, %{"over_cap" => true}))

    assert data.worker.task_id == ctx.task.id
    assert is_pid(Worker.whereis(ctx.task.id))

    assert [event] =
             Arbiter.Events.Record
             |> Ash.Query.filter(workspace_id == ^ctx.ws.id and topic == "account_cap_override")
             |> Ash.read!()

    assert event.payload["task_id"] == ctx.task.id
    assert event.payload["actor"] == "coordinator"
  end

  test "the catalog schema accepts `over_cap`" do
    tool = Enum.find(Arbiter.MCP.Catalog.all(), &(&1.name == "worker_dispatch"))
    assert %{"type" => "boolean"} = tool.input_schema["properties"]["over_cap"]
  end
end
