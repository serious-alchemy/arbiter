defmodule Arbiter.Worker.DispatchPaceExemptTest do
  @moduledoc """
  The P0 pace exemption on the live dispatch path (bd-6bxv7h, design §4.2): a
  P0 the gate lets through only because of the exemption writes
  `pace_exempt: {window, used, paced, cap}` on the run's routing decision and
  broadcasts a `quota_pace_exempt` event; a P2 on the same account is held,
  and with the layer off nothing is recorded.

  Every agent binary is stubbed by `Arbiter.TestSandbox`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run

  require Ash.Query

  @repo "pe/repo"
  @exempt %{
    "threshold_mode" => "paced",
    "pace_exempt_priority" => 0,
    "pace_exempt_threshold" => 0.8
  }

  setup do
    claude_credential_env!()

    sandbox = TestSandbox.provision!("pace-exempt")
    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{@repo => sandbox.repo})

    on_exit(fn ->
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
      TestSandbox.own_live_workers!(sandbox)
    end)

    %{sandbox: sandbox}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # A workspace with one Claude account at 40% of its 5h window, 0.02 elapsed:
  # past the paced 0.35 floor, far under the flat 0.85 default.
  defp workspace!(quota_config, config) do
    ws =
      Ash.create!(Workspace, %{name: "pe-#{System.unique_integer([:positive])}", config: config})

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "claude-#{System.unique_integer([:positive])}",
        quota_config: quota_config
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id,
      implementer_position: 0
    })

    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: 0.40,
      reset_5h_at: DateTime.add(now(), 17_640, :second),
      status_5h: "allowed",
      utilization_7d: 0.0,
      reset_7d_at: DateTime.add(now(), 302_400, :second),
      status_7d: "allowed",
      captured_at: now()
    })

    ws
  end

  defp task!(ws, priority),
    do: Ash.create!(Issue, %{title: "p#{priority}", workspace_id: ws.id, priority: priority})

  defp dispatch(task),
    do: Dispatch.dispatch(task.id, force: true, repo: @repo, start_driver: false)

  defp events(ws, topic) do
    Arbiter.Events.Record
    |> Ash.Query.filter(workspace_id == ^ws.id and topic == ^topic)
    |> Ash.read!()
  end

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(base_task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  describe "routed workspace (most_quota)" do
    setup do
      %{ws: workspace!(@exempt, %{"routing" => %{"provider_selection" => "most_quota"}})}
    end

    test "a P0 dispatches past the paced line; the run and an event record the exemption",
         %{ws: ws, sandbox: sandbox} do
      task = task!(ws, 0)
      assert {:ok, result} = dispatch(task)
      TestSandbox.own!(sandbox, result.worker_pid)

      assert %{"window" => "5h", "used" => 0.4, "paced" => paced, "cap" => 0.8} =
               latest_run(task.id).routing_decision["pace_exempt"]

      assert_in_delta paced, 0.35, 0.01

      assert [%{payload: payload}] = events(ws, "quota_pace_exempt")
      assert payload["task_id"] == task.id
      assert payload["priority"] == 0
      assert %{"window" => "5h", "used" => 0.4, "cap" => 0.8} = payload["pace_exempt"]
    end

    test "a P2 on the same account is held and records no exemption", %{ws: ws} do
      task = task!(ws, 2)
      assert {:error, {:quota_held, _}} = dispatch(task)
      assert events(ws, "quota_pace_exempt") == []
    end
  end

  describe "routing off" do
    test "a P0 dispatches past the paced line and an event records it", %{sandbox: sandbox} do
      ws = workspace!(@exempt, %{})
      task = task!(ws, 0)
      assert {:ok, result} = dispatch(task)
      TestSandbox.own!(sandbox, result.worker_pid)

      assert [%{payload: %{"pace_exempt" => %{"window" => "5h", "cap" => 0.8}}}] =
               events(ws, "quota_pace_exempt")
    end

    test "layer off: a P0 is held like a P2 and nothing is recorded" do
      ws = workspace!(Map.delete(@exempt, "pace_exempt_priority"), %{})
      task = task!(ws, 0)
      assert {:error, {:quota_held, _}} = dispatch(task)
      assert events(ws, "quota_pace_exempt") == []
    end
  end
end
