defmodule Arbiter.Worker.CiTriageLog do
  @moduledoc """
  The Watchdog's side of the deterministic CI triage (GitHub #1144): the
  per-head re-run budget and the ticket record of each decision.

  `Arbiter.Workflows.MergeQueue.CiTriage` says what a red head is; the Watchdog
  acts on it (re-run, hold, or spawn a fix pass) and calls `record/4` for every
  such decision, so a ticket's notes show the class, the action and the evidence
  (job names, failure reasons, matched files) instead of an agent's missing
  closing message.
  """

  alias Arbiter.Mergers
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue.CiTriage

  require Logger

  @default_budget 2

  @doc """
  Re-runs of the failed jobs allowed per head before a fix pass
  (`merge.ci.triage_rerun_budget`, a repo entry overriding the workspace's).
  Default #{@default_budget}; `0` turns the triage re-runs off.
  """
  @spec budget(Workspace.t() | nil, String.t() | nil) :: non_neg_integer()
  def budget(%Workspace{} = workspace, repo) do
    case workspace |> Mergers.merge_config(repo) |> Map.get("ci") do
      %{"triage_rerun_budget" => n} when is_integer(n) and n >= 0 -> n
      _ -> @default_budget
    end
  rescue
    _ -> @default_budget
  end

  def budget(_workspace, _repo), do: @default_budget

  @doc """
  Append the decision to the ticket's notes (atomically, so a worker's own
  concurrent notes survive) and log it. Best-effort: a failed write never blocks
  the remediation.
  """
  @spec record(String.t(), String.t() | nil, String.t(), CiTriage.result()) :: :ok
  def record(task_id, head, action, triage) do
    text =
      "## CI triage (#{DateTime.to_iso8601(DateTime.utc_now())})\n\n" <>
        "head #{head || "(unknown)"}: #{action}\n\n" <> CiTriage.render(triage)

    Logger.info("Worker.Watchdog: task=#{task_id} head=#{head}: #{action} [#{triage.class}]")

    with {:ok, task} <- Ash.get(Issue, task_id),
         {:ok, _} <- Ash.update(task, %{append_notes: text}, action: :update) do
      :ok
    else
      other ->
        Logger.debug("CiTriageLog: ticket note for #{task_id} not written: #{inspect(other)}")
        :ok
    end
  rescue
    e ->
      Logger.debug("CiTriageLog: ticket note for #{task_id} raised: #{Exception.message(e)}")
      :ok
  end
end
