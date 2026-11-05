defmodule Arbiter.Worker.CiUnrun do
  @moduledoc """
  A red head whose pipeline never ran a job.

  GitLab fails a pipeline at creation, with **no jobs**, when it refuses to run
  it: the pushing user is not identity-verified, a quota is spent, the config is
  invalid. The head reads `failed`, but no check failed and no code change can
  clear it. Treated as a code failure it sends fix passes with nothing to fix
  (bd-7eve8a: a `gitlab_bot_token` user that was not verified burned every fix
  pass on 26 pipelines) and, when a later pipeline went green, was recorded as a
  flake.

  Both CI consumers — the Watchdog's `:ci_failed` path and the ReviewGate's CI
  wait — ask `read/2` before they treat a red head as one to fix or re-run. A hit
  means: no fix pass, no attempt spent, no flake record, and `escalate/5` raises
  an attention item that carries the forge's own reason and names the pushing
  user and the credential, so the coordinator can roll the credential back.

  The question is an adapter callback (`c:Arbiter.Mergers.Merger.unrun_pipeline/1`);
  an adapter without it (GitHub) never reports one, so its red heads are unchanged.
  """

  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Worker.GitCredential

  require Logger

  @doc """
  The adapter's `unrun_pipeline` info for `mr_ref`, or `nil` when the head's
  failure is a real one (or the adapter cannot tell, or the read failed — a forge
  that cannot answer never changes how a red head is handled).
  """
  @spec read(module() | nil, String.t() | nil) :: map() | nil
  def read(adapter, mr_ref) when is_atom(adapter) and not is_nil(adapter) and is_binary(mr_ref) do
    with true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :unrun_pipeline, 1),
         {:ok, %{} = info} <- adapter.unrun_pipeline(mr_ref) do
      info
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def read(_adapter, _mr_ref), do: nil

  @doc """
  Raise the attention item for `info` on the ticket in `snapshot`
  (`%{task_id, workspace_id}`). Deduped by the notifier: one per outstanding
  episode. Best-effort — never raises.
  """
  @spec escalate(map(), String.t() | nil, map(), map() | nil, String.t() | nil) :: :ok
  def escalate(snapshot, mr_ref, info, workspace, repo) do
    Logger.warning(
      "CiUnrun: pipeline #{inspect(Map.get(info, :pipeline_id))} for task=#{snapshot.task_id} " <>
        "mr=#{mr_ref} failed with no jobs (#{Map.get(info, :failure_reason) || "reason unknown"}); " <>
        "not a code failure: no fix pass, no flake record"
    )

    CoordinatorNotifier.ci_pipeline_not_run(snapshot, mr_ref, info,
      credential: GitCredential.describe_credential(workspace, repo)
    )
  rescue
    e ->
      Logger.warning("CiUnrun: escalation raised: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end
end
