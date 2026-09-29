defmodule ArbiterWeb.Api.QueueController do
  @moduledoc """
  REST endpoints for task-queue operations.

  Routes:

    * `POST /api/queue/:task_id/retry_auto_resolve` — re-arm one more auto-resolve
      attempt for a task whose merge Watchdog is parked after exhausting
      `max_auto_resolve_attempts` on a `:ci_failed` block (bd-bspakl).
    * `POST /api/queue/:task_id/restart_watchdog` — mint a fresh Watchdog for a
      Merging ticket whose Watchdog died outright, started from the ticket's
      row (bd-8jixav, bd-741sid). Distinct from the above, which only re-arms
      an already-running Watchdog.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Worker.Watchdog

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc """
  Re-arm one more auto-resolve attempt on a task's merge Watchdog.

  Only meaningful once the Watchdog has exhausted `max_auto_resolve_attempts`
  on a `:ci_failed` block and parked indefinitely (bd-bspakl) — the dashboard's
  "Retry" action for that escalation calls this instead of the worker resume
  action, which is correctly refused in this state.

  Returns `{"retried": true, "task_id": "..."}` on success.

  Errors:

    * 404 — no Watchdog is currently running for this task.
    * 400 — the Watchdog exists but isn't parked on an exhausted `:ci_failed`
      block or an exhausted conflict auto-resolve (bd-4olwyg), so there's
      nothing to re-arm.
  """
  def retry_auto_resolve(conn, %{"task_id" => task_id})
      when is_binary(task_id) and task_id != "" do
    case Watchdog.retry_auto_resolve(task_id) do
      :ok ->
        json(conn, %{retried: true, task_id: task_id})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :not_parked_on_ci_failed} ->
        {:error,
         {:invalid_request,
          "task #{task_id} isn't parked on an exhausted :ci_failed block or an exhausted " <>
            "conflict auto-resolve — nothing to re-arm"}}

      {:error, :busy} ->
        {:error, {:busy, "task #{task_id}'s watchdog is busy polling — try again in a moment"}}
    end
  end

  def retry_auto_resolve(_conn, _params) do
    {:error, {:invalid_request, "task_id path parameter is required"}}
  end

  @doc """
  Mint a **fresh** merge Watchdog for a Merging ticket whose Watchdog has died,
  started from the ticket's row (bd-8jixav, bd-741sid).

  A Watchdog is a `:temporary` process — when it crashes it is gone for good,
  silently — leaving the ticket Merging with a genuinely open MR nothing is
  polling. `retry_auto_resolve` cannot recover that: it messages an
  already-running Watchdog and 404s once the process is gone.

  Returns `{"restarted": true, "task_id": "..."}` on success. Refusals are
  phrased by `Arbiter.Worker.Watchdog.restart_refusal/2`:

    * 404 — there is no such ticket.
    * 409 — a Watchdog is already running. Refused rather than stacked: two
      Watchdogs polling one MR would race the merge and double-dispatch fix
      passes.
    * 400 — the ticket is not Merging, has no PR on record, or its merger
      adapter cannot be resolved; or the Watchdog failed to start.

  An explicit restart (`arb queue restart-watchdog`): a ticket pulled out of
  the merge queue (`Arbiter.Tasks.PullRequest.pull/1`) goes back in it.
  """
  def restart_watchdog(conn, %{"task_id" => task_id})
      when is_binary(task_id) and task_id != "" do
    case Watchdog.restart(task_id, clear_pull: true) do
      :ok ->
        json(conn, %{restarted: true, task_id: task_id})

      {:error, reason} ->
        case Watchdog.restart_refusal(task_id, reason) do
          {:not_found, _message} -> {:error, :not_found}
          {:conflict, message} -> {:error, {:conflict, message}}
          {_invalid_or_internal, message} -> {:error, {:invalid_request, message}}
        end
    end
  end

  def restart_watchdog(_conn, _params) do
    {:error, {:invalid_request, "task_id path parameter is required"}}
  end

  @rerun_modes %{
    "auto" => :auto,
    "failed_jobs" => :failed_jobs,
    "all_jobs" => :all_jobs,
    "workflow" => :workflow
  }

  @doc """
  Re-run CI for a task's PR, choosing the **granularity** of the re-run
  (bd-5mzzww).

  Arbiter had no CI-retry verb at all: every retry was a human clicking the
  forge UI, and the button a human reaches for first — "re-run failed jobs" —
  reuses every job that already succeeded. When the failing check tests an
  artifact an *earlier job in the same run* produced (a per-branch review app, a
  built image), that re-run re-tests the identical stale input and is
  deterministically guaranteed to fail again. In the incident this endpoint
  exists for, two such human re-runs failed identically over 19 hours; only a
  full re-dispatch went green.

  Body params (all optional):

    * `mode` — `auto` (default), `failed_jobs`, `all_jobs`, `workflow`.
    * `workflow` — workflow name or file basename, when several runs failed.
    * `inputs` — `workflow_dispatch` inputs; supplying any forces `workflow`
      mode, because only a fresh dispatch can carry them. Pairing inputs with
      an explicit `failed_jobs`/`all_jobs` mode is rejected (422) rather than
      silently dropping them.

  Returns `{"rerun": true, "task_id": ..., "mode": ..., "run_id": ...}`.

  Errors:

    * 404 — no Watchdog is currently running for this task.
    * 400 — unknown mode, or the merger for this task has no re-run primitive.
    * 503 — the Watchdog is busy polling.
  """
  def rerun_ci(conn, %{"task_id" => task_id} = params)
      when is_binary(task_id) and task_id != "" do
    with {:ok, mode} <- parse_mode(params),
         {:ok, inputs} <- parse_inputs(params) do
      opts =
        %{mode: mode, inputs: inputs}
        |> put_workflow(params)

      case Watchdog.rerun_ci(task_id, opts) do
        {:ok, result} ->
          json(conn, Map.merge(%{rerun: true, task_id: task_id}, result))

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, :unsupported} ->
          {:error,
           {:invalid_request,
            "task #{task_id}'s merger has no CI re-run primitive — re-run it from the forge UI"}}

        {:error, :busy} ->
          {:error, {:busy, "task #{task_id}'s watchdog is busy polling — try again in a moment"}}

        {:error, reason} ->
          {:error, {:invalid_request, "CI re-run failed for #{task_id}: #{inspect(reason)}"}}
      end
    end
  end

  def rerun_ci(_conn, _params) do
    {:error, {:invalid_request, "task_id path parameter is required"}}
  end

  @doc """
  Record an "this CI failure is infrastructure, not this diff" verdict on a task
  parked on a `:ci_failed` block, reclassifying the park as
  `:ci_failed_external` (bd-5mzzww).

  Before this existed, a worker that correctly diagnosed a day-wide infra
  failure had nowhere to put the conclusion: the park stayed
  indistinguishable from genuinely broken code, and the diagnosis sat in a chat
  log hours before a human reached the same answer independently.

  Requires a `note` — the evidence. An unevidenced "it's not me" is not
  something an operator can act on.

  Errors:

    * 404 — no Watchdog is currently running for this task.
    * 400 — no note, or the task is not parked on a `:ci_failed` block.
    * 503 — the Watchdog is busy polling.
  """
  def mark_ci_external(conn, %{"task_id" => task_id} = params)
      when is_binary(task_id) and task_id != "" do
    case trimmed(params["note"]) do
      nil ->
        {:error,
         {:invalid_request,
          "a `note` is required: an \"infra, not my diff\" verdict without evidence is not " <>
            "something an operator can act on"}}

      note ->
        case Watchdog.mark_ci_external(task_id, note) do
          :ok ->
            json(conn, %{marked: true, task_id: task_id, park_reason: "ci_failed_external"})

          {:error, :not_found} ->
            {:error, :not_found}

          {:error, :not_parked_on_ci_failed} ->
            {:error,
             {:invalid_request,
              "task #{task_id} is not parked on a :ci_failed block — there is nothing to " <>
                "reclassify as external"}}

          {:error, :busy} ->
            {:error,
             {:busy, "task #{task_id}'s watchdog is busy polling — try again in a moment"}}
        end
    end
  end

  def mark_ci_external(_conn, _params) do
    {:error, {:invalid_request, "task_id path parameter is required"}}
  end

  defp parse_mode(params) do
    case params["mode"] do
      nil ->
        {:ok, :auto}

      raw when is_binary(raw) ->
        case Map.fetch(@rerun_modes, raw) do
          {:ok, mode} ->
            {:ok, mode}

          :error ->
            {:error,
             {:invalid_request,
              "unknown mode #{inspect(raw)} — expected one of: " <>
                (@rerun_modes |> Map.keys() |> Enum.sort() |> Enum.join(", "))}}
        end

      other ->
        {:error, {:invalid_request, "mode must be a string, got: #{inspect(other)}"}}
    end
  end

  defp parse_inputs(params) do
    case params["inputs"] do
      nil -> {:ok, %{}}
      map when is_map(map) -> {:ok, map}
      other -> {:error, {:invalid_request, "inputs must be an object, got: #{inspect(other)}"}}
    end
  end

  defp put_workflow(opts, params) do
    case trimmed(params["workflow"]) do
      nil -> opts
      wf -> Map.put(opts, :workflow, wf)
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_), do: nil
end
