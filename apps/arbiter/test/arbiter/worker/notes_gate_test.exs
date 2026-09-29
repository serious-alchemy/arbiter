defmodule Arbiter.Worker.NotesGateTest do
  @moduledoc """
  Regression tests for the notes gate, which guards `issue_type: :research`.

  A research directive's deliverable is a findings summary written to the
  `notes` field — not a code change. The notes gate fires when the worker
  signals `arb done` but `notes` is still blank. Like the commit gate, the
  nudge cap is pinned to 0 in these tests so we assert the structural gate
  behaviour (fail + escalate) without exercising the retry layer.

  `issue_type: :task` (an operational action) shares the no-PR path but NOT the
  gate: it completes on `arb done` with no findings (bd-9s9dqz).
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "notes-gate-ws-#{System.unique_integer([:positive])}",
        prefix: "ng",
        config: %{}
      })

    %{ws: ws}
  end

  defp new_task(ws, notes \\ nil, issue_type \\ :research) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "notes-gate task",
        workspace_id: ws.id,
        issue_type: issue_type
      })

    task = put_state!(task, :active)

    task =
      if notes do
        {:ok, t} = Ash.update(task, %{notes: notes}, action: :update)
        t
      else
        task
      end

    task
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Drive a REAL session port that does the agent's work and exits cleanly
  # (status 0) WITHOUT ever printing `arb done` — the exact wrap-up failure mode
  # from bd-2da6ay. The port exit (not a synthetic done message) is what routes
  # the worker through the deferred stop check.
  defp exit_clean_without_done(pid, tag) do
    cwd = tmp_dir!(tag)

    {:ok, _port} =
      Arbiter.Worker.ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", "echo 'findings recorded; wrapping up'; exit 0"]
      )

    :ok
  end

  # Drive a REAL gemini/agy session that echoes a captured-shape `step_update`
  # ERROR event (bd-25ivqe: a `:strict` policy auto-denying a `run_command`
  # call — here, the worker's own `arb inbox` bootstrap call) and then exits
  # cleanly without ever printing `arb done`, exactly as it would if every
  # subsequent retry kept getting denied too. `tool_info.error` is the object
  # shape (`%{"type" => ..., "message" => ...}`) confirmed live against the
  # installed agy (1.2.8); an earlier version of this fixture guessed a bare
  # string, which is why the original fix passed this exact test yet still
  # failed to attribute a real denial (`permission_denial?/1` only matches
  # `is_binary`, so an unwrapped map object always fell through to `false`).
  defp exit_agy_denied_without_done(pid, tag, command \\ "arb inbox bd-ci0y74") do
    cwd = tmp_dir!(tag)

    error_event =
      Jason.encode!(%{
        "event" => "step_update",
        "step_update" => %{
          "step_index" => 1,
          "state" => "ERROR",
          "step_type" => "tool",
          "tool_name" => "run_command",
          "tool_info" => %{
            "name" => "run_command",
            "parameters" => %{"CommandLine" => command},
            "error" => %{
              "type" => "TOOL_ERROR",
              "message" => "permission check failed for unsandboxed \"#{command}\""
            }
          }
        }
      })

    {:ok, _port} =
      Arbiter.Worker.ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        provider: "gemini",
        command: ["sh", "-c", "echo '#{error_event}'; exit 0"]
      )

    :ok
  end

  defp start_worker(task, extra_meta) do
    meta =
      Map.merge(
        %{
          # Dispatch stamps issue_type into meta; replicate that here so the
          # worker's no-PR guards route through the notes gate path.
          issue_type: :research,
          review_spawn: false
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        # Task-type workers have no worktree; dispatch defaults repo to "unknown".
        repo: "unknown",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  describe "notes gate (bd-5lc99r)" do
    test "arb-done with blank notes fails + escalates instead of completing", %{ws: ws} do
      task = new_task(ws)
      # Pin nudge cap to 0 so we hit the structural fail path immediately,
      # without the retry layer spawning a new session.
      pid = start_worker(task, %{notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)

      # Must not have completed or routed to any review path.
      refute snap.outcome == :succeeded
      refute snap.waiting_on == :review_gate

      # fail_now/2 stores the failure reason under :failure_reason in meta.
      assert snap.meta.failure_reason == :blank_notes_at_completion
      # park_notes_gate also records the structural why under :notes_gate_detail.
      assert snap.meta.notes_gate_detail == :cap_exhausted

      # Task stays open — the notes gate deliberately does NOT write to the
      # notes field (unlike the commit gate), because polluting notes would
      # let a re-dispatched worker satisfy the gate without producing real
      # findings. The escalation carries the diagnostic instead.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.state == :closed

      # Coordinator receives an escalation naming the gate failure.
      escalations = Message.inbox("admiral", workspace_id: ws.id)

      escalation =
        Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.subject =~ "Notes gate"
    end

    test "arb-done with populated notes completes cleanly", %{ws: ws} do
      task = new_task(ws, "## Findings\n\nResearch complete. Conclusion: viable.")
      pid = start_worker(task, %{notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.outcome == :succeeded
    end

    test "whitespace-only notes are treated as blank", %{ws: ws} do
      task = new_task(ws, "   \n\t  ")
      pid = start_worker(task, %{notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

      assert Worker.state(pid).meta.failure_reason == :blank_notes_at_completion
    end
  end

  describe "nudge cap from workspace config (bd-4qjl0q)" do
    # A REAL session that prints the completion sentinel and exits, so the
    # worker stashes its port args (`meta.claude_spawn`) and the notes gate's
    # send-back can genuinely relaunch it. A fixture argv has no prompt slot to
    # splice the nudge into, so every relaunch re-runs this same command — which
    # signals done again with `notes` still blank, exactly the worker that
    # keeps forgetting to write its findings. (printf keeps the sentinel off
    # this source line.)
    defp signal_done_session(pid, tag) do
      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: tmp_dir!(tag),
          command: ["sh", "-c", "printf 'arb %s\\n' done"]
        )

      :ok
    end

    defp notes_gate_escalation(ws, task) do
      Message.inbox("admiral", workspace_id: ws.id)
      |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))
    end

    test "defaults to 2: a second send-back is attempted before escalating", %{ws: ws} do
      task = new_task(ws)
      # No `notes_nudge_cap` meta override — the cap comes from config/default.
      pid = start_worker(task, %{})
      :ok = signal_done_session(pid, "ng-cap-default")

      wait_until(
        fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end,
        10_000
      )

      snap = Worker.state(pid)
      assert snap.meta.notes_nudge_attempts == 2
      assert snap.meta.notes_gate_detail == :cap_exhausted

      escalation = notes_gate_escalation(ws, task)
      assert escalation
      assert escalation.body =~ "tried 2/2 send-back attempt(s)"
    end

    test "notes_gate.nudge_cap = 1 preserves the single send-back", %{ws: ws} do
      {:ok, ws} =
        Ash.update(ws, %{config: %{"notes_gate" => %{"nudge_cap" => 1}}})

      task = new_task(ws)
      pid = start_worker(task, %{})
      :ok = signal_done_session(pid, "ng-cap-one")

      wait_until(
        fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end,
        10_000
      )

      snap = Worker.state(pid)
      assert snap.meta.notes_nudge_attempts == 1
      assert snap.meta.notes_gate_detail == :cap_exhausted

      escalation = notes_gate_escalation(ws, task)
      assert escalation
      assert escalation.body =~ "tried 1/1 send-back attempt(s)"
    end
  end

  describe "operational `task` type has no notes gate (bd-9s9dqz)" do
    test "arb-done with blank notes completes cleanly", %{ws: ws} do
      task = new_task(ws, nil, :task)
      pid = start_worker(task, %{issue_type: :task, notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      refute Map.has_key?(snap.meta, :failure_reason)
      refute Map.has_key?(snap.meta, :notes_gate_detail)
      refute snap.waiting_on == :review_gate

      # No escalation: nothing tripped.
      refute Message.inbox("admiral", workspace_id: ws.id)
             |> Enum.any?(&(&1.kind == :escalation and &1.directive_ref == task.id))
    end

    test "a string-typed issue_type still routes as no-PR", %{ws: ws} do
      task = new_task(ws, nil, :task)
      pid = start_worker(task, %{issue_type: "task", notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end)
    end

    test "research still refuses a blank-notes completion when typed as a string", %{ws: ws} do
      task = new_task(ws)
      pid = start_worker(task, %{issue_type: "research", notes_nudge_cap: 0})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)
      assert Worker.state(pid).meta.failure_reason == :blank_notes_at_completion
    end
  end

  describe "exit-without-done finalization (bd-2da6ay)" do
    # The wrap-up failure mode: a task-type worker reaches the end of its work
    # and the subprocess exits cleanly (status 0) but the agent never printed
    # `arb done`. Before this fix the worker routed into the bd-t9uq25 resume
    # loop, which only replayed the identical clean exit — burning Opus until
    # the resume cap was exhausted, then failing. Now the worker finalizes
    # through the notes gate the same way `arb done` does.

    test "clean exit with populated notes completes via the notes gate (no resume loop)",
         %{ws: ws} do
      task = new_task(ws, "## Findings\n\nInvestigation complete. Conclusion: viable.")
      pid = start_worker(task, %{notes_nudge_cap: 0})

      :ok = exit_clean_without_done(pid, "ng-exit-populated")

      wait_until(fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.outcome == :succeeded
      # It completed straight through the notes gate — never down the resume
      # path (no resume attempt was ever recorded) and never failed.
      refute Map.has_key?(snap.meta, :resume_attempts)
      refute Map.has_key?(snap.meta, :stop_reason)
    end

    test "clean exit with blank notes fails + escalates instead of looping on resume",
         %{ws: ws} do
      task = new_task(ws)
      # Pin the nudge cap to 0 so we hit the structural park path immediately,
      # without respawning a session.
      pid = start_worker(task, %{notes_nudge_cap: 0})

      :ok = exit_clean_without_done(pid, "ng-exit-blank")

      wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      # Failed via the notes gate (concrete cause), NOT via the resume/stop path.
      assert snap.meta.failure_reason == :blank_notes_at_completion
      assert snap.meta.notes_gate_detail == :cap_exhausted
      refute Map.has_key?(snap.meta, :resume_attempts)

      # Task stays open — the notes gate never pollutes the notes field.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.state == :closed

      # Coordinator receives the notes-gate escalation naming the failure.
      escalation =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.subject =~ "Notes gate"
    end

    test "a strict-denied required command reports a concrete failure reason (bd-25ivqe AC4)",
         %{ws: ws} do
      task = new_task(ws)
      pid = start_worker(task, %{notes_nudge_cap: 0})

      :ok = exit_agy_denied_without_done(pid, "ng-strict-denied")

      wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      # Not the generic catch-all — a concrete, actionable reason naming the
      # denied command.
      assert snap.meta.failure_reason == "strict policy denied required command `arb`"
      assert snap.meta.denied_command == "arb"

      escalation =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      assert escalation.body =~ "strict-policy bootstrap failure"
    end

    # bd-7wymls: run fc54ef4a reported "strict policy denied required command
    # `pwd`" — but `pwd` is not part of the worker protocol. Only a
    # bootstrap command is "required"; anything else is just "denied".
    test "a strict-denied NON-bootstrap command is not called \"required\"", %{ws: ws} do
      task = new_task(ws)
      pid = start_worker(task, %{notes_nudge_cap: 0})

      :ok = exit_agy_denied_without_done(pid, "ng-strict-denied-nonboot", "pwd && git status")

      wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.meta.failure_reason == "strict policy denied command `pwd`"

      escalation =
        Message.inbox("admiral", workspace_id: ws.id)
        |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))

      assert escalation
      refute escalation.body =~ "bootstrap failure"
      assert escalation.body =~ "`pwd && git status`"
    end
  end
end
