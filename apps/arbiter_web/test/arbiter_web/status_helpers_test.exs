defmodule ArbiterWeb.StatusHelpersTest do
  use ExUnit.Case

  alias ArbiterWeb.StatusHelpers

  describe "run_status/1" do
    test "a live run reads its state" do
      assert StatusHelpers.run_status(%{state: :starting, outcome: nil}) == :starting
      assert StatusHelpers.run_status(%{state: :working, outcome: nil}) == :working
      assert StatusHelpers.run_status(%{state: :waiting, outcome: nil}) == :waiting
    end

    test "a finished run reads its outcome" do
      assert StatusHelpers.run_status(%{state: :finished, outcome: :succeeded}) == :succeeded
      assert StatusHelpers.run_status(%{state: :finished, outcome: :failed}) == :failed
      assert StatusHelpers.run_status(%{state: :finished, outcome: :interrupted}) == :interrupted
      assert StatusHelpers.run_status(%{state: :finished, outcome: :handed_off}) == :handed_off
      assert StatusHelpers.run_status(%{state: :finished}) == :finished
    end

    test "anything without a state is nil" do
      assert StatusHelpers.run_status(%{}) == nil
      assert StatusHelpers.run_status(nil) == nil
    end
  end

  describe "run_label/1" do
    test "labels each live state" do
      assert StatusHelpers.run_label(%{state: :starting, meta: %{}}) == "Starting"
      assert StatusHelpers.run_label(%{state: :starting, meta: %{resume: true}}) == "Resuming"
      assert StatusHelpers.run_label(%{state: :working}) == "Working"

      assert StatusHelpers.run_label(%{state: :waiting, waiting_on: :question}) ==
               "Waiting on you"

      assert StatusHelpers.run_label(%{state: :waiting, waiting_on: :review_gate}) == "In review"
    end

    test "labels each outcome of a finished run" do
      assert StatusHelpers.run_label(%{state: :finished, outcome: :succeeded}) == "Succeeded"
      assert StatusHelpers.run_label(%{state: :finished, outcome: :failed}) == "Failed"
      assert StatusHelpers.run_label(%{state: :finished, outcome: :interrupted}) == "Interrupted"
      assert StatusHelpers.run_label(%{state: :finished, outcome: :handed_off}) == "Handed off"
    end

    test "a map without a state is Unknown" do
      assert StatusHelpers.run_label(%{}) == "Unknown"
    end
  end

  describe "run_role/1" do
    test "an implement run with role impl is impl, otherwise the kind" do
      assert StatusHelpers.run_role(%{kind: :implement, role: "impl"}) == "impl"
      assert StatusHelpers.run_role(%{kind: :implement, role: "base"}) == "implement"
      assert StatusHelpers.run_role(%{kind: :review, role: "review"}) == "review"
      assert StatusHelpers.run_role(%{kind: :fix_pass}) == "fix_pass"
      assert StatusHelpers.run_role(%{kind: :conflict}) == "conflict"
    end
  end

  describe "worker_status_class/1" do
    test "returns correct badge class for each run status" do
      assert StatusHelpers.worker_status_class(:starting) == "badge-ghost"
      assert StatusHelpers.worker_status_class(:working) == "badge-info"
      assert StatusHelpers.worker_status_class(:waiting) == "badge-warning"
      assert StatusHelpers.worker_status_class(:succeeded) == "badge-success"
      assert StatusHelpers.worker_status_class(:failed) == "badge-error"
      assert StatusHelpers.worker_status_class(:interrupted) == "badge-warning"
      assert StatusHelpers.worker_status_class(:handed_off) == "badge-ghost"
      assert StatusHelpers.worker_status_class(:unknown) == ""
    end

    test "a run map is keyed on its run status" do
      assert StatusHelpers.worker_status_class(%{state: :working}) == "badge-info"

      assert StatusHelpers.worker_status_class(%{state: :finished, outcome: :failed}) ==
               "badge-error"
    end
  end

  describe "worker_status_label/1" do
    test "returns correct label for each run status" do
      assert StatusHelpers.worker_status_label(:starting) == "Starting"
      assert StatusHelpers.worker_status_label(:working) == "Working"
      assert StatusHelpers.worker_status_label(:waiting) == "Waiting"
      assert StatusHelpers.worker_status_label(:finished) == "Finished"
      assert StatusHelpers.worker_status_label(:succeeded) == "Succeeded"
      assert StatusHelpers.worker_status_label(:failed) == "Failed"
      assert StatusHelpers.worker_status_label(:interrupted) == "Interrupted"
      assert StatusHelpers.worker_status_label(:handed_off) == "Handed off"
    end

    test "capitalizes unknown atoms" do
      assert StatusHelpers.worker_status_label(:some_status) == "Some_status"
    end

    test "converts non-atoms to strings" do
      assert StatusHelpers.worker_status_label("string_status") == "string_status"
    end
  end

  describe "difficulty_badge_class/1" do
    test "returns correct badge class for each difficulty level" do
      assert StatusHelpers.difficulty_badge_class(nil) == "badge-ghost"
      assert StatusHelpers.difficulty_badge_class(0) == "badge-success"
      assert StatusHelpers.difficulty_badge_class(1) == "badge-info"
      assert StatusHelpers.difficulty_badge_class(2) == "badge-secondary"
      assert StatusHelpers.difficulty_badge_class(3) == "badge-warning"
      assert StatusHelpers.difficulty_badge_class(4) == "badge-error"
      assert StatusHelpers.difficulty_badge_class(5) == "badge-ghost"
    end
  end

  describe "run_status_class/1" do
    test "returns correct badge class for each run status" do
      assert StatusHelpers.run_status_class(:succeeded) == "badge-success"
      assert StatusHelpers.run_status_class(:failed) == "badge-error"
      assert StatusHelpers.run_status_class(:working) == "badge-info"
      assert StatusHelpers.run_status_class(:waiting) == "badge-warning"
      assert StatusHelpers.run_status_class(:unknown) == "badge-ghost"

      assert StatusHelpers.run_status_class(%{state: :finished, outcome: :succeeded}) ==
               "badge-success"
    end
  end

  describe "kind_badge_class/1" do
    test "returns correct badge class for each notification kind" do
      assert StatusHelpers.kind_badge_class(:notification) == "badge-info"
      assert StatusHelpers.kind_badge_class(:direction) == "badge-warning"
      assert StatusHelpers.kind_badge_class(:flag) == "badge-accent"
      assert StatusHelpers.kind_badge_class(:escalation) == "badge-error"
      assert StatusHelpers.kind_badge_class(:failure) == "badge-error"
      assert StatusHelpers.kind_badge_class(:completion) == "badge-success"
      assert StatusHelpers.kind_badge_class(:info) == "badge-info"
      assert StatusHelpers.kind_badge_class(:unknown) == "badge-ghost"
    end
  end

  describe "status_dot_class/1" do
    test "returns correct background class for each status" do
      assert StatusHelpers.status_dot_class(:working) == "bg-info"
      assert StatusHelpers.status_dot_class(:waiting) == "bg-warning"
      assert StatusHelpers.status_dot_class(:succeeded) == "bg-success"
      assert StatusHelpers.status_dot_class(:failed) == "bg-error"
      assert StatusHelpers.status_dot_class(:unknown) == "bg-base-content/30"
    end
  end

  describe "format_ts_short/1" do
    test "formats DateTime as short time" do
      dt = ~U[2023-01-15 14:30:45Z]
      assert StatusHelpers.format_ts_short(dt) == "14:30:45"
    end

    test "returns empty string for non-DateTime" do
      assert StatusHelpers.format_ts_short(nil) == ""
      assert StatusHelpers.format_ts_short("invalid") == ""
    end
  end

  describe "format_ts_long/1" do
    test "formats DateTime as long timestamp" do
      dt = ~U[2023-01-15 14:30:45Z]
      assert StatusHelpers.format_ts_long(dt) == "2023-01-15 14:30:45 UTC"
    end

    test "returns empty string for non-DateTime" do
      assert StatusHelpers.format_ts_long(nil) == ""
      assert StatusHelpers.format_ts_long("invalid") == ""
    end
  end

  describe "flow_state/2" do
    test "returns :done for steps before current status" do
      assert StatusHelpers.flow_state(:starting, :working) == :done
      assert StatusHelpers.flow_state(:starting, :waiting) == :done
      assert StatusHelpers.flow_state(:working, :waiting) == :done
      assert StatusHelpers.flow_state(:waiting, :finished) == :done
    end

    test "returns :current for the current status" do
      assert StatusHelpers.flow_state(:starting, :starting) == :current
      assert StatusHelpers.flow_state(:working, :working) == :current
    end

    test "returns :todo for steps after current status" do
      assert StatusHelpers.flow_state(:working, :starting) == :todo
      assert StatusHelpers.flow_state(:waiting, :working) == :todo
    end

    test "returns :todo for invalid step or status" do
      assert StatusHelpers.flow_state(:invalid, :working) == :todo
      assert StatusHelpers.flow_state(:working, :invalid) == :todo
    end
  end

  describe "flow_step_class/1" do
    test "returns correct class for each flow step state" do
      assert StatusHelpers.flow_step_class(:done) == "step-primary"
      assert StatusHelpers.flow_step_class(:current) == "step-primary"
      assert StatusHelpers.flow_step_class(:todo) == ""
    end
  end

  describe "flow_step_marker/1" do
    test "returns check mark for done steps" do
      assert StatusHelpers.flow_step_marker(:done) == "✓"
    end

    test "returns nil for non-done steps" do
      assert StatusHelpers.flow_step_marker(:current) == nil
      assert StatusHelpers.flow_step_marker(:todo) == nil
    end
  end

  describe "flow_step_label/1" do
    test "returns correct label for each step" do
      assert StatusHelpers.flow_step_label(:starting) == "Starting"
      assert StatusHelpers.flow_step_label(:working) == "Working"
      assert StatusHelpers.flow_step_label(:waiting) == "Waiting"
      assert StatusHelpers.flow_step_label(:finished) == "Finished"
    end
  end

  describe "worker_flow/0" do
    test "returns the worker flow sequence" do
      assert StatusHelpers.worker_flow() == [:starting, :working, :waiting, :finished]
    end
  end
end
