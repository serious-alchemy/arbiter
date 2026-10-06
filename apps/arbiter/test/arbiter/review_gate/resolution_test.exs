defmodule Arbiter.ReviewGate.ResolutionTest do
  @moduledoc """
  bd-4qjl0q: a gate escalation's recorded resolution — the coordinator's answer
  to it (`accept_as_is` / `amend` / `send_back` / `reject`), with reasoning,
  actor and timestamp — persisted against the task, recordable over MCP in one
  call, and returned by `review_gate_rounds_list` so an escalated-and-amended
  run reads differently from one that converged.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.ReviewGate.{Resolution, Resolutions, Round}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "gate-res-#{System.unique_integer([:positive])}"})

    {:ok, task} = Ash.create(Issue, %{title: "gate resolution", workspace_id: ws.id})
    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    %{ws: ws, task: task, coordinator: coordinator}
  end

  defp review_round(task, round, verdict, findings) do
    {:ok, row} =
      Ash.create(Round, %{
        task_id: task.id,
        round: round,
        role: :review,
        verdict: verdict,
        findings: findings,
        finding_count: if(verdict == :approve, do: 0, else: 1),
        converged: verdict == :approve
      })

    row
  end

  defp impl_round(task, round) do
    {:ok, row} =
      Ash.create(Round, %{
        task_id: task.id,
        round: round,
        role: :impl,
        findings: "addressed round #{round}"
      })

    row
  end

  describe "Resolutions.record/1" do
    test "persists decision, reasoning, actor and timestamp against the task", %{task: task} do
      assert {:ok, %Resolution{} = res} =
               Resolutions.record(%{
                 task_id: task.id,
                 gate: :notes_gate,
                 decision: :send_back,
                 reasoning: "the worker forgot the notes write; re-dispatching",
                 actor: "coordinator"
               })

      assert res.task_id == task.id
      assert res.workspace_id == task.workspace_id
      assert res.gate == :notes_gate
      assert res.decision == :send_back
      assert res.reasoning =~ "forgot the notes write"
      assert res.actor == "coordinator"
      assert %DateTime{} = res.inserted_at
      # A gate with no rounds resolves at task level — no round link.
      assert res.round == nil

      assert [%Resolution{id: id}] = Resolutions.list(task.id)
      assert id == res.id
    end

    test "accepts string decisions and gates (the MCP / REST wire form)", %{task: task} do
      assert {:ok, res} =
               Resolutions.record(%{
                 "task_id" => task.id,
                 "decision" => "accept_as_is",
                 "reasoning" => "the open finding is a non-blocking nit"
               })

      assert res.decision == :accept_as_is
      # review_gate is the default gate; the actor defaults to the coordinator.
      assert res.gate == :review_gate
      assert res.actor == "coordinator"
    end

    test "a review_gate resolution links to the last reviewer round it answers",
         %{task: task} do
      review_round(task, 1, :request_changes, "VERDICT: REQUEST_CHANGES r1")
      impl_round(task, 1)
      review_round(task, 2, :request_changes, "VERDICT: REQUEST_CHANGES r2")

      assert {:ok, res} =
               Resolutions.record(%{task_id: task.id, decision: :amend, reasoning: "amended"})

      assert res.round == 2
      assert res.fix_round_attempt == 0
    end

    test "rejects an unknown decision, blank reasoning, and an unknown task", %{task: task} do
      assert {:error, {:invalid, msg}} =
               Resolutions.record(%{task_id: task.id, decision: "overrule", reasoning: "x"})

      assert msg =~ "decision"

      assert {:error, {:invalid, msg}} =
               Resolutions.record(%{task_id: task.id, decision: :amend, reasoning: "   "})

      assert msg =~ "reasoning"

      assert {:error, {:not_found, _}} =
               Resolutions.record(%{task_id: "bd-nope00", decision: :amend, reasoning: "x"})

      assert Resolutions.list(task.id) == []
    end

    test "broadcasts a gate_resolved event on the task's workspace stream",
         %{ws: ws, task: task} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      {:ok, _} =
        Resolutions.record(%{task_id: task.id, decision: :reject, reasoning: "wrong approach"})

      assert_receive {:event, %{topic: "gate_resolved"} = event}
      assert event.task_id == task.id
      assert event.gate == "review_gate"
      assert event.decision == "reject"
    end
  end

  describe "review_gate_resolve MCP tool" do
    test "records a resolution in one call and returns it", %{task: task, coordinator: coord} do
      assert {:ok, %{resolution: res}} =
               Tools.review_gate_resolve(coord, %{
                 "task_id" => task.id,
                 "decision" => "amend",
                 "reasoning" => "heuristic need not be airtight; provenance tag instead"
               })

      assert res.decision == :amend
      assert res.actor == "coordinator"
      assert [%Resolution{decision: :amend}] = Resolutions.list(task.id)
    end

    test "a caller-supplied actor is ignored; attribution comes from the caller", %{task: task, coordinator: coord} do
      assert {:ok, %{resolution: res}} =
               Tools.review_gate_resolve(coord, %{
                 "task_id" => task.id,
                 "decision" => "accept_as_is",
                 "reasoning" => "fine",
                 "actor" => "operator:ryan"
               })

      assert res.actor == "coordinator"
    end

    test "requires task_id, decision and reasoning", %{task: task, coordinator: coord} do
      assert {:error, {:invalid, _}} =
               Tools.review_gate_resolve(coord, %{"decision" => "amend", "reasoning" => "x"})

      assert {:error, {:invalid, _}} =
               Tools.review_gate_resolve(coord, %{"task_id" => task.id, "reasoning" => "x"})

      assert {:error, {:invalid, _}} =
               Tools.review_gate_resolve(coord, %{"task_id" => task.id, "decision" => "amend"})
    end

    test "is a coordinator-tier tool" do
      tool = Enum.find(Arbiter.MCP.Catalog.all(), &(&1.name == "review_gate_resolve"))
      assert tool
      assert tool.tiers == [:coordinator]
    end
  end

  describe "review_gate_rounds_list with a resolution" do
    test "a converged run and an escalated-and-amended run produce different output",
         %{ws: ws, task: amended, coordinator: coord} do
      {:ok, converged} = Ash.create(Issue, %{title: "converged", workspace_id: ws.id})

      # Converged: rejected once, approved on round 2.
      review_round(converged, 1, :request_changes, "VERDICT: REQUEST_CHANGES")
      impl_round(converged, 1)
      review_round(converged, 2, :approve, "VERDICT: APPROVE")

      # Escalated: rejected on all three rounds, then amended by the coordinator.
      for r <- 1..3 do
        review_round(amended, r, :request_changes, "VERDICT: REQUEST_CHANGES r#{r}")
        if r < 3, do: impl_round(amended, r)
      end

      {:ok, _} =
        Resolutions.record(%{task_id: amended.id, decision: :amend, reasoning: "amended"})

      {:ok, conv} = Tools.review_gate_rounds_list(coord, %{"task_id" => converged.id})
      {:ok, amend} = Tools.review_gate_rounds_list(coord, %{"task_id" => amended.id})

      assert conv.outcome == "converged"
      assert conv.resolution == nil
      assert conv.resolutions == []

      assert amend.outcome == "resolved"
      assert amend.resolution.decision == :amend
      assert amend.resolution.round == 3

      refute Map.take(conv, [:outcome, :resolution]) == Map.take(amend, [:outcome, :resolution])
    end

    test "an escalated run with no resolution yet reads as not_converged",
         %{task: task, coordinator: coord} do
      for r <- 1..3, do: review_round(task, r, :request_changes, "VERDICT: REQUEST_CHANGES")

      assert {:ok, %{outcome: "not_converged", resolution: nil}} =
               Tools.review_gate_rounds_list(coord, %{"task_id" => task.id})
    end

    test "a task with no rounds and no resolution reads as none",
         %{task: task, coordinator: coord} do
      assert {:ok, %{outcome: "none", resolution: nil, rounds: []}} =
               Tools.review_gate_rounds_list(coord, %{"task_id" => task.id})
    end
  end

  # AC4: replay vs-acnaup's shape end-to-end. Three ReviewGate rounds, a High
  # finding standing on the last one with the reviewer's verified remedy, no
  # convergence — then the coordinator amends against that standing finding.
  # Before bd-4qjl0q the only trace was a sentence in a commit message; now the
  # decision, its reasoning, who made it and the round it overrides are all
  # queryable from the task.
  describe "vs-acnaup replay (bd-4qjl0q AC4)" do
    test "3 unconverged rounds + a coordinator amendment leave a queryable record",
         %{task: task, coordinator: coord} do
      standing_finding = """
      VERDICT: REQUEST_CHANGES
      1. [High] An empty 200 from the deep corroborating probe is accepted as
         corroboration, yielding a writable false `Symbol.inception_date` floor.
         Remedy (applied locally, 39/39 tests pass): route `{:ok, []}` to
         `inconclusive/4`.
      """

      review_round(task, 1, :request_changes, "VERDICT: REQUEST_CHANGES\n1. [High] r1")
      impl_round(task, 1)
      review_round(task, 2, :request_changes, "VERDICT: REQUEST_CHANGES\n1. [High] r2")
      impl_round(task, 2)
      review_round(task, 3, :request_changes, standing_finding)

      reasoning =
        "Restore the {:ok, []} corroboration outcome: the corroboration heuristic is not " <>
          "required to be airtight — the probe ladder bottoms out at 1994-09, so hard-failing " <>
          "every deep empty 200 leaves most of the catalogue unmeasurable. Floor provenance " <>
          "tag + opt-in gate instead."

      assert {:ok, %{resolution: recorded}} =
               Tools.review_gate_resolve(coord, %{
                 "task_id" => task.id,
                 "gate" => "review_gate",
                 "decision" => "amend",
                 "reasoning" => reasoning,
                 "actor" => "coordinator"
               })

      # The record names the decision, its reasoning, who and when, and the
      # round whose standing finding it overrides.
      assert {:ok, listed} = Tools.review_gate_rounds_list(coord, %{"task_id" => task.id})

      assert listed.outcome == "resolved"
      assert length(listed.rounds) == 5
      assert List.last(listed.rounds).findings =~ "[High]"

      res = listed.resolution
      assert res.id == recorded.id
      assert res.decision == :amend
      assert res.reasoning == reasoning
      assert res.actor == "coordinator"
      assert res.gate == :review_gate
      assert res.round == 3
      assert res.fix_round_attempt == 0
      assert is_binary(res.inserted_at)

      # And it is queryable straight off the task, independent of the MCP view.
      assert [%Resolution{decision: :amend, reasoning: ^reasoning, round: 3}] =
               Resolutions.list(task.id)
    end
  end
end
