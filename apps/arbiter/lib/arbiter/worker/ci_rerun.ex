defmodule Arbiter.Worker.CIRerun do
  @moduledoc """
  Re-run CI for a task's PR — the one entry point behind the `ci_rerun` MCP tool
  and `POST /api/queue/:task_id/rerun_ci` (and so `arb queue rerun-ci`), so a
  PR re-runs the same way whichever surface asks (bd-dtfe9x, D-W-18).

  Prefers the task's live `Arbiter.Worker.Watchdog`, which already holds the
  adapter, the PR ref and the per-repo config. With **no** Watchdog running it
  falls back to resolving the merger adapter straight off the task's workspace
  and re-running against the PR ref recorded on the task: a PR whose Watchdog
  has died is still retryable (the #1447 shape), whichever surface the retry
  comes from. The result says which way it went in `:via`.

  Pure of any caller's authority: callers authorize the task first (MCP scope /
  `ArbiterWeb.ApiPolicy`).
  """

  alias Arbiter.Mergers
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.Watchdog

  @type error ::
          :not_found
          | :unsupported
          | :busy
          | {:no_pr, String.t()}
          | {:no_workspace, String.t()}
          | {:failed, term()}

  @doc """
  Re-run CI for `task_id`. `opts` is the `Watchdog.rerun_ci/2` map (`:mode`,
  `:workflow`, `:inputs`).
  """
  @spec rerun(String.t(), map()) :: {:ok, map()} | {:error, error()}
  def rerun(task_id, opts) when is_binary(task_id) and is_map(opts) do
    case Watchdog.rerun_ci(task_id, opts) do
      {:ok, result} -> {:ok, Map.merge(%{task_id: task_id, via: "watchdog"}, result)}
      {:error, :not_found} -> rerun_via_workspace(task_id, opts)
      {:error, :unsupported} -> {:error, :unsupported}
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> {:error, {:failed, reason}}
    end
  end

  defp rerun_via_workspace(task_id, opts) do
    with {:ok, %Issue{} = issue} <- fetch_issue(task_id),
         {:ok, pr_ref} <- pr_ref(issue),
         {:ok, workspace} <- fetch_workspace(issue) do
      # bd-73zv62: the task's repo's merger, not the workspace-level one.
      adapter = Mergers.for_repo(workspace, issue.repo)

      if function_exported?(adapter, :rerun_ci, 2) do
        Mergers.prepare_with_repo(workspace, issue.repo)

        case adapter.rerun_ci(pr_ref, opts) do
          {:ok, result} -> {:ok, Map.merge(%{task_id: task_id, via: "workspace"}, result)}
          {:error, reason} -> {:error, {:failed, reason}}
        end
      else
        {:error, :unsupported}
      end
    end
  end

  defp fetch_issue(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = issue} -> {:ok, issue}
      _ -> {:error, :not_found}
    end
  end

  defp pr_ref(%Issue{id: id, pr_ref: ref}) when ref in [nil, ""], do: {:error, {:no_pr, id}}
  defp pr_ref(%Issue{pr_ref: ref}), do: {:ok, ref}

  defp fetch_workspace(%Issue{id: id, workspace_id: ws_id}) do
    case ws_id && Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> {:error, {:no_workspace, id}}
    end
  end

  @doc "A human message for an `error()` — the wording both surfaces share."
  @spec describe_error(error(), String.t()) :: String.t()
  def describe_error(:not_found, task_id), do: "task #{task_id} not found"

  def describe_error(:unsupported, task_id),
    do:
      "task #{task_id}'s merger adapter does not support re-running CI — only " <>
        "hosted forges with a workflow API do (the `direct` strategy has no CI to re-run)"

  def describe_error(:busy, task_id),
    do:
      "task #{task_id}'s watchdog is busy polling — try again in a moment rather " <>
        "than repeating the call, since the original request may still land"

  def describe_error({:no_pr, id}, _task_id),
    do: "task #{id} has no PR recorded (no `pr_ref`), so there is no CI run to re-run"

  def describe_error({:no_workspace, id}, _task_id),
    do: "task #{id} has no readable workspace to resolve a merger from"

  def describe_error({:failed, reason}, task_id),
    do: "CI re-run failed for #{task_id}: #{inspect(reason)}"
end
