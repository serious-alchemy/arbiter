defmodule Arbiter.Worker.HeldResume do
  @moduledoc """
  The ticket-side record of a resume held for the primary's own capacity
  (bd-3fbj83).

  `Arbiter.Worker.Dispatch` defers an automatic resume the primary has no room
  for into `Arbiter.Board.Autopilot` (`held_for: :local_capacity`), whose queue
  lives only in memory. A restart emptied it: nothing re-queued the resume, the
  ticket stayed In progress with nobody working it, and it kept holding a slot.

  So the deferral also writes a `held_resume` marker into the ticket's
  `review_gate_state` (beside the `pass` and `ci_wait` markers) and clears it when
  the queue replays or drops the entry.
  `Arbiter.Workers.Reconciler.reconcile_held_resumes/1` reads it at boot and
  puts the entry back in the queue. Best-effort: a failed write only loses the
  restart guarantee, never the deferral.
  """

  alias Arbiter.Tasks.PullRequest

  require Logger

  @kinds %{"resume" => :resume, "resume_session" => :resume_session}

  @doc "Record that `task_id` has a `kind` resume held for local capacity."
  @spec mark(String.t(), atom(), DateTime.t()) :: :ok
  def mark(task_id, kind, now \\ DateTime.utc_now()) when is_binary(task_id) and is_atom(kind),
    do: put(task_id, %{kind: kind, held_at: now})

  @doc "Clear the marker (the queue replayed or dropped the entry)."
  @spec clear(String.t()) :: :ok
  def clear(task_id) when is_binary(task_id), do: put(task_id, nil)

  @doc "The ticket's held resume kind (`:resume` / `:resume_session`), or `nil`."
  @spec stored_kind(map() | nil) :: atom() | nil
  def stored_kind(%{review_gate_state: %{"held_resume" => %{"kind" => kind}}}),
    do: Map.get(@kinds, kind)

  def stored_kind(_ticket), do: nil

  defp put(task_id, marker) do
    case PullRequest.record_review_gate(task_id, %{held_resume: marker}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("HeldResume: write failed for #{task_id}: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.debug("HeldResume: write raised for #{task_id}: #{Exception.message(e)}")
      :ok
  end
end
