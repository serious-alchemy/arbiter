defmodule Arbiter.Nodes.LostResume do
  @moduledoc """
  The automatic resume of a run whose node was lost (`docs/design/remote-workers.md`
  §10.3): "auto-resume re-dispatches via Placement (another node or local per
  mode)".

  A Worker that finds its node gone stamps the run `interrupted` / `:node_lost` and
  asks for this. It is `Arbiter.Workers.Reconciler`'s boot-time resume of an
  interrupted run (same entry point, same `:automatic` origin, so a ticket that no
  longer holds a slot defers to the scheduler instead of jumping the queue), run
  off the Worker's process: `Dispatch.resume/2` stops the prior worker itself.
  The new spawn provisions a fresh shadow from the home clone, which holds the last
  checkpoint, and `claude --resume` finds the mirrored transcript at the same cwd.

  A ticket with **no worktree** (`research`, `task`) has nothing to resume: the resume
  refuses with `:no_outpost`, so it is requeued (`active` -> `queued`, the door
  `Worker.AuthDeath` uses) for a fresh dispatch, `notes` intact (the fresh prompt says
  an earlier run wrote them). After `max_redispatches/0` consecutive node/pod
  interruptions it stays `active` and one `ticket_stuck` escalation names the cause.

  No resume attempt is consumed: the attempt cap lives in the Worker's
  `meta[:resume_attempts]` and bounds an agent that stopped on its own.

  Configuration, `config :arbiter, :node_lost_resume`: `enabled:` (default `true`;
  off in test), `resume_fun:` (`task_id -> term`, for tests).
  """

  require Ash.Query
  require Logger

  alias Arbiter.Messages.Escalation
  alias Arbiter.Tasks.Issue
  alias Arbiter.Workers.Run

  @max_redispatches 3
  @node_categories ["node_lost", "pod_disrupted", "preempted"]

  @doc """
  How many consecutive node/pod interruptions a run with no worktree is requeued
  through before the ticket is escalated instead.
  """
  @spec max_redispatches() :: pos_integer()
  def max_redispatches, do: @max_redispatches

  @doc "Resume `task_id` in the background. `:ok` whether or not it is enabled."
  @spec schedule(String.t() | nil) :: :ok
  def schedule(nil), do: :ok

  def schedule(task_id) when is_binary(task_id) do
    config = Application.get_env(:arbiter, :node_lost_resume, [])

    if Keyword.get(config, :enabled, true) do
      resume_fun = Keyword.get(config, :resume_fun, &resume/1)

      {:ok, _} =
        Task.Supervisor.start_child(Arbiter.TaskSupervisor, fn -> run(resume_fun, task_id) end)
    end

    :ok
  end

  defp run(resume_fun, task_id) do
    case resume_fun.(task_id) do
      {:ok, _} ->
        Logger.info("Nodes: resumed task #{task_id} after its node was lost")

      # A ticket with no worktree (research / task) has nothing to resume: requeue it.
      {:error, :no_outpost} ->
        redispatch_fresh(task_id)

      other ->
        Logger.warning(
          "Nodes: could not resume task #{task_id} after its node was lost: " <>
            inspect(other, limit: 5)
        )
    end
  rescue
    e ->
      Logger.warning(
        "Nodes: resume of task #{task_id} after node loss raised: #{Exception.message(e)}"
      )
  end

  defp resume(task_id),
    do: Arbiter.Workers.Reconciler.default_resume(%Arbiter.Tasks.Issue{id: task_id})

  @doc false
  @spec run_now(String.t()) :: :ok
  def run_now(task_id) do
    config = Application.get_env(:arbiter, :node_lost_resume, [])
    run(Keyword.get(config, :resume_fun, &resume/1), task_id)
  end

  # No worktree to resume: put the ticket back in the queue, bounded.
  defp redispatch_fresh(task_id) do
    with {:ok, %Issue{state: state} = task} when state in [:active, :merging] <-
           Ash.get(Issue, task_id) do
      n = consecutive_interruptions(task_id)

      if n > @max_redispatches do
        escalate_cap(task, n)
      else
        stop_prior_worker(task_id)

        case Ash.update(task, %{}, action: :requeue) do
          {:ok, _} ->
            Logger.info(
              "Nodes: task #{task_id} has no worktree to resume after its node was lost; " <>
                "requeued for a fresh dispatch (interruption #{n} of #{@max_redispatches})"
            )

          {:error, e} ->
            Logger.warning("Nodes: could not requeue task #{task_id}: #{inspect(e)}")
        end
      end
    end

    :ok
  end

  # Newest-first run rows, counting the unbroken streak of node/pod interruptions.
  defp consecutive_interruptions(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id and kind == :implement)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.read!()
    |> Enum.take_while(&(&1.outcome == :interrupted and &1.stop_category in @node_categories))
    |> length()
  end

  defp stop_prior_worker(task_id) do
    case Arbiter.Worker.whereis(task_id) do
      pid when is_pid(pid) -> Arbiter.Worker.stop(pid, :normal, 5_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp escalate_cap(%Issue{id: id, workspace_id: ws_id}, n) do
    Escalation.post(%{
      kind: :ticket_stuck,
      from_ref: "system",
      workspace_id: ws_id,
      task_ref: id,
      subject: "#{id} stuck — its run was preempted / lost its node #{n} times in a row",
      body:
        "The last #{n} runs of #{id} were interrupted by a preempted pod or a lost node " <>
          "(not a failure of the task). It has no worktree to resume, and Arbiter requeued it " <>
          "#{@max_redispatches} times already, so it is left active. Check the cluster for " <>
          "what keeps preempting it, then `arb worker stop` + demote + promote to retry."
    })
  rescue
    e -> Logger.warning("Nodes: could not escalate task #{id}: #{Exception.message(e)}")
  end
end
