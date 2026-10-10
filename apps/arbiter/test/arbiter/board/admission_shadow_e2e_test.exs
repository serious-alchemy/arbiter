defmodule Arbiter.Board.AdmissionShadowE2ETest do
  @moduledoc """
  `scheduler_admission` end to end (DC6): the real Autopilot reads the real
  board (`Snapshot.load/1`, `Arbiter.Board.WalkInputs`, the walk) and hands
  its card to the real `Dispatch.dispatch/2`, which spawns a (stubbed) worker
  and writes its run row. The one seam is where the published budgets come
  from: the test env's `Budget.Server` computes nothing, so they are handed to
  `WalkInputs` directly.

    * `shadow`: today's card is dispatched, its run carries the walk's
      decision as `routing_decision.admission_shadow`, and the hold change is
      an `admission_shadow_events` row.
    * `legacy`: the same card goes, the run carries no record and no row is
      written.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Board.{AdmissionShadowEvent, Autopilot, Snapshot}
  alias Arbiter.Quota.Budget
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Workers.Run

  require Ash.Query

  setup do
    ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(10)
    on_exit(fn -> Arbiter.Settings.set_scheduler_admission(nil) end)

    ws =
      Ash.create!(Workspace, %{
        name: "e2e-#{System.unique_integer([:positive])}",
        prefix: "e2e#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "e2e-#{System.unique_integer([:positive])}",
        max_concurrent: 3
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    ready = fn title, priority ->
      created =
        Ash.create!(Issue, %{
          title: title,
          workspace_id: ws.id,
          priority: priority,
          acceptance: "- e2e fixture"
        })

      Ash.update!(created, %{}, action: :promote_to_ready)
    end

    %{account: account, first: ready.("first", 1), second: ready.("second", 2)}
  end

  # By default the claude pool is ahead of its line: a budget of 0, under
  # today's cap of 3.
  defp autopilot(account, budget \\ 0, reason \\ "5h ahead of its line") do
    budget = %Budget{
      account: account.id,
      pool: "claude",
      budget: budget,
      binding: {:window, "5h"},
      reason: reason,
      ceiling: %{max_concurrent: 3, share: nil}
    }

    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        paused: false,
        interval_ms: :never,
        topics: [],
        follow_up: false,
        registry_settled?: fn -> true end,
        snapshot: fn opts ->
          Snapshot.load(Keyword.put(opts, :walk_opts, budgets: [budget]))
        end
      )

    pid
  end

  defp run_of(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  test "shadow: today's card goes, and the walk's decision is on its run and in an event row",
       %{account: account, first: first} do
    {:ok, "shadow"} = Arbiter.Settings.set_scheduler_admission("shadow")

    assert {:ok, dispatched} = Autopilot.tick(autopilot(account), 30_000)
    assert dispatched == first.id

    run = run_of(first.id)
    record = run.routing_decision["admission_shadow"]
    IO.puts("\n[e2e shadow] run #{run.id} routing_decision: #{inspect(run.routing_decision)}")

    assert %{
             "policy" => "shadow",
             "dispatched" => ^dispatched,
             "pick" => nil,
             "agrees" => false,
             "comparable" => false,
             "cause" => "capacity:provider"
           } = record

    assert record["reason"] =~ "0 of 0 seats (5h ahead of its line)"

    assert [event] = Ash.read!(AdmissionShadowEvent)

    IO.puts(
      "[e2e shadow] event: #{inspect(Map.take(event, [:policy, :legacy_pick, :walk_pick, :agrees, :comparable, :cause, :walk, :budgets]))}"
    )

    assert %{
             policy: "shadow",
             legacy_pick: ^dispatched,
             walk_pick: nil,
             cause: "capacity:provider"
           } =
             event

    assert [%{"budget" => 0, "cap" => 3, "pool" => "claude"}] =
             Enum.filter(event.budgets, &(&1["account_id"] == account.id))
  end

  test "shadow, with room on the pool: the walk agrees and names its pair",
       %{account: account, first: first} do
    {:ok, "shadow"} = Arbiter.Settings.set_scheduler_admission("shadow")

    assert {:ok, dispatched} = Autopilot.tick(autopilot(account, 2, "5h room for 2"), 30_000)
    assert dispatched == first.id

    record = run_of(first.id).routing_decision["admission_shadow"]
    IO.puts("\n[e2e shadow, room] admission_shadow: #{inspect(record)}")

    label = "claude:#{account.slug}"
    account_id = account.id

    assert %{
             "pick" => ^dispatched,
             "agrees" => true,
             "comparable" => true,
             "cause" => nil,
             "account_id" => ^account_id,
             "pool" => "claude",
             "pool_label" => ^label,
             "node" => "local",
             "placements" => 2
           } = record
  end

  test "legacy: the same card goes, with no record and no event row",
       %{account: account, first: first} do
    assert {:ok, dispatched} = Autopilot.tick(autopilot(account), 30_000)
    assert dispatched == first.id

    run = run_of(first.id)
    IO.puts("\n[e2e legacy] run #{run.id} routing_decision: #{inspect(run.routing_decision)}")

    assert run.routing_decision == nil
    assert Ash.read!(AdmissionShadowEvent) == []
  end
end
