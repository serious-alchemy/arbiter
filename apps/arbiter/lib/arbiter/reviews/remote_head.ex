defmodule Arbiter.Reviews.RemoteHead do
  @moduledoc """
  The remote head Arbiter last pushed or observed for a ticket's own branch
  (bd-6ao60c, #1203), recorded on the ticket so it outlives any one run.

  ## Why this exists

  A rebase of the ticket's own branch is delivered with `--force-with-lease`
  pinned to a remote SHA Arbiter already holds (`PushState.rewrite_lease/3`,
  bd-4axlg0). Until now the only carrier of that SHA was in-memory: the
  ReviewGate's `pushed_remote_head`, seeded when a fix round was placed. A
  ticket's own implement run had none, so a rebase whose commits no longer
  patch-match the remote's (main's `mix format` changed their context) was
  refused as diverged and parked `head_not_pushed` — on 2026-10-31 three
  approved vstim tickets, each after a `conflict` pass on the cluster was
  interrupted and an `implement` run resumed on `local`.

  So every push Arbiter makes, and every time its review gate sees the remote
  carrying exactly the head it holds, the SHA is written to the ticket's
  `review_gate_state`. Any later run, on any backend, reads it back
  (`recorded/2`) and hands it to `PushState` as `:expected_remote`.

  ## Safety

  The record is one entry: `{branch, sha}`. `recorded/2` answers only for that
  branch, so a lease is never offered for a branch other than the ticket's own.
  A remote that has moved off the recorded SHA (a third-party push) no longer
  matches, and the rewrite is refused as before. Both functions are best-effort
  and never raise: a missing ticket or an unreadable row reads as "nothing
  recorded", which keeps the lease off, never on.
  """

  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PullRequest

  @key "remote_head"
  @sha ~r/\A[0-9a-f]{40,64}\z/

  @doc "Record `sha` as the remote head of `branch` for `task_id`. Always `:ok`."
  @spec record(String.t() | nil, String.t() | nil, String.t() | nil) :: :ok
  def record(task_id, branch, sha)
      when is_binary(task_id) and is_binary(branch) and is_binary(sha) do
    if Regex.match?(@sha, sha) do
      PullRequest.record_review_gate(task_id, %{@key => %{"branch" => branch, "sha" => sha}})
    end

    :ok
  rescue
    e ->
      Logger.debug("RemoteHead.record/3 swallowed: #{Exception.message(e)}")
      :ok
  end

  def record(_task_id, _branch, _sha), do: :ok

  @doc "The remote head recorded for `branch` of `task_id`, or `nil`."
  @spec recorded(String.t() | nil, String.t() | nil) :: String.t() | nil
  def recorded(task_id, branch) when is_binary(task_id) and is_binary(branch) do
    case Ash.get(Issue, task_id) do
      {:ok, %{review_gate_state: %{@key => %{"branch" => ^branch, "sha" => sha}}}}
      when is_binary(sha) ->
        sha

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def recorded(_task_id, _branch), do: nil
end
