defmodule Arbiter.Worker.SendBackBriefTest do
  @moduledoc "bd-bk8kae / #976 — a resume after `resolve --send-back` carries the reasoning and findings."

  use Arbiter.DataCase, async: false

  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "sb-#{System.unique_integer([:positive])}"})
    {:ok, task} = Ash.create(Issue, %{title: "send back", workspace_id: ws.id})
    %{task: task}
  end

  defp review!(task, attrs) do
    {:ok, row} =
      Ash.create(
        Round,
        Map.merge(
          %{task_id: task.id, round: 1, role: :review, verdict: :request_changes},
          attrs
        )
      )

    row
  end

  defp resolve!(task, decision, reasoning) do
    {:ok, r} =
      Resolutions.record(%{task_id: task.id, decision: decision, reasoning: reasoning})

    r
  end

  test "manual resume prompt carries the send-back text and latest REQUEST_CHANGES findings",
       %{task: task} do
    review!(task, %{findings: "OLD-FINDING"})
    review!(task, %{round: 2, findings: "nightly:run must need image:test_runner"})
    resolve!(task, :send_back, "ADD the needs edge, then push")

    prompt = Arbiter.Worker.manual_resume_prompt(task.id)
    assert prompt =~ "ADD the needs edge, then push"
    assert prompt =~ "nightly:run must need image:test_runner"
    refute prompt =~ "OLD-FINDING"
    assert prompt =~ "ended before you finished"
  end

  test "no send-back means no block", %{task: task} do
    review!(task, %{findings: "F"})
    refute Arbiter.Worker.manual_resume_prompt(task.id) =~ "SENT BACK"
  end

  test "a later accept_as_is supersedes the send-back", %{task: task} do
    resolve!(task, :send_back, "redo it")
    resolve!(task, :accept_as_is, "fine")
    refute Arbiter.Worker.manual_resume_prompt(task.id) =~ "redo it"
  end

  describe "flag_unchanged_head/3" do
    alias Arbiter.Messages.Message
    alias Arbiter.Worker.SendBackBrief

    @head "7788d94eaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    defp escalations(task) do
      Message |> Ash.read!() |> Enum.filter(&(&1.task_ref == task.id))
    end

    test "tells the coordinator when the head equals the one the send-back was recorded on",
         %{task: task} do
      {:ok, _} =
        Resolutions.record(%{
          task_id: task.id,
          decision: :send_back,
          reasoning: "add the needs edge",
          head_sha: @head
        })

      assert :flagged = SendBackBrief.flag_unchanged_head(task.id, task.workspace_id, @head)

      assert [msg] = escalations(task)
      assert msg.body =~ "add the needs edge"
      assert msg.subject =~ "no new commit"
    end

    test "stays quiet when the head moved or there is no send-back", %{task: task} do
      assert :ok = SendBackBrief.flag_unchanged_head(task.id, task.workspace_id, @head)

      {:ok, _} =
        Resolutions.record(%{
          task_id: task.id,
          decision: :send_back,
          reasoning: "x",
          head_sha: @head
        })

      assert :ok = SendBackBrief.flag_unchanged_head(task.id, task.workspace_id, "beef" <> @head)
      assert escalations(task) == []
    end
  end
end
