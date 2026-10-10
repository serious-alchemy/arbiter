defmodule Arbiter.Worker.DispatchSpendCapTest do
  @moduledoc """
  The dollar spend cap holds FRESH dispatches only (bd-a6grlr): once an
  account's metered spend in its window (plus the in-flight estimate) reaches
  the cap, or passes the paced line, a ticket being started is held in the
  `DispatchQueue` with a spend reason - while follow-ups on tickets already
  started (resumes, re-dispatches, reviews) still run.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota.SpendCap
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.DispatchQueue

  @repo ResumeSlotFixture.repo()

  setup do
    ResumeSlotFixture.setup_repo!()
    Application.put_env(:arbiter, :conductor_system_max_concurrent, 10)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "spend-#{System.unique_integer([:positive])}",
        prefix: "sp#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp account!(ws, config) do
    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "spend-#{System.unique_integer([:positive])}",
        quota_config: config
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    account
  end

  defp spend!(account, ws, cost, at \\ DateTime.utc_now()) do
    Ash.create!(UsageEvent, %{
      task_id: "bd-ledger-#{System.unique_integer([:positive])}",
      source: :task,
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      workspace_id: ws.id,
      cost_usd: cost,
      occurred_at: at
    })
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- spend fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  defp dispatch(issue, extra \\ []),
    do: Dispatch.dispatch(issue.id, [repo: @repo, start_driver: false] ++ extra)

  describe "flat cap, fresh dispatch" do
    test "is held with a spend reason once metered spend reaches the cap", %{ws: ws} do
      account = account!(ws, %{"spend_cap" => 20.0, "spend_metered" => true})
      spend!(account, ws, 25.0)
      issue = ready!(ws, "over the cap")

      assert {:error, {:quota_held, id}} = dispatch(issue)
      assert id == issue.id
      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued

      assert %{reason: reason} = DispatchQueue.held_item(ws.id, issue.id)
      assert reason.gate == :spend
      assert reason.phrase =~ "spend cap $20.00/week reached"
      assert Dispatch.quota_held_message(issue.id) =~ "spend cap $20.00/week reached"
    end

    test "starts while under the cap", %{ws: ws} do
      account = account!(ws, %{"spend_cap" => 20.0, "spend_metered" => true})
      spend!(account, ws, 5.0)
      issue = ready!(ws, "under the cap")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
    end

    test "notional spend on a non-metered account never holds", %{ws: ws} do
      account = account!(ws, %{"spend_cap" => 1.0, "spend_metered" => false})
      spend!(account, ws, 400.0)
      issue = ready!(ws, "subscription")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
    end

    test "an operator's force_quota bypass goes past the cap", %{ws: ws} do
      account = account!(ws, %{"spend_cap" => 20.0, "spend_metered" => true})
      spend!(account, ws, 25.0)
      issue = ready!(ws, "forced")

      assert {:ok, %{worker_pid: pid}} =
               dispatch(issue,
                 skip_quota_gate: true,
                 quota_bypass_actor: "operator",
                 quota_bypass_reason: "ship it"
               )

      assert is_pid(pid)
    end
  end

  describe "follow-ups on a started ticket still run past the cap" do
    # A ticket started while the account was under its cap, whose worker has
    # since gone: In progress, worktree preserved.
    defp interrupted!(ws, account) do
      issue = ready!(ws, "interrupted #{System.unique_integer([:positive])}")
      assert {:ok, first} = dispatch(issue)
      ref = Process.monitor(first.worker_pid)
      :ok = Worker.stop(issue.id, :normal)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      assert Ash.get!(Issue, issue.id).state == :active
      spend!(account, ws, 50.0)
      issue
    end

    setup %{ws: ws} do
      %{account: account!(ws, %{"spend_cap" => 20.0, "spend_metered" => true})}
    end

    test "a resume", %{ws: ws, account: account} do
      issue = interrupted!(ws, account)
      assert {:error, {:quota_held, _}} = dispatch(ready!(ws, "fresh one is held"))
      assert {:ok, %{worker_pid: pid}} = Dispatch.resume(issue.id, start_driver: false, resume_origin: :human)
      assert is_pid(pid)
    end

    test "a re-dispatch of the In progress ticket", %{ws: ws, account: account} do
      issue = interrupted!(ws, account)
      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
    end

    test "a review dispatch", %{ws: ws, account: account} do
      issue = interrupted!(ws, account)
      refute match?({:error, {:quota_held, _}}, dispatch(issue, review: true))
    end
  end

  describe "Admission: a burst of fresh dispatches cannot overshoot" do
    # Hold an admission open in its own process, as a dispatch does between the
    # gate and `Worker.start/1`.
    defp hold_admission(issue, opts) do
      test = self()

      pid =
        spawn(fn ->
          send(test, {:admitted, self(), Admission.admit(issue, :claude, opts)})

          receive do
            :release -> :ok
          end
        end)

      assert_receive {:admitted, ^pid, result}, 5_000
      {pid, result}
    end

    test "each admission counts the earlier ones' estimated remaining cost", %{ws: ws} do
      account = account!(ws, %{"spend_cap" => 20.0, "spend_metered" => true})
      spend!(account, ws, 10.0)
      a = ready!(ws, "burst a")
      b = ready!(ws, "burst b")
      c = ready!(ws, "burst c")
      opts = [spend_opts: [estimate_fun: fn _id -> 8.0 end]]

      {pa, ra} = hold_admission(a, opts)
      assert {:ok, _} = ra
      {pb, rb} = hold_admission(b, opts)
      assert {:ok, _} = rb

      # 10 settled + 2 x ~8 in flight is past the cap: the third is held.
      {pc, rc} = hold_admission(c, opts)
      assert {:error, {:spend_cap, reason}} = rc
      assert reason.gate == :spend
      assert_in_delta reason.used, 26.0, 0.001

      for pid <- [pa, pb, pc], do: send(pid, :release)
      assert SpendCap.check(account, nil, in_flight: 0.0) == :ok
    end

    test "a ticket's already-spent cost is not counted twice", %{ws: ws} do
      account = account!(ws, %{"spend_cap" => 20.0, "spend_metered" => true})
      a = ready!(ws, "partly spent")
      spend!(account, ws, 6.0, DateTime.utc_now())
      # A ledger row for the ticket itself, already part of the 6.0 settled.
      Ash.create!(UsageEvent, %{
        task_id: a.id,
        source: :task,
        step: :work,
        provider: "claude",
        provider_account_id: account.id,
        workspace_id: ws.id,
        cost_usd: 4.0,
        occurred_at: DateTime.utc_now()
      })

      b = ready!(ws, "second")
      opts = [spend_opts: [estimate_fun: fn _id -> 12.0 end]]
      {pa, {:ok, _}} = hold_admission(a, opts)
      # In flight: 12.0 estimate - 4.0 spent = 8.0, on top of 10.0 settled: 18 < 20 (22 if the 4.0 were counted twice).
      {pb, rb} = hold_admission(b, opts)
      assert {:ok, _} = rb
      for pid <- [pa, pb], do: send(pid, :release)
    end
  end
end
