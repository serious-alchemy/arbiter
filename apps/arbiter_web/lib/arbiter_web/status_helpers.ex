defmodule ArbiterWeb.StatusHelpers do
  @moduledoc """
  Shared helper functions for status badges, labels, and styling across LiveViews.

  These functions are extracted from dashboard_live, task_detail_live, and worker_detail_live
  to eliminate duplication and ensure consistent status/badge rendering across the app.
  """

  # Ordered run lifecycle for the step progress stepper (bd-1uu19b: the one
  # run vocabulary, `Arbiter.Workers.RunState`). A failed run is handled
  # separately in templates (it doesn't belong on the happy-path track).
  @worker_flow [:starting, :working, :waiting, :finished]

  def worker_flow, do: @worker_flow

  # ---- Run state (bd-1uu19b) ----

  @doc """
  The one atom a badge keys on for a run — a worker snapshot or an
  `Arbiter.Workers.Run` row: its `outcome` once `:finished`, its `state`
  before that. `nil` for anything without a `:state`.
  """
  def run_status(%{state: :finished} = run), do: Map.get(run, :outcome) || :finished
  def run_status(%{state: state}) when is_atom(state), do: state
  def run_status(_), do: nil

  @doc """
  A human label for a run — a worker snapshot or a `Run` row. Reads
  `waiting_on` to say what a waiting run is waiting for, and a starting
  snapshot's `meta.resume` to tell a resume from a fresh dispatch.
  """
  def run_label(%{state: :starting, meta: %{resume: true}}), do: "Resuming"
  def run_label(%{state: :waiting, waiting_on: :question}), do: "Waiting on you"
  def run_label(%{state: :waiting, waiting_on: :review_gate}), do: "In review"

  def run_label(run) do
    case run_status(run) do
      nil -> "Unknown"
      status -> worker_status_label(status)
    end
  end

  @doc """
  The roster tag for a run row: its kind, except that an `:implement` run the
  ReviewGate dispatched for a revise round (`role` "impl") is `"impl"`, apart
  from the authoring run.
  """
  def run_role(%{kind: :implement, role: "impl"}), do: "impl"
  def run_role(%{kind: kind}) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  def run_role(_), do: "implement"

  # ---- Status badges ----

  def difficulty_badge_class(nil), do: "badge-ghost"
  def difficulty_badge_class(0), do: "badge-success"
  def difficulty_badge_class(1), do: "badge-info"
  def difficulty_badge_class(2), do: "badge-secondary"
  def difficulty_badge_class(3), do: "badge-warning"
  def difficulty_badge_class(4), do: "badge-error"
  def difficulty_badge_class(_), do: "badge-ghost"

  # Keyed on `run_status/1`'s atom: a live run's state, a finished run's
  # outcome.
  def worker_status_class(%{} = run), do: worker_status_class(run_status(run))
  def worker_status_class(:starting), do: "badge-ghost"
  def worker_status_class(:working), do: "badge-info"
  def worker_status_class(:waiting), do: "badge-warning"
  def worker_status_class(:succeeded), do: "badge-success"
  def worker_status_class(:failed), do: "badge-error"
  def worker_status_class(:interrupted), do: "badge-warning"
  def worker_status_class(:handed_off), do: "badge-ghost"
  def worker_status_class(:finished), do: "badge-ghost"
  def worker_status_class(_), do: ""

  def worker_status_label(:starting), do: "Starting"
  def worker_status_label(:working), do: "Working"
  def worker_status_label(:waiting), do: "Waiting"
  def worker_status_label(:finished), do: "Finished"
  def worker_status_label(:succeeded), do: "Succeeded"
  def worker_status_label(:failed), do: "Failed"
  def worker_status_label(:interrupted), do: "Interrupted"
  def worker_status_label(:handed_off), do: "Handed off"

  def worker_status_label(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  def worker_status_label(other), do: to_string(other)

  def run_status_class(%{} = run), do: run_status_class(run_status(run))
  def run_status_class(:succeeded), do: "badge-success"
  def run_status_class(:failed), do: "badge-error"
  def run_status_class(:working), do: "badge-info"
  def run_status_class(:waiting), do: "badge-warning"
  def run_status_class(_), do: "badge-ghost"

  def kind_badge_class(:notification), do: "badge-info"
  def kind_badge_class(:direction), do: "badge-warning"
  def kind_badge_class(:flag), do: "badge-accent"
  def kind_badge_class(:escalation), do: "badge-error"
  def kind_badge_class(:failure), do: "badge-error"
  def kind_badge_class(:completion), do: "badge-success"
  def kind_badge_class(:info), do: "badge-info"
  def kind_badge_class(_), do: "badge-ghost"

  def status_dot_class(:working), do: "bg-info"
  def status_dot_class(:waiting), do: "bg-warning"
  def status_dot_class(:succeeded), do: "bg-success"
  def status_dot_class(:failed), do: "bg-error"
  def status_dot_class(_), do: "bg-base-content/30"

  # ---- Timestamp formatting ----

  def format_ts_short(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_ts_short(_), do: ""

  def format_ts_long(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_ts_long(_), do: ""

  # ---- Flow/stepper rendering ----

  def flow_state(step, status) do
    step_idx = Enum.find_index(@worker_flow, &(&1 == step))
    status_idx = Enum.find_index(@worker_flow, &(&1 == status))

    cond do
      is_nil(step_idx) or is_nil(status_idx) -> :todo
      step_idx < status_idx -> :done
      step_idx == status_idx -> :current
      true -> :todo
    end
  end

  def flow_step_class(:done), do: "step-primary"
  def flow_step_class(:current), do: "step-primary"
  def flow_step_class(:todo), do: ""

  def flow_step_marker(:done), do: "✓"
  def flow_step_marker(_), do: nil

  def flow_step_label(:starting), do: "Starting"
  def flow_step_label(:working), do: "Working"
  def flow_step_label(:waiting), do: "Waiting"
  def flow_step_label(:finished), do: "Finished"
end
