defmodule Arbiter.Worker.CiSync do
  @moduledoc """
  Keeps a CI-failure remediation from re-testing a stale branch (bd-5owt7w).

  On vstim 44% of three days' failed pipelines were one test that `main` had
  already fixed: the Watchdog's `:ci_failed` auto-resolve and `ci_rerun` kept
  re-testing MR heads that did not contain the fix, each attempt failing the
  same way and burning budget until the lane escalated. bd-5z9yvb synced a
  branch before *merging*; nothing synced it before a *CI-failure remediation*.

  Two pure-ish questions, shared by the Watchdog's auto-resolve loop and the
  `ci_rerun` entry points (`Arbiter.Worker.CIRerun`) so they answer alike on
  every forge:

    * `check/4` — does the head lack target commits? Same probe and
      `merge.require_up_to_date` / `merge.up_to_date_tolerance` knobs as the
      merge-time check (`Arbiter.Worker.MergeFreshness`). The sync itself is the
      adapter's `update_branch` (merge or rebase per `merge.sync_strategy`).
    * `target_hold/3` — is the *target* branch's own latest pipeline red? Then
      no MR branch can go green by being fixed or re-run, and an attempt spent
      on one is wasted: `"target branch red: <pipeline>"` names the hold.

  `rerun/4` is `ci_rerun` with the first question asked up front: a stale head
  is synced instead of re-run (the new head gets a pipeline of its own).
  """

  alias Arbiter.Mergers
  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Worker.MergeFreshness

  require Logger

  @doc "`:fresh`, `{:stale, behind}` or `{:unknown, reason}` for `head` vs. `base`."
  @spec check(map() | nil, String.t() | nil, String.t() | nil, String.t() | nil) ::
          :fresh | {:stale, pos_integer()} | {:unknown, term()}
  def check(workspace, repo, base, head),
    do: MergeFreshness.check(workspace, LocalCompare.repo_path(workspace, repo), base, head)

  @doc """
  `"target branch red: <pipeline>"` when `base`'s newest settled pipeline failed,
  else `nil`. Fails open: an adapter with no `branch_pipeline/3`, a read error or
  a branch with no settled pipeline holds nothing.
  """
  @spec target_hold(module(), String.t(), String.t() | nil) :: String.t() | nil
  def target_hold(adapter, mr_ref, base) when is_binary(base) and base != "" do
    with true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :branch_pipeline, 3),
         {:ok, %{status: "failed"} = pipeline} <- adapter.branch_pipeline(mr_ref, base, %{}) do
      "target branch red: " <> describe_pipeline(base, pipeline)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def target_hold(_adapter, _mr_ref, _base), do: nil

  defp describe_pipeline(base, pipeline) do
    id = Map.get(pipeline, :id)
    url = Map.get(pipeline, :url)
    sha = pipeline |> Map.get(:sha) |> short_sha()

    ["#{base} pipeline #{id}", sha && "on #{sha}", url && "(#{url})"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp short_sha(sha) when is_binary(sha) and sha != "", do: String.slice(sha, 0, 8)
  defp short_sha(_), do: nil

  @doc """
  Re-run CI for `mr_ref` through `adapter` — unless its head is behind the
  target, in which case the branch is synced instead (`update_branch`) and the
  result says so: `{:ok, %{action: :synced, behind: n, head: sha, base: ref, ...}}`.
  A sync that does not apply is `{:error, {:sync_failed, reason}}`. A head that
  is current, or one this cannot tell about, re-runs as before.

  `ctx` is `%{workspace: ws, repo: repo}`.
  """
  @spec rerun(module(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def rerun(adapter, mr_ref, opts, ctx) do
    case stale_head(adapter, mr_ref, ctx) do
      {:stale, behind, head, base} -> sync(adapter, mr_ref, ctx, behind, head, base)
      _ -> adapter.rerun_ci(mr_ref, opts)
    end
  end

  defp stale_head(adapter, mr_ref, ctx) do
    with {:ok, %{head_sha: head, base_ref: base}} when is_binary(head) and is_binary(base) <-
           adapter.get(mr_ref),
         true <-
           Code.ensure_loaded?(adapter) and
             (function_exported?(adapter, :update_branch, 1) or
                function_exported?(adapter, :update_branch, 2)),
         {:stale, behind} <- check(ctx[:workspace], ctx[:repo], base, head) do
      {:stale, behind, head, base}
    else
      _ -> :current
    end
  rescue
    _ -> :current
  catch
    :exit, _ -> :current
  end

  defp sync(adapter, mr_ref, ctx, behind, head, base) do
    case Mergers.update_branch(adapter, mr_ref, ctx[:workspace], ctx[:repo]) do
      :ok ->
        Logger.info(
          "Worker.CiSync: #{mr_ref} head #{head} lacks #{behind} commit(s) of #{base}; " <>
            "synced the branch instead of re-running CI on the stale head"
        )

        {:ok,
         %{
           action: :synced,
           behind: behind,
           head: head,
           base: base,
           rationale:
             "head #{head} was #{behind} commit(s) behind #{base}; synced the branch " <>
               "(merge.sync_strategy) instead of re-running CI on a head that lacks the target — " <>
               "CI runs on the synced head"
         }}

      {:error, reason} ->
        {:error, {:sync_failed, reason}}

      other ->
        {:error, {:sync_failed, {:bad_return, other}}}
    end
  end
end
