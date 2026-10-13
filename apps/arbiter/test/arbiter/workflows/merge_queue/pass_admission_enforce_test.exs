defmodule Arbiter.Workflows.MergeQueue.PassAdmissionEnforceTest do
  @moduledoc """
  A CI fix or conflict pass for a ticket in Merging under `scheduler_admission`
  (DC8, design `provider-dynamic-concurrency.md` §2.2, §3.2, I9).

  Under `legacy` a Merging ticket holds no slot, so its pass must get one and
  waits in the scheduler's fast lane at a full cap (bd-741sid) — unchanged.
  Under `enforce` the pass is a follow-up of in-flight work (an open PR): it is
  counted on the pool it runs on and never held for a full layer, so it starts
  at once. A cap of 0 on the primary still holds it, as in every mode.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Nodes
  alias Arbiter.Settings
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.Registry, as: WorkerRegistry
  alias Arbiter.Workflows.MergeQueue.PassAdmission

  setup do
    on_exit(fn ->
      Settings.set_nodes_local_max_workers(nil)
      Settings.set_scheduler_admission(nil)
    end)

    ws =
      Ash.create!(Workspace, %{
        name: "pae-#{System.unique_integer([:positive])}",
        prefix: "pae#{System.unique_integer([:positive])}"
      })

    # The board's cap is the primary's 1, and another ticket In progress holds
    # it. Its live worker also holds the one seat of the claude account's pool
    # (`max_concurrent: 1`), so the pool is full under `enforce` too.
    {:ok, 1} = Nodes.set_local_max_workers(1, nil)

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "pae-#{System.unique_integer([:positive])}",
        max_concurrent: 1
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    holding =
      Ash.create!(Issue, %{title: "holding the slot", workspace_id: ws.id})
      |> put_state!(:active)

    live_worker!(holding.id, ws.id)

    task = Ash.create!(Issue, %{title: "red CI", workspace_id: ws.id}) |> put_state!(:merging)
    %{task: task}
  end

  # A live claude worker registered under `key`, as a running ticket's is.
  defp live_worker!(key, ws_id) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(WorkerRegistry, key, nil)
        :ok = WorkerRegistry.put_dispatch(key, ws_id, "claude", [])
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp deferrer do
    test = self()

    fn task_id, kind, _opts ->
      send(test, {:deferred, task_id, kind})
      :ok
    end
  end

  for kind <- [:fix_pass, :conflict] do
    test "#{kind}, legacy: waits in the fast lane at a full cap, as today", %{task: task} do
      {:ok, _} = Settings.set_scheduler_admission(:legacy)

      assert {:deferred, _info} =
               PassAdmission.admit(task, unquote(kind), %{defer_resume: deferrer()})

      task_id = task.id
      assert_received {:deferred, ^task_id, unquote(kind)}
    end

    test "#{kind}, enforce: a follow-up, it starts at once", %{task: task} do
      {:ok, _} = Settings.set_scheduler_admission(:enforce)

      assert :ok = PassAdmission.admit(task, unquote(kind), %{defer_resume: deferrer()})
      refute_received {:deferred, _, _}
    end

    test "#{kind}, enforce: a primary cap of 0 still holds it", %{task: task} do
      {:ok, _} = Settings.set_scheduler_admission(:enforce)
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)

      assert {:error, {:no_node_capacity, %{cap: 0}}} =
               PassAdmission.admit(task, unquote(kind), %{defer_resume: deferrer()})
    end
  end
end
