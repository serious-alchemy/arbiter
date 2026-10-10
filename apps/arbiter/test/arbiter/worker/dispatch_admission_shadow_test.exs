defmodule Arbiter.Worker.DispatchAdmissionShadowTest do
  @moduledoc """
  The admission shadow's record on the run (DC6, provider-dynamic-concurrency
  §10.2): `Dispatch.dispatch/2`'s `:admission_shadow` lands on the run as
  `routing_decision.admission_shadow`, beside whatever routing decided, and
  decides nothing. Without it the run is exactly today's.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run

  require Ash.Query

  @repo ResumeSlotFixture.repo()

  @record %{
    "policy" => "shadow",
    "dispatched" => "bd-x",
    "pick" => "bd-y",
    "account_id" => "acct",
    "pool" => "claude",
    "pool_label" => "claude:default",
    "node" => "local",
    "agrees" => false,
    "comparable" => true,
    "cause" => "capacity:provider",
    "reason" => "waiting for claude:default: 3 of 3 seats",
    "placements" => 1
  }

  setup do
    ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(10)
    :ok
  end

  defp workspace!(config) do
    Ash.create!(Workspace, %{
      name: "das-#{System.unique_integer([:positive])}",
      prefix: "das#{System.unique_integer([:positive])}",
      config: config
    })
  end

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  defp dispatch!(issue, extra) do
    assert {:ok, %{worker_pid: pid}} =
             Dispatch.dispatch(
               issue.id,
               [force: true, repo: @repo, start_driver: false] ++ extra
             )

    assert is_pid(pid)
    latest_run(issue.id)
  end

  test "on an unrouted workspace the record is the whole decision" do
    ws = workspace!(%{})
    issue = Ash.create!(Issue, %{title: "shadowed", workspace_id: ws.id})

    run = dispatch!(issue, admission_shadow: @record)

    assert run.routing_decision == %{"admission_shadow" => @record}
    assert run.provider_account_id == nil
  end

  test "without it, the run records exactly what it did before" do
    ws = workspace!(%{})
    issue = Ash.create!(Issue, %{title: "legacy", workspace_id: ws.id})

    run = dispatch!(issue, [])

    assert run.routing_decision == nil
  end

  test "on a routed workspace it rides beside the routing decision, which is unchanged" do
    ws = workspace!(%{"routing" => %{"provider_selection" => "most_quota"}})

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "das-#{System.unique_integer([:positive])}"
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id,
      implementer_position: 0
    })

    plain = Ash.create!(Issue, %{title: "routed", workspace_id: ws.id})
    shadowed = Ash.create!(Issue, %{title: "routed and shadowed", workspace_id: ws.id})

    today = dispatch!(plain, [])
    run = dispatch!(shadowed, admission_shadow: @record)

    assert run.routing_decision["admission_shadow"] == @record
    assert run.routing_decision["outcome"] == today.routing_decision["outcome"]
    assert run.routing_decision["account_id"] == account.id
    assert run.provider_account_id == account.id
    refute Map.has_key?(today.routing_decision, "admission_shadow")
  end
end
