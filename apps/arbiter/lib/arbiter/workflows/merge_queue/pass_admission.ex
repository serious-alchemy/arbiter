defmodule Arbiter.Workflows.MergeQueue.PassAdmission do
  @moduledoc """
  Whether a CI fix pass or a conflict pass may start now (bd-741sid).

  A pass is an ordinary run on its ticket: it registers under the ticket id and
  takes the ticket back In progress (`return_to_work`). A ticket in Merging
  holds no slot (bd-asxw4e), so the pass must get one — the same rule
  `Arbiter.Worker.ResumeSlot` applies to an automatic resume:

    * a free slot → the pass starts;
    * no free slot → it is handed to the scheduler's **fast lane**
      (`Arbiter.Board.Autopilot.defer_resume/4`, kind `:fix_pass` or
      `:conflict`), which starts it the moment a slot frees, ahead of every
      Ready ticket — it is work already in progress, returning from Merging;
    * a ticket already In progress (a pass on a ticket whose run is still
      working) needs no new slot.

  An admitted pass holds its slot from the moment it is admitted
  (`with_slot/2`), not from the moment its agent is up. A ticket pulled out
  of the merge queue (`Arbiter.Tasks.PullRequest.pull/1`) gets no pass.

  A pass runs on the primary, so with the primary's worker cap at 0
  (`Arbiter.Nodes.LocalCapacity`) it is held with `{:error, {:no_node_capacity,
  info}}` before any slot is taken; the ticket stays in Merging.

  The replay carries `slot_admitted: true` and is not re-checked. Like every
  deferral, the queue is in memory: a restart loses it, and the ticket's
  Watchdog — restarted from the row by the boot reconciler — sees the same red
  CI or conflict and asks again.
  """

  alias Arbiter.Nodes.LocalCapacity
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Worker
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Worker.StopReason

  require Logger

  @type kind :: :fix_pass | :conflict

  @doc """
  Admit a `kind` pass on `task`. `:ok` to start it now; `{:deferred, info}` when
  it is waiting in the fast lane for a slot; `{:error, reason}` when the
  scheduler could not take it (it is refused rather than run over the cap), or
  `{:error, :pulled}` when the ticket was pulled out of the merge queue.

  `args` are the dispatcher's own: `slot_admitted: true` marks a replay the
  scheduler already admitted, and `:defer_resume` is a test seam — a 3-arity
  function standing in for the configured deferrer.
  """
  @spec admit(Issue.t(), kind(), map()) :: :ok | {:deferred, map()} | {:error, term()}
  def admit(%Issue{} = task, kind, args) when kind in [:fix_pass, :conflict] and is_map(args) do
    if PullRequest.pulled?(task) do
      Logger.info(
        "PassAdmission: #{kind} pass for #{task.id} not started — the ticket was pulled out " <>
          "of the merge queue"
      )

      {:error, :pulled}
    else
      with :ok <- local_capacity(task, kind), do: admit_slot(task, kind, args)
    end
  end

  # RW8: a pass runs on the primary, and the primary's cap covers it
  # (`Arbiter.Nodes.LocalCapacity`). Only a cap of 0 holds one — a pass replaces
  # its own ticket's slot, so it is never held for merely being at the cap — and
  # the hold is `{:error, {:no_node_capacity, info}}`: the Watchdog counts no
  # attempt for it and asks again on its next poll.
  defp local_capacity(%Issue{id: id, workspace_id: ws_id}, kind) do
    local_kind = if kind == :conflict, do: :conflict_pass, else: :fix_pass

    LocalCapacity.admit(id, local_kind,
      reason: {:local_only, :follow_up},
      workspace_id: ws_id
    )
  end

  defp admit_slot(task, kind, args) do
    case ResumeSlot.admit(task,
           origin: :automatic,
           slot_admitted: Map.get(args, :slot_admitted) == true
         ) do
      {:ok, _how} -> :ok
      {:defer, info} -> defer(task, kind, args, info)
      {:error, _} = error -> error
    end
  end

  @doc """
  Run `start` holding the slot `admit/3` granted. `start` is the rest of the
  pass's dispatch: its worktree, its worker, its agent.

  A Merging ticket goes back to work (`return_to_work`) before `start` runs,
  not after. Provisioning a worktree and starting an agent take seconds, and a
  ticket still Merging in that window reads as a free slot to the scheduler,
  which could promote a Ready ticket into it. If `start` fails, a ticket this
  took back to work returns to Merging (`PullRequest.back_to_merging/1`).
  The exception is a ticket another run holds by then: the slot is that run's.
  """
  @spec with_slot(Issue.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_slot(%Issue{id: task_id}, start) when is_function(start, 0) do
    took? = take_slot(task_id)

    case start.() do
      {:ok, _} = started ->
        started

      failed ->
        if took? and not run_live?(task_id), do: PullRequest.back_to_merging(task_id)
        failed
    end
  end

  @doc """
  The pass's worker registered but its agent never started. Fail the worker
  (`:spawn_failed`) rather than leave it `:idle`: an idle pass holds the
  ticket's key, every later pass would read it as one still running, and it
  would keep the ticket In progress. A failed pass sends its ticket back to
  Merging.
  """
  @spec agent_failed(pid(), term()) :: :ok
  def agent_failed(worker_pid, reason) when is_pid(worker_pid) do
    _ = Worker.fail(worker_pid, StopReason.spawn_failed(reason))
    :ok
  catch
    :exit, _ -> :ok
  end

  # Read fresh: a replay's task struct, or the Watchdog's, can predate a move.
  defp take_slot(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{state: :merging}} -> Issue.back_to_work(task_id) == :ok
      _ -> false
    end
  end

  # A run still working the ticket. It is not this pass, which never started
  # (or was failed above); it is one that took the ticket to work meanwhile.
  # A busy worker counts as live: its ticket must not go back to Merging
  # under it.
  defp run_live?(task_id) do
    case Worker.whereis(task_id) do
      nil -> false
      pid -> not Worker.finished?(Worker.state(pid))
    end
  catch
    :exit, {:timeout, _} -> true
    :exit, _ -> false
  end

  defp defer(%Issue{id: task_id}, kind, args, info) do
    defer = Map.get(args, :defer_resume) || configured_deferrer()
    replay = Map.drop(args, [:defer_resume, :task, :workspace, :slot_admitted])

    case defer.(task_id, kind, args: replay) do
      :ok ->
        Logger.info(
          "PassAdmission: #{kind} pass for #{task_id} waits in the fast lane for a slot " <>
            "(cap #{info.cap}, held by #{inspect(info.holders)})"
        )

        {:deferred, Map.put(info, :deferred, true)}

      other ->
        Logger.warning(
          "PassAdmission: could not queue the #{kind} pass for #{task_id} " <>
            "(#{inspect(other)}); refusing it at the full cap instead"
        )

        {:error, {:slot_cap_full, info}}
    end
  end

  # `:arbiter, :resume_deferrer` — the board autopilot everywhere but the test
  # env, which records instead (see config/test.exs), exactly as for resumes.
  defp configured_deferrer do
    module = Application.get_env(:arbiter, :resume_deferrer, Arbiter.Board.Autopilot)
    &module.defer_resume/3
  end
end
