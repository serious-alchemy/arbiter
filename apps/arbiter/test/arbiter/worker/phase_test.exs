defmodule Arbiter.Worker.PhaseTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Phase

  # `run` names the author's run in the one run vocabulary (bd-1uu19b):
  # :starting, :working, :question (waiting on a question), :in_review
  # (waiting on the ReviewGate), or a finished outcome (:succeeded, :failed,
  # :handed_off).
  defp author(run, attrs \\ %{}) do
    Map.merge(
      Map.merge(
        %{task_id: "bd-1", registry_key: "bd-1", role: nil, meta: %{}},
        run_fields(run)
      ),
      attrs
    )
  end

  defp run_fields(:starting), do: %{state: :starting, outcome: nil, waiting_on: nil}
  defp run_fields(:working), do: %{state: :working, outcome: nil, waiting_on: nil}
  defp run_fields(:question), do: %{state: :waiting, outcome: nil, waiting_on: :question}
  defp run_fields(:in_review), do: %{state: :waiting, outcome: nil, waiting_on: :review_gate}

  defp run_fields(outcome) when outcome in [:succeeded, :failed, :handed_off],
    do: %{state: :finished, outcome: outcome, waiting_on: nil}

  defp reviewer(attrs) do
    Map.merge(
      %{
        task_id: "bd-1#review",
        registry_key: "bd-1#review",
        state: :working,
        role: :reviewer,
        meta: %{role: :reviewer, reviews: "bd-1"}
      },
      attrs
    )
  end

  defp implementer(attrs) do
    Map.merge(
      %{
        task_id: "bd-1#review#impl1",
        registry_key: "bd-1#review#impl1",
        state: :working,
        role: :implementer,
        meta: %{role: :implementer, revises: "bd-1"}
      },
      attrs
    )
  end

  defp fix_pass(attrs) do
    Map.merge(
      %{
        task_id: "bd-1",
        registry_key: "bd-1:fixpass",
        state: :working,
        role: :fix_pass,
        meta: %{role: :fix_pass}
      },
      attrs
    )
  end

  defp conflict(attrs) do
    Map.merge(
      %{
        task_id: "bd-1",
        registry_key: "bd-1:conflict",
        state: :working,
        role: :conflict_resolver,
        meta: %{role: :conflict_resolver}
      },
      attrs
    )
  end

  describe "of/2 — the author's own agent" do
    test "a live main agent is :implementing" do
      assert Phase.of(author(:working, %{agent_live: true})) == :implementing
      assert Phase.of(author(:starting, %{agent_live: true})) == :implementing

      assert Phase.of(author(:starting, %{agent_live: true, meta: %{resume: true}})) ==
               :implementing
    end

    # bd-741sid: the phase names the stage; whether an agent is live is the
    # liveness beside it (see the moduledoc), which is what tells a record
    # between agents from running work. Such a record only exists for a moment
    # now — every worker stops when its agent stops.
    test "a working record whose agent has exited still names its stage, and reads as not live" do
      worker = author(:working, %{agent_live: false})
      assert Phase.of(worker) == :implementing
      refute Phase.any_agent_live?(worker, [])
    end
  end

  describe "of/2 — what is live for this task" do
    test "a live reviewer reads as :in_review" do
      author = author(:in_review, %{agent_live: false})
      assert Phase.of(author, [reviewer(%{agent_live: true})]) == :in_review
    end

    test "a live implementer round reads as :addressing_review" do
      author = author(:in_review, %{agent_live: false})
      assert Phase.of(author, [implementer(%{agent_live: true})]) == :addressing_review
    end

    # bd-741sid: no author stays resident on an open PR any more, so the
    # author here is one whose own agent has exited mid-run.
    test "a live CI fix pass reads as :fixing_ci" do
      author = author(:working, %{agent_live: false})
      assert Phase.of(author, [fix_pass(%{agent_live: true})]) == :fixing_ci
    end

    test "a live conflict resolver reads as :resolving_conflict" do
      author = author(:working, %{agent_live: false})
      assert Phase.of(author, [conflict(%{agent_live: true})]) == :resolving_conflict
    end

    test "a subordinate whose own agent has exited does not claim the author's phase" do
      author = author(:working, %{agent_live: false})
      assert Phase.of(author, [fix_pass(%{agent_live: false})]) == :implementing
    end

    test "siblings for other tasks are ignored" do
      author = author(:working, %{agent_live: false})
      other = reviewer(%{agent_live: true, meta: %{role: :reviewer, reviews: "bd-999"}})
      assert Phase.of(author, [other]) == :implementing
    end
  end

  describe "of/2 — no agent anywhere" do
    # bd-741sid: opening the MR ends the run, so an author with its PR open is
    # a finished, succeeded run — and a run a follow-up superseded is done too.
    test "a run that opened its MR, or was handed off, is :done" do
      assert Phase.of(author(:succeeded, %{agent_live: false})) == :done
      assert Phase.of(author(:handed_off, %{agent_live: false})) == :done
    end

    test "a question or a parked failure is :waiting_on_you" do
      assert Phase.of(author(:question, %{agent_live: false})) == :waiting_on_you
      assert Phase.of(author(:failed, %{agent_live: false})) == :waiting_on_you
    end

    test "the review gate spun up but nothing is live yet is :in_review" do
      assert Phase.of(author(:in_review, %{agent_live: false})) == :in_review
    end

    test "a live-state record between agents is its stage, never a hand-off (bd-741sid)" do
      for worker <- [
            author(:working, %{agent_live: false}),
            author(:starting, %{agent_live: false})
          ] do
        assert Phase.of(worker) == :implementing
        refute Phase.any_agent_live?(worker, [])
      end

      refute :handing_off in Phase.phases()
    end

    test "an open PR is no worker phase: that wait is the Merging ticket's step (bd-36ytcl)" do
      refute :waiting_ci_merge in Phase.phases()
    end

    test "a succeeded worker is :done" do
      assert Phase.of(author(:succeeded, %{agent_live: false})) == :done
    end
  end

  describe "of/2 — subordinate rows report their own round" do
    test "each role names its own phase while its agent is live" do
      assert Phase.of(reviewer(%{agent_live: true})) == :in_review
      assert Phase.of(implementer(%{agent_live: true})) == :addressing_review
      assert Phase.of(fix_pass(%{agent_live: true})) == :fixing_ci
      assert Phase.of(conflict(%{agent_live: true})) == :resolving_conflict
    end

    test "a pass with no live agent is still in its round, and reads as not live (bd-741sid)" do
      pass = fix_pass(%{agent_live: false})
      assert Phase.of(pass) == :fixing_ci
      refute Phase.any_agent_live?(pass, [])
    end
  end

  describe "of/2 — unknown liveness" do
    test "a snapshot that cannot answer keeps the old reading rather than inventing one" do
      # No :agent_live key at all — the pre-bd-aw2cyt behaviour, where a
      # :working record meant a running agent.
      assert Phase.of(author(:working)) == :implementing
      assert Phase.of(author(:in_review)) == :in_review
    end
  end

  describe "annotate/1" do
    test "stamps :phase on every row using its siblings" do
      rows = [
        author(:in_review, %{agent_live: false}),
        reviewer(%{agent_live: true})
      ]

      assert [%{phase: :in_review}, %{phase: :in_review}] = Phase.annotate(rows)
    end

    test "leaves rows for unrelated tasks alone" do
      rows = [
        author(:working, %{agent_live: true}),
        %{
          task_id: "bd-2",
          registry_key: "bd-2",
          state: :waiting,
          waiting_on: :question,
          role: nil,
          meta: %{},
          agent_live: false
        }
      ]

      assert [%{phase: :implementing}, %{phase: :waiting_on_you}] = Phase.annotate(rows)
    end
  end

  describe "label/1" do
    test "every phase has a human label" do
      for phase <- Phase.phases() do
        assert is_binary(Phase.label(phase))
        assert Phase.label(phase) != ""
      end
    end
  end

  describe "any_agent_live?/2" do
    test "true when this task has an agent burning quota in any role" do
      assert Phase.any_agent_live?(author(:working, %{agent_live: true}), [])

      assert Phase.any_agent_live?(author(:in_review, %{agent_live: false}), [
               reviewer(%{agent_live: true})
             ])
    end

    test "false when the record is alive but nothing is running for it" do
      # The exact case bd-aw2cyt is about: a card that reads as work in
      # progress while no process exists.
      refute Phase.any_agent_live?(author(:in_review, %{agent_live: false}), [
               reviewer(%{agent_live: false})
             ])

      refute Phase.any_agent_live?(author(:question, %{agent_live: false}), [])
    end

    test "unknown liveness is not a claim either way, and does not read as dead" do
      assert Phase.any_agent_live?(author(:working), [])
    end
  end

  # bd-92mx1m's slot hand-off is gone (bd-741sid): no worker fails "only so an
  # automatic round can replace it" any more, so a stale `slot_handoff` marker
  # on an old snapshot changes nothing.
  describe "a :failed worker" do
    test "waits on you, whatever an old snapshot's meta says" do
      assert Phase.of(author(:failed)) == :waiting_on_you
      assert Phase.of(author(:failed, %{meta: %{slot_handoff: true}})) == :waiting_on_you
      assert Phase.of(author(:question, %{meta: %{slot_handoff: true}})) == :waiting_on_you
    end
  end
end
