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
  alias Arbiter.Tasks.PullRequest
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
  Persist the re-run count (and the failing test set that earned it) for `head`
  on the ticket, so a restarted Watchdog does not hand a head a fresh budget.
  Only the newest head is kept: heads only move forward. Best-effort.
  """
  @spec save_rerun(String.t(), String.t() | nil, pos_integer(), [String.t()] | nil) :: :ok
  def save_rerun(_task_id, head, _count, _set) when head in [nil, ""], do: :ok

  def save_rerun(task_id, head, count, set) do
    case PullRequest.record_review_gate(task_id, %{
           ci_triage_rerun: %{head: head, count: count, set: set}
         }) do
      :ok -> :ok
      {:error, why} -> Logger.debug("CiTriageLog: rerun count write failed: #{inspect(why)}")
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  The persisted `%{count, set}` for `head`, or `nil` when the ticket has none for
  that head (or the read fails).
  """
  @spec load_rerun(String.t(), String.t()) ::
          %{count: pos_integer(), set: [String.t()] | nil} | nil
  def load_rerun(task_id, head) do
    case Ash.get(Issue, task_id) do
      {:ok,
       %{review_gate_state: %{"ci_triage_rerun" => %{"head" => ^head, "count" => count} = r}}}
      when is_integer(count) and count > 0 ->
        %{count: count, set: if(is_list(r["set"]), do: Enum.map(r["set"], &to_string/1))}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

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
