defmodule Arbiter.Worker.ReviewOnlyFixRoundFindingsTest do
  @moduledoc """
  bd-2ujj2p / #605: a coordinator-dispatched review (`arb review <task>` /
  `worker_review`) that ends REQUEST_CHANGES handed the ReviewGate fix round
  only the text AFTER its `VERDICT:` line — a reviewer that posts its findings
  (the PR comment body) and then prints the sentinel left the fix round with
  `VERDICT: REQUEST_CHANGES`, `VERIFICATION: FULL` and `arb done`, so the
  implementer correctly changed nothing and the gate parked the ticket.

  The fix round must carry the review's full findings text; a verdict with no
  findings anywhere escalates instead of starting an empty round.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.{StubFixRoundDispatcher, StubMerger}
  alias Arbiter.Worker

  setup do
    StubMerger.reset()
    StubFixRoundDispatcher.reset()
    :ok
  end

  defp start_reviewer(output_lines, opts \\ []) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ro-fr-ws-#{System.unique_integer([:positive])}",
        prefix: "rf",
        config: %{}
      })

    {:ok, task} = Ash.create(Issue, %{title: "reviewed task", workspace_id: ws.id})
    task = put_state!(task, :active)

    task =
      case Keyword.get(opts, :pr_feedback) do
        nil ->
          task

        feedback ->
          {:ok, task} = Ash.update(task, %{pr_ref: "rv/repo#605"}, action: :update)
          StubMerger.set_review_feedback("rv/repo#605", feedback)
          task
      end

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "rv/repo",
        workspace_id: ws.id,
        meta: %{
          review_only: true,
          output_lines: output_lines,
          merger_adapter_override: StubMerger,
          merger_workspace_override: nil
        }
      )

    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    # Synchronise on the worker having handled the completion message.
    _ = :sys.get_state(pid)
    assert Worker.state(pid).outcome == :failed
    {task, ws, pid}
  end

  @body [
    "## Review",
    "- [Medium] lib/foo.ex:12 missing nil guard on the lookup",
    "- [Medium] lib/bar.ex:40 the retry loop never backs off"
  ]

  test "findings printed BEFORE the VERDICT line reach the fix round" do
    {task, _ws, _pid} =
      start_reviewer(
        ["reading the diff"] ++ @body ++ ["VERDICT: REQUEST_CHANGES", "VERIFICATION: FULL"]
      )

    assert StubFixRoundDispatcher.dispatch_count() == 1

    assert [args] = StubFixRoundDispatcher.dispatches()
    assert args.task_id == task.id
    assert args.findings =~ "lib/foo.ex:12 missing nil guard"
    assert args.findings =~ "lib/bar.ex:40 the retry loop never backs off"
    assert args.findings =~ "VERDICT: REQUEST_CHANGES"
  end

  test "PR review body reaches the fix round even when stdout holds only narration" do
    pr_body = "[Medium] lib/foo.ex:12 missing nil guard on the lookup"

    {task, _ws, _pid} =
      start_reviewer(
        [
          "I'll post my review to the PR now.",
          "VERDICT: REQUEST_CHANGES",
          "VERIFICATION: FULL",
          "arb done"
        ],
        pr_feedback: %{
          changes_requested: true,
          latest_review_id: 1,
          feedback: [%{kind: :review, state: "CHANGES_REQUESTED", body: pr_body}]
        }
      )

    assert StubFixRoundDispatcher.dispatch_count() == 1

    assert [args] = StubFixRoundDispatcher.dispatches()
    assert args.task_id == task.id
    assert args.findings =~ "VERDICT: REQUEST_CHANGES"
    assert args.findings =~ pr_body
    refute args.findings =~ "post my review"
  end

  test "findings printed after the VERDICT line still reach the fix round" do
    {_task, _ws, _pid} = start_reviewer(["VERDICT: REQUEST_CHANGES"] ++ @body)

    assert StubFixRoundDispatcher.dispatch_count() == 1
    assert [args] = StubFixRoundDispatcher.dispatches()
    assert args.findings =~ "lib/foo.ex:12 missing nil guard"
  end

  test "a REQUEST_CHANGES with no findings anywhere escalates and starts no fix round" do
    {task, ws, pid} =
      start_reviewer(["VERDICT: REQUEST_CHANGES", "VERIFICATION: FULL", "arb done"])

    messages = Message.inbox("admiral", workspace_id: ws.id)

    assert Enum.any?(messages, &(&1.kind == :escalation and &1.directive_ref == task.id))
    assert StubFixRoundDispatcher.dispatch_count() == 0
    assert StubFixRoundDispatcher.escalations() == []
    assert Map.get(Worker.state(pid).meta || %{}, :review_gate_fix_round_attempts) in [nil, 0]
  end
end
