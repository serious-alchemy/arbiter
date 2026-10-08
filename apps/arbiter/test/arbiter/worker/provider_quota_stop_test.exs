defmodule Arbiter.Worker.ProviderQuotaStopTest do
  @moduledoc """
  bd-a6vh2x end to end: a run that stops because its provider account ran out
  of allowance is a hold, not a crash.

    * the account is held until the reset the provider named (agy: "Resets in
      11m34s"), which is what routing and the quota surfaces read;
    * the ticket is queued as a held resume — no crash or resume attempt is
      counted, no `worker_stopped` escalation is raised, and the ticket shows
      no `run_crashed` attention;
    * when the hold lifts, the same session continues in the same worktree;
    * if routing can already place the ticket on another provider, it leaves the
      hold early on that provider, keeping its worktree.

  The agent binaries are `Arbiter.TestSandbox` stubs; the `agy` one replays the
  recorded output of run ddebab52 (exit 3) while a marker file exists.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Messages.Message
  alias Arbiter.Providers.Pause
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.{Issue, Lifecycle, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.DispatchQueue

  require Ash.Query

  @moduletag :capture_log

  @repo "qs/repo"

  setup do
    claude_credential_env!()

    # While `stop-marker` exists the stubbed agy dies the way run ddebab52 did;
    # without it, it behaves like a live session.
    stop_marker =
      Path.join(System.tmp_dir!(), "agy-quota-stop-#{System.unique_integer([:positive])}")

    File.write!(stop_marker, "")

    agy = """
    echo "agy $@" >> "$ARB_STUB_LOG"
    if [ -f #{stop_marker} ]; then
      echo "error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 11m34s."
      echo 'AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 11m34s.","status":"RESOURCE_EXHAUSTED","error_code":429,"code_kind":"http","retryable":true}'
      exit 3
    fi
    sleep 30
    """

    sandbox = TestSandbox.provision!("quota-stop", stub: %{"agy" => ""})
    write_agy_stub!(sandbox, agy)

    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{@repo => sandbox.repo})

    on_exit(fn ->
      File.rm(stop_marker)
      TestSandbox.own_live_workers!(sandbox)
    end)

    %{sandbox: sandbox, stop_marker: stop_marker}
  end

  # ---- fixtures -------------------------------------------------------------

  defp write_agy_stub!(sandbox, body) do
    path = Path.join(sandbox.bin, "agy")
    File.write!(path, "#!/bin/sh\nARB_STUB_LOG=#{sandbox.log}\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp account!(provider) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "#{provider}-#{System.unique_integer([:positive])}"
    })
  end

  defp allow!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: position
    })
  end

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{
      name: "qs-#{System.unique_integer([:positive])}",
      prefix: "qs",
      config: config
    })
  end

  defp claude_headroom!(account) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: 0.10,
      reset_5h_at: DateTime.add(now, 9_000),
      status_5h: "allowed",
      utilization_7d: 0.0,
      reset_7d_at: DateTime.add(now, 302_400),
      status_7d: "allowed",
      captured_at: now
    })
  end

  defp task!(ws, attrs \\ %{}),
    do: Ash.create!(Issue, Map.merge(%{title: "quota work", workspace_id: ws.id}, attrs))

  defp record_session!(task, ws, provider, session_id) do
    Ash.create!(UsageEvent, %{
      task_id: task.id,
      workspace_id: ws.id,
      repo: @repo,
      step: :work,
      provider: provider,
      session_id: session_id,
      occurred_at: DateTime.utc_now()
    })
  end

  # Dispatch on agy and wait for the stop to be held.
  defp dispatch_and_stop!(task, ws, sandbox) do
    {:ok, first} =
      Dispatch.dispatch(task.id,
        force: true,
        repo: @repo,
        start_driver: false,
        start_claude: true,
        agent_type: :gemini,
        preflight: false
      )

    TestSandbox.own!(sandbox, first.worker_pid)
    record_session!(task, ws, "gemini", "agy-conv-#{System.unique_integer([:positive])}")
    eventually(fn -> DispatchQueue.held?(ws.id, task.id) end)
    first
  end

  defp eventually(fun, tries \\ 250) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  # The hold has run its course: the account is free and the queued resume is
  # due now.
  defp lift_hold!(ws, task_id, provider) do
    {:ok, _} = Arbiter.Settings.set_provider_pauses(%{})
    item = DispatchQueue.held_item(ws.id, task_id)

    :ok =
      DispatchQueue.hold_until(
        ws.id,
        task_id,
        item.opts,
        item.reason,
        provider,
        DateTime.add(DateTime.utc_now(), -1, :second)
      )

    ws.id |> Arbiter.Workflows.DispatchQueueSupervisor.whereis() |> DispatchQueue.drain()
  end

  # ---- the tests --------------------------------------------------------------

  describe "an agy RESOURCE_EXHAUSTED stop" do
    test "opens an account hold until the reset and queues a held resume, not a crash",
         %{sandbox: sandbox} do
      ws = workspace!()
      agy = account!(:antigravity)
      allow!(ws, agy, 0)
      task = task!(ws)

      first = dispatch_and_stop!(task, ws, sandbox)

      # Classified as quota exhaustion, not a crash.
      run = latest_run(task.id)
      assert run.stop_category == "quota_exhausted"
      assert run.exit_code == 3

      # The account is held until the stated reset (11m34s + the clock-skew buffer).
      assert %{until: until, kind: :quota} = Pause.for_account(agy)
      secs = DateTime.diff(until, DateTime.utc_now())
      assert secs in (11 * 60 + 34)..(11 * 60 + 34 + 70)

      # The ticket waits as a held resume that replays at the reset.
      assert %{intent: "resume", retry_not_before: at, provider: :gemini} =
               ws.id |> DispatchQueue.held_item(task.id) |> DispatchQueue.describe()

      assert DateTime.compare(at, until) == :eq

      # Nothing was counted, and nobody was told it crashed.
      refute Map.get(Worker.state(first.worker_pid).meta, :resume_attempts, 0) > 0
      assert Message.last_escalation(:worker_stopped, task_ref: task.id) == nil

      assert %{attention: nil, hold: %{reason: "held — quota" <> _}} =
               task.id |> then(&Ash.get!(Issue, &1)) |> Lifecycle.view()
    end

    test "the same session resumes in the same worktree once the hold lifts",
         %{sandbox: sandbox, stop_marker: stop_marker} do
      ws = workspace!()
      agy = account!(:antigravity)
      allow!(ws, agy, 0)
      task = task!(ws)

      first = dispatch_and_stop!(task, ws, sandbox)
      stopped_run = latest_run(task.id)
      %{session_id: session_id} = Ash.read!(UsageEvent) |> Enum.find(&(&1.task_id == task.id))

      # Early on, the held resume does not drain: the account is still held.
      ws.id |> Arbiter.Workflows.DispatchQueueSupervisor.whereis() |> DispatchQueue.drain()
      assert DispatchQueue.held?(ws.id, task.id)

      File.rm!(stop_marker)
      lift_hold!(ws, task.id, :gemini)

      eventually(fn -> not DispatchQueue.held?(ws.id, task.id) end)
      eventually(fn -> match?(%Run{} = r when r.id != stopped_run.id, latest_run(task.id)) end)

      resumed = latest_run(task.id)
      assert resumed.resumed_from_run_id == stopped_run.id
      assert resumed.provider == "gemini"

      pid = Worker.whereis(task.id)
      assert Worker.state(pid).meta[:worktree_path] == first.worktree_path
      assert File.dir?(first.worktree_path)

      # The stub logs a call per line of argv; the resumed spawn carries the
      # stopped session's conversation id.
      eventually(fn ->
        Enum.any?(TestSandbox.calls(sandbox), &(&1 =~ "--conversation #{session_id}"))
      end)

      # Resuming out of a quota stop is not another attempt at a crashed run.
      refute Ash.get!(Issue, task.id).attention_cause == :run_crashed
    end
  end

  describe "rerouting" do
    test "a ticket whose constraint allows it moves to a provider with headroom, keeping its worktree",
         %{sandbox: sandbox} do
      ws = workspace!(%{"routing" => %{"provider_selection" => "most_quota"}})
      agy = account!(:antigravity)
      claude = account!(:claude)
      allow!(ws, agy, 0)
      allow!(ws, claude, 1)
      claude_headroom!(claude)
      task = task!(ws)

      first = dispatch_and_stop!(task, ws, sandbox)
      stopped_run = latest_run(task.id)

      # The reset is ~12 minutes out, but claude has room now: the item
      # leaves the hold without waiting for it.
      assert %{until: until} = Pause.for_account(agy)
      assert DateTime.compare(until, DateTime.utc_now()) == :gt

      ws.id |> Arbiter.Workflows.DispatchQueueSupervisor.whereis() |> DispatchQueue.drain()

      eventually(fn -> not DispatchQueue.held?(ws.id, task.id) end)
      eventually(fn -> match?(%Run{} = r when r.id != stopped_run.id, latest_run(task.id)) end)

      rerouted = latest_run(task.id)
      assert rerouted.provider == "claude"
      assert rerouted.provider_account_id == claude.id
      assert rerouted.resumed_from_run_id == stopped_run.id

      pid = Worker.whereis(task.id)
      assert Worker.state(pid).meta[:worktree_path] == first.worktree_path

      # agy stays held for everyone else.
      assert Pause.for_account(agy)
    end

    test "a ticket constrained to the stopped provider waits for the reset instead",
         %{sandbox: sandbox} do
      ws = workspace!(%{"routing" => %{"provider_selection" => "most_quota"}})
      agy = account!(:antigravity)
      claude = account!(:claude)
      allow!(ws, agy, 0)
      allow!(ws, claude, 1)
      claude_headroom!(claude)
      task = task!(ws, %{provider_constraint: %{"exclude" => ["claude"]}})

      dispatch_and_stop!(task, ws, sandbox)

      ws.id |> Arbiter.Workflows.DispatchQueueSupervisor.whereis() |> DispatchQueue.drain()

      assert DispatchQueue.held?(ws.id, task.id)
      assert %{attention: nil} = task.id |> then(&Ash.get!(Issue, &1)) |> Lifecycle.view()
    end
  end
end
