defmodule Arbiter.ReviewGate.MergeAuthorization do
  @moduledoc """
  Whether the ReviewGate's own record lets a ticket's PR merge (bd-651ine / #529).

  ## Why this exists

  The merge guards (`Arbiter.Mergers.ReviewedSha`, `Arbiter.Reviews.Coverage`)
  compare the head being merged with the head a review *approved*. With no
  approval ever recorded there is no baseline, and `ReviewedSha.check(nil, _)`
  merges **unguarded** — deliberately, for paths that have no review to offer
  (the `Direct` strategy, an adapter that surfaces no head SHA). That is right
  for a ticket nobody reviewed and wrong for one the gate *rejected*: a
  REQUEST_CHANGES ticket has rounds on file and no approval, so it looked
  exactly like a ticket the gate never saw.

  Incident (bd-311cun / PR #527, 2026-10-08): round 1 returned REQUEST_CHANGES,
  the implementer committed fixes, the gate parked, the coordinator recorded a
  `send_back` resolution and resumed the worker, and the ticket merged with no
  reviewer round after round 1 and `approved=false` on the PR. This module is
  the check at the merge chokepoints that makes the gate's own record binding.

  ## The rule

  `check/2` reads the ticket's reviewer rounds (`Arbiter.ReviewGate.Round`,
  roles `:review` and `:conflict_review`) and its `:review_gate` resolutions:

    * **no reviewer round on file** — `:ok`. The ReviewGate never argued this
      ticket (review not required, an external review, a research task), so
      there is nothing for the record to contradict. The reviewed-SHA guards
      still apply.
    * **the latest reviewer round approved** — `:ok`. Whether the *head* is the
      approved one is the reviewed-SHA / coverage guards' question (they carry
      the content-equality exceptions); this module only adds the case they
      cannot see.
    * **the latest reviewer round did not approve** (REQUEST_CHANGES, a timed
      out pass) — refused, unless the newest resolution answering that round
      is `accept_as_is` or `amend` and covers `head`. Those two are the
      coordinator deciding, on its own authority, that the work ships. `send_back` and
      `reject` never authorise a merge: `send_back` means *another review round
      follows* the implementer's next completion, and that round's APPROVE is
      what the next `check/2` finds.

  A resolution covers `head` when it was recorded against that head
  (`Resolution.head_sha`) or against none (recorded with no head to resolve —
  a ticket with no PR yet — which then covers whatever the ticket merges).
  A resolution recorded before the latest reviewer round answers an older
  argument and authorises nothing.

  Read failures fail OPEN with a loud log line: a database fault must not
  strand every merge in the fleet, and this guard is one layer among several.
  """

  require Ash.Query
  require Logger

  alias Arbiter.ReviewGate.{Resolution, Round}

  @reviewer_roles [:review, :conflict_review]
  @authorising [:accept_as_is, :amend]

  @type refusal ::
          {:review_not_approved,
           %{
             verdict: atom() | nil,
             round: pos_integer() | nil,
             resolution: atom() | nil,
             head: String.t() | nil
           }}

  @doc """
  `:ok` when `task_id`'s ReviewGate record permits merging `head`, otherwise
  `{:error, {:review_not_approved, detail}}`. `head` is the commit about to
  merge, when the caller knows it (`nil` when it does not).
  """
  @spec check(String.t() | nil, String.t() | nil) :: :ok | {:error, refusal()}
  def check(task_id, head) when is_binary(task_id) do
    case latest_review(task_id) do
      nil ->
        :ok

      %{verdict: :approve} ->
        :ok

      latest ->
        answer = latest_answer(task_id, latest)

        if answer && answer.decision in @authorising && covers?(answer, head) do
          :ok
        else
          {:error,
           {:review_not_approved,
            %{
              verdict: latest.verdict,
              round: latest.round,
              resolution: answer && answer.decision,
              head: head
            }}}
        end
    end
  rescue
    e ->
      Logger.error(
        "ReviewGate.MergeAuthorization: could not read the gate record for task=#{task_id} " <>
          "(#{Exception.message(e)}); not refusing the merge on it"
      )

      :ok
  end

  def check(_task_id, _head), do: :ok

  @doc "One line for a log or an escalation: why `check/2` refused."
  @spec describe(refusal()) :: String.t()
  def describe({:review_not_approved, detail}) do
    verdict = detail.verdict && Atom.to_string(detail.verdict)
    head = detail.head && String.slice(detail.head, 0, 12)

    "the latest reviewer round (#{detail.round || "?"}) is #{verdict || "not an approval"}" <>
      if(head, do: " and head #{head} has no APPROVE", else: " and the head has no APPROVE") <>
      case detail.resolution do
        nil ->
          ""

        :send_back ->
          "; the `send_back` resolution is not a pass — another review round must follow " <>
            "the implementer's completion"

        decision ->
          "; the `#{decision}` resolution does not authorise a merge"
      end
  end

  # ---- helpers --------------------------------------------------------------

  defp latest_review(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id and role in ^@reviewer_roles)
    |> Ash.Query.sort(inserted_at: :asc, fix_round_attempt: :asc, round: :asc)
    |> Ash.read!()
    |> List.last()
  end

  defp review_gate_resolutions(task_id) do
    Resolution
    |> Ash.Query.filter(task_id == ^task_id and gate == :review_gate)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  # The newest resolution recorded at or after `latest`: the coordinator's last
  # word on that round. A later `send_back` or `reject` withdraws an earlier
  # `accept_as_is`.
  defp latest_answer(task_id, latest) do
    task_id
    |> review_gate_resolutions()
    |> Enum.filter(&answers?(&1, latest))
    |> List.last()
  end

  defp answers?(resolution, latest),
    do: DateTime.compare(resolution.inserted_at, latest.inserted_at) != :lt

  defp covers?(%{head_sha: nil}, _head), do: true
  defp covers?(%{head_sha: ""}, _head), do: true
  defp covers?(_resolution, nil), do: true
  defp covers?(%{head_sha: recorded}, head), do: recorded == head
end
