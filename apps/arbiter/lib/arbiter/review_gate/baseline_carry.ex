defmodule Arbiter.ReviewGate.BaselineCarry do
  @moduledoc """
  Carry a review baseline across a verified-clean sync (bd-2oo8kf / #1062).

  A ticket's merge is bound to a reviewed head `H` in one of two ways: a
  coordinator's `accept_as_is` / `amend` ruling recorded against `H`
  (`Arbiter.ReviewGate.MergeAuthorization`), or a ReviewGate APPROVE that
  latched `H` as `issues.last_reviewed_sha`. On a busy target the queue syncs
  the branch (`update_branch`, or the forge rebases it) and the head becomes
  `H'`; the ruling was then voided (`head_changed`) and the latch cleared, so a
  ruled or approved MR needed a coordinator re-rule per sync (vs-6myyiu,
  2026-10-27: ruled 14:41Z, rebased 15:06Z with an identical range-diff,
  re-ruled by hand 15:07Z, merged).

  `carry/1` moves the baseline from `H` to `H'` when
  `Arbiter.Mergers.SyncProof` proves `H'` is `H` and the target's own delta and
  nothing else — a rebase with identical patch-ids, or a merge of the target
  whose tree equals `git merge-tree` of its parents. Then:

    * a **ruling** on `H` is re-recorded against `H'` as a system-authored
      resolution (`RulingResume.carry_forward/4`) — it shows in the rounds
      list (`review_gate_rounds_list`'s `resolutions`) with who/what/why;
    * an **APPROVE** baseline is re-stamped (`last_reviewed_sha := H'`);
    * both announce a `"carried"` event on the `review_gate` stream, which
      `RoundsReport` lists under `carries`.

  Any content beyond the target's delta — a conflict resolution, an extra
  commit, an amended hunk, a merge of anything but the target — is not proven,
  and `carry/1` returns `:void` with nothing written: the head is judged as any
  other new head, exactly as before this module existed.

  Security-sensitive: this widens what a ruling covers. It never trusts the
  caller's claim that a head is "just a sync" — the proof is recomputed in the
  task's own checkout, and failing to compute it is `:void`.
  """

  require Logger

  alias Arbiter.Mergers.SyncProof
  alias Arbiter.ReviewGate.{MergeAuthorization, RulingResume}
  alias Arbiter.Tasks.Issue

  @type request :: %{
          required(:task_id) => String.t(),
          required(:from) => String.t() | nil,
          required(:to) => String.t() | nil,
          required(:repo_path) => String.t() | nil,
          required(:base) => String.t() | nil,
          optional(:workspace_id) => String.t() | nil
        }

  @doc """
  Verify that `to` is `from` synced with `base` and, if so, carry the ticket's
  baseline from `from` to `to`. `{:carried, baseline, proof}` (`baseline` is
  `:ruling` or `:approval`) or `:void`.
  """
  @spec carry(request()) :: {:carried, :ruling | :approval, String.t()} | :void
  def carry(%{task_id: task_id, from: from, to: to, base: base} = req)
      when is_binary(task_id) and is_binary(from) and from != "" and is_binary(to) and to != "" and
             is_binary(base) and base != "" do
    with true <- from != to,
         baseline when baseline != :none <- baseline_at(task_id, from),
         {:ok, _kind, proof} <- SyncProof.verify(Map.get(req, :repo_path), base, from, to) do
      apply_carry(task_id, Map.get(req, :workspace_id), from, to, proof, baseline)
    else
      {:error, reason} ->
        Logger.info(
          "BaselineCarry: task=#{task_id} #{from} -> #{to} is not a proven clean sync " <>
            "(#{inspect(reason, limit: 6)}); the baseline is not carried"
        )

        :void

      _ ->
        :void
    end
  rescue
    e ->
      Logger.warning("BaselineCarry: task=#{task_id} raised: #{Exception.message(e)}")
      :void
  catch
    :exit, _ -> :void
  end

  def carry(_req), do: :void

  @doc """
  Carry the baseline from `from` to `to` on a proof the caller already has
  (`proof` is the one-line statement of it): the Watchdog and the queue's
  net-diff equality checks, which predate `SyncProof`. Same record as `carry/1`.
  `:void` when `from` holds no baseline.
  """
  @spec carry_proven(String.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
          {:carried, :ruling | :approval, String.t()} | :void
  def carry_proven(task_id, workspace_id, from, to, proof) do
    case baseline_at(task_id, from) do
      :none -> :void
      baseline -> apply_carry(task_id, workspace_id, from, to, proof, baseline)
    end
  end

  defp apply_carry(task_id, _workspace_id, from, to, proof, :ruling) do
    case RulingResume.carry_forward(task_id, from, to, proof) do
      {:ok, _carried} ->
        restamp(task_id, from, to)
        {:carried, :ruling, proof}

      :none ->
        :void
    end
  end

  defp apply_carry(task_id, workspace_id, from, to, proof, :approval) do
    restamp(task_id, from, to)

    RulingResume.announce_carry(task_id, workspace_id, "approval", from, to, proof)

    {:carried, :approval, proof}
  end

  # What `from` is the baseline of: a standing ruling recorded against it, else
  # the ReviewGate's APPROVE (the latest reviewer round approved, and the ticket's
  # latch names `from`). A ruling recorded against no head is not a baseline at
  # a head, so it needs no carrying.
  defp baseline_at(task_id, from) do
    cond do
      match?(%{head_sha: ^from}, MergeAuthorization.ruling_covering(task_id, from)) -> :ruling
      approval_at?(task_id, from) -> :approval
      true -> :none
    end
  end

  defp approval_at?(task_id, from) do
    MergeAuthorization.approved?(task_id) and recorded_reviewed_sha(task_id) == from
  end

  defp recorded_reviewed_sha(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{last_reviewed_sha: sha}} -> sha
      _ -> nil
    end
  end

  # The durable latch follows the baseline, so a Watchdog started later (or a
  # restart) binds the merge to the head that is actually there.
  defp restamp(task_id, from, to) do
    with {:ok, %Issue{last_reviewed_sha: ^from} = task} <- Ash.get(Issue, task_id),
         {:ok, _} <- Ash.update(task, %{last_reviewed_sha: to, last_reviewed_at: DateTime.utc_now()}) do
      :ok
    else
      _ -> :ok
    end
  end
end
