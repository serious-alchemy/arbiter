defmodule Arbiter.Worker.AdmissionFollowUpTest do
  @moduledoc """
  I9 (DC6, provider-dynamic-concurrency §2.2, §4.5, §11): a follow-up of work
  already In progress is never held because a layer is full — in any
  `scheduler_admission` mode.

  The fixture fills both layers a dispatch can meet today: the provider
  account (`max_concurrent: 1`, one live run on it) and, for the review-side
  roles, the primary's machine cap (1, the same live run). Then each follow-up
  role of an In-progress ticket starts anyway, over the full layer, under
  `legacy`, `shadow` and `enforce` alike: the walk plans only Ready cards, so
  no mode can reach a follow-up.

  What still holds a follow-up is a layer's hard zero (a machine cap of 0, as
  `:zero_only` does), which `Arbiter.Nodes.LocalCapacityTest` covers.

  One rule is older than this: the primary's cap counts a *resume* at its cap
  (`:at_cap`, bd-b2iigy — a restart's resume sweep once put 5 runs on a cap of
  2), and a ReviewGate fix round re-dispatched through
  `ReviewGateFixRoundDispatcher` is a resume. Under `legacy` and `shadow` it is
  unchanged (I1), so the cases in the loop fill the account, not the machine.
  DC8 settles §2.2 under `enforce`: a resume of a ticket In progress is a
  follow-up, held by the primary's cap only at 0 (the last two describes), and
  the gate holds a follow-up on a hard rule only, never on the paced line (O2).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{Concurrency, ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.TestSandbox
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Dispatch}
  alias Arbiter.Workflows.MergeQueue.{ConflictResolver, FixPassDispatcher}
  alias Arbiter.Workflows.ReviewGateFixRoundDispatcher

  @repo ResumeSlotFixture.repo()

  setup do
    sandbox = ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(10)
    on_exit(fn -> Arbiter.Settings.set_scheduler_admission(nil) end)

    ws =
      Ash.create!(Workspace, %{
        name: "i9-#{System.unique_integer([:positive])}",
        prefix: "i9#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "i9-#{System.unique_integer([:positive])}",
        max_concurrent: 1
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    # The ticket whose follow-ups are tested: In progress, its run stopped.
    ticket = Ash.create!(Issue, %{title: "in flight", workspace_id: ws.id, issue_type: :feature})

    {:ok, first} =
      Dispatch.dispatch(ticket.id,
        force: true,
        force_slot: true,
        repo: @repo,
        start_driver: false
      )

    ref = Process.monitor(first.worker_pid)
    :ok = Worker.stop(ticket.id, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert Ash.get!(Issue, ticket.id).state == :active

    # Another ticket's live run fills the account: 1 of 1.
    other = Ash.create!(Issue, %{title: "the other run", workspace_id: ws.id})
    {:ok, live} = Dispatch.dispatch(other.id, force: true, repo: @repo, start_driver: false)
    TestSandbox.own!(sandbox, live.worker_pid)
    assert Concurrency.live_count(account) == 1

    %{sandbox: sandbox, ws: ws, account: account, ticket: ticket}
  end

  # The primary full too: its cap is the one live run.
  defp fill_the_machine!, do: ResumeSlotFixture.put_local_cap(1)

  # A pass's own In-progress ticket, its branch pushed the way its first run
  # would have (the routing suite's CI-pass fixture). Dispatched over the full
  # account on purpose: this is the fixture, not the case.
  defp pass_context(%{sandbox: sandbox, ws: ws}) do
    ticket =
      Ash.create!(Issue, %{title: "in merge work", workspace_id: ws.id, issue_type: :feature})

    {:ok, first} =
      Dispatch.dispatch(ticket.id, force: true, force_slot: true, repo: "r", start_driver: false)

    TestSandbox.own!(sandbox, first.worker_pid)
    :ok = Worker.fail(first.worker_pid, :token_exhausted)
    assert Ash.get!(Issue, ticket.id).state == :active

    branch = BranchNamer.derive(ticket)
    :ok = TestSandbox.seed_branch!(sandbox, branch)

    %{
      task: Ash.get!(Issue, ticket.id),
      repo: @repo,
      repo_path: sandbox.repo,
      branch: branch,
      target_branch: "main",
      workspace: ws,
      start_claude: false
    }
  end

  for mode <- [:legacy, :shadow, :enforce] do
    describe "under #{mode}" do
      setup do
        {:ok, _} = Arbiter.Settings.set_scheduler_admission(unquote(mode))
        :ok
      end

      test "the walk never plans a follow-up: an In-progress ticket is not a Ready card", ctx do
        board = Snapshot.load(workspace_id: ctx.ws.id, admission: unquote(mode))

        refute Enum.any?(board.ready, &(&1.id == ctx.ticket.id))

        if walk = Map.get(board, :walk),
          do: refute(Enum.any?(walk.entries, &(&1.id == ctx.ticket.id)))
      end

      test "a resume goes over a full account", ctx do
        assert {:ok, %{worker_pid: pid}} =
                 Dispatch.resume(ctx.ticket.id, start_driver: false, resume_origin: :automatic)

        TestSandbox.own!(ctx.sandbox, pid)
        assert Concurrency.live_count(ctx.account) == 2
      end

      test "a re-dispatched ReviewGate fix round goes over a full account", ctx do
        assert {:ok, %{worker_pid: pid}} =
                 ReviewGateFixRoundDispatcher.dispatch(%{
                   task_id: ctx.ticket.id,
                   attempt: 1,
                   verdict: :request_changes,
                   claude_command: ["true"]
                 })

        TestSandbox.own!(ctx.sandbox, pid)
      end

      test "a CI fix pass goes over a full account and a full machine", ctx do
        context = pass_context(ctx)
        fill_the_machine!()

        assert {:ok, %{worker_pid: pid}} = FixPassDispatcher.dispatch(context)
        TestSandbox.own!(ctx.sandbox, pid)
      end

      test "a conflict pass goes over a full account and a full machine", ctx do
        context = pass_context(ctx)

        # Move main on, so the branch has something to resolve against.
        git = fn args ->
          {_, 0} = System.cmd("git", ["-C", ctx.sandbox.repo | args], stderr_to_stdout: true)
        end

        git.(["checkout", "-q", "main"])
        File.write!(Path.join(ctx.sandbox.repo, "other.txt"), "other\n")
        git.(["add", "other.txt"])
        git.(["commit", "-q", "-m", "other work"])
        git.(["push", "-q", "origin", "main"])

        fill_the_machine!()

        assert {:ok, %{worker_pid: pid}} = ConflictResolver.dispatch(context)
        TestSandbox.own!(ctx.sandbox, pid)
      end
    end
  end

  # ---- DC8: enforce settles the node layer and drops the pace hold -------------

  # The account's 5h window at 90%, past the flat 0.85 ceiling (a utilization
  # rule, so a pace rule in the gate's terms), with the provider still accepting.
  defp past_the_line!(account) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Ash.create!(Arbiter.Quota.AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: 0.90,
      reset_5h_at: DateTime.add(now, 9_000, :second),
      status_5h: "allowed",
      utilization_7d: 0.10,
      reset_7d_at: DateTime.add(now, 302_400, :second),
      status_7d: "allowed",
      captured_at: now
    })
  end

  defp mode!(mode), do: {:ok, _} = Arbiter.Settings.set_scheduler_admission(mode)

  describe "a resume on a full primary (DC8 settles §2.2 on the node layer)" do
    setup do
      Arbiter.Test.StubResumeDeferrer.reset()
      fill_the_machine!()
      :ok
    end

    test "legacy: deferred, as it is today (the :at_cap rule, bd-b2iigy)", ctx do
      mode!(:legacy)

      assert {:ok, %{deferred: true, held_for: :local_capacity}} =
               Dispatch.resume(ctx.ticket.id, start_driver: false, resume_origin: :automatic)
    end

    test "enforce: a follow-up of In-progress work goes over the full machine", ctx do
      mode!(:enforce)

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.resume(ctx.ticket.id, start_driver: false, resume_origin: :automatic)

      TestSandbox.own!(ctx.sandbox, pid)
    end

    test "enforce: a re-dispatched ReviewGate fix round goes over the full machine too", ctx do
      mode!(:enforce)

      assert {:ok, %{worker_pid: pid}} =
               ReviewGateFixRoundDispatcher.dispatch(%{
                 task_id: ctx.ticket.id,
                 attempt: 1,
                 verdict: :request_changes,
                 claude_command: ["true"]
               })

      TestSandbox.own!(ctx.sandbox, pid)
    end

    test "enforce: a cap of 0 is a hard zero and still holds it", ctx do
      mode!(:enforce)
      ResumeSlotFixture.put_local_cap(0)

      assert {:ok, %{deferred: true, held_for: :local_capacity}} =
               Dispatch.resume(ctx.ticket.id, start_driver: false, resume_origin: :automatic)
    end
  end

  describe "a follow-up past the paced line (§4.5, O2)" do
    setup ctx do
      past_the_line!(ctx.account)
      :ok
    end

    test "legacy: the gate holds a resume past the line in the DispatchQueue", ctx do
      mode!(:legacy)

      assert {:error, {:quota_held, _}} =
               Dispatch.resume(ctx.ticket.id, start_driver: false, resume_origin: :automatic)
    end

    test "enforce: the resume goes ahead — follow-ups are held by the hard rules only", ctx do
      mode!(:enforce)

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.resume(ctx.ticket.id, start_driver: false, resume_origin: :automatic)

      TestSandbox.own!(ctx.sandbox, pid)
    end

    test "enforce: a ReviewGate fix round goes ahead too", ctx do
      mode!(:enforce)

      assert {:ok, %{worker_pid: pid}} =
               ReviewGateFixRoundDispatcher.dispatch(%{
                 task_id: ctx.ticket.id,
                 attempt: 1,
                 verdict: :request_changes,
                 claude_command: ["true"]
               })

      TestSandbox.own!(ctx.sandbox, pid)
    end
  end
end
