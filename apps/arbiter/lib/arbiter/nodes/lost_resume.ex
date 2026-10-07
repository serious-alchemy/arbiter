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

  No resume attempt is consumed: the attempt cap lives in the Worker's
  `meta[:resume_attempts]` and bounds an agent that stopped on its own.

  Configuration, `config :arbiter, :node_lost_resume`: `enabled:` (default `true`;
  off in test), `resume_fun:` (`task_id -> term`, for tests).
  """

  require Logger

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
end
