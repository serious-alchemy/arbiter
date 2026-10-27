defmodule Arbiter.ReviewGate.RulingResume do
  @moduledoc """
  A merge-permitting ruling puts the ticket back on the merge path.

  When the ReviewGate escalates, the coordinator answers with
  `review_gate_resolve` (`Arbiter.ReviewGate.Resolutions`). `send_back` and
  `reject` send the work back. `accept_as_is` and `amend` say it ships as it is —
  and until this module that was only a record: the ticket stayed parked, nothing
  watched CI, and the coordinator waited for the pipeline, merged the exact head
  by hand and closed the ticket (five times on 2026-10-25, one of them sitting
  ~30 minutes green and unmerged because no event fires when CI turns green on a
  parked ticket).

  ## What a ruling on head H does

  `resume/2` is called by `Resolutions.record/2` for a `:review_gate` ruling that
  permits a merge:

    1. **Stamps H as the reviewed baseline** (`issues.last_reviewed_sha`). The
       stale-SHA guards then bind the merge to H exactly: the forge is handed H as
       the atomic merge precondition, the `direct` merger refuses a branch that is
       no longer at H, and a head that moves is judged on content like any other.
    2. **Clears the park** (`ReviewPark`, `review_gate_not_converged`) and the
       open escalation, so the ticket leaves "waiting on you".
    3. **Re-enters the merge path** by the state the ticket is in:
         * *Active* with the gate's round state (the escalation's usual resting
           place) — `Arbiter.Worker.resume_merge_after_ruling/2`, the hand-off a
           late APPROVE takes: adopt/open the PR and start the ticket's Watchdog,
           or merge locally for a `direct` repo.
         * *Merging* with no Watchdog — one is started from the ticket's row.
         * *Merging* with a Watchdog already watching — nothing to start; it
           re-reads the ruling on its next merge attempt.
         * a worker with a live run is resident, or the ticket is not parked on
           the gate — left alone. A worker left registered but `:finished` does
           not count as resident.
    4. The Watchdog does the rest: waits for the pipeline on H, merges exactly H,
       closes the ticket and runs the post-merge steps (deploy watch, tracker
       sync, `verify_after_deploy`). A repo with `merge.auto_merge` off stops at
       "ready to merge" with the `awaiting_manual_merge` attention cause.

  The ruling never covers a head it was not recorded against
  (`Arbiter.ReviewGate.MergeAuthorization`): CI failing on H goes down the normal
  fix-pass path, whose new head needs a fresh round or ruling; a head that moves
  before the merge blocks it and re-escalates naming both SHAs
  (`head_changed/4`), unless the move is a pure rebase whose net diff against the
  base is identical to the ruled one (`carry_forward/4`).

  ## Events

  Each outcome is announced on the workspace `review_gate` event stream with a
  `ruling_event` of `"resumed"`, `"merged"`, `"ci_failed"`, `"head_changed"` or
  `"carried"` (a pure rebase the ruling still covers), carrying `task_id`,
  `head_sha` and a one-line `message`.
  """

  require Logger

  alias Arbiter.ReviewGate.{MergeAuthorization, Resolution, Resolutions}
  alias Arbiter.Tasks.{Attention, Issue, ReviewPark}
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog

  @authorising [:accept_as_is, :amend]

  @doc "Whether `decision` permits a merge without a reviewer APPROVE."
  @spec merge_permitting?(atom()) :: boolean()
  def merge_permitting?(decision), do: decision in @authorising

  @doc """
  `resume/2`, off the caller's process unless `config :arbiter, :ruling_resume`
  says `:sync` (the suite) or `:off`. Opening a PR and merging are forge and git
  calls; `review_gate_resolve` returns the recorded ruling at once and the
  outcome arrives as events.
  """
  @spec resume_async(Resolution.t()) :: :ok
  def resume_async(%Resolution{gate: :review_gate, decision: decision} = resolution)
      when decision in @authorising do
    case Application.get_env(:arbiter, :ruling_resume, :async) do
      :off ->
        :ok

      :sync ->
        _ = resume(resolution)
        :ok

      _async ->
        _ = Task.Supervisor.start_child(Arbiter.TaskSupervisor, fn -> resume(resolution) end)
        :ok
    end
  end

  def resume_async(_resolution), do: :ok

  @doc """
  Put the ruling's ticket back on the merge path (see the moduledoc). Never
  raises; returns `{:ok, how}` or `{:skipped, why}`.

  Options: `:watch_opts` — merged over the Watchdog's row-derived options when
  this starts one (test seams such as a stub fix-pass dispatcher).
  """
  @spec resume(Resolution.t(), keyword()) :: {:ok, atom()} | {:skipped, term()}
  def resume(resolution, opts \\ [])

  def resume(%Resolution{gate: :review_gate, decision: decision} = resolution, opts)
      when decision in @authorising do
    with {:ok, task} <- fetch(resolution.task_id),
         {:ok, path} <- path_for(task) do
      do_resume(task, resolution, path, opts)
    else
      {:skip, why} ->
        Logger.info(
          "RulingResume: task=#{resolution.task_id} #{decision} ruling does not resume the " <>
            "merge path (#{inspect(why)})"
        )

        {:skipped, why}
    end
  rescue
    e ->
      Logger.warning(
        "RulingResume: resuming task=#{resolution.task_id} raised: #{Exception.message(e)}"
      )

      {:skipped, :raised}
  catch
    :exit, reason ->
      Logger.warning(
        "RulingResume: resuming task=#{resolution.task_id} exited: #{inspect(reason)}"
      )

      {:skipped, :exited}
  end

  def resume(_resolution, _opts), do: {:skipped, :not_merge_permitting}

  @doc """
  A worker resume of `task_id` whose standing merge-permitting ruling covers
  `head` (the worktree's current head) goes straight back onto the merge path —
  CI wait, merge, close — instead of starting a fresh review round that would
  ignore the ruling. `:none` when no ruling covers `head` (none recorded, a
  `send_back` / `reject` answered the round, or the head moved) or the ticket
  cannot re-enter the merge path; the caller then resumes normally.
  """
  @spec resume_covering(String.t(), String.t() | nil, keyword()) :: {:ok, atom()} | :none
  def resume_covering(task_id, head, opts \\ []) do
    with %Resolution{} = ruling <- MergeAuthorization.ruling_covering(task_id, head),
         {:ok, how} <- resume(ruling, opts) do
      {:ok, how}
    else
      _ -> :none
    end
  end

  # ---- the paths ------------------------------------------------------------

  defp fetch(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = task} -> {:ok, task}
      _ -> {:skip, :no_ticket}
    end
  end

  # Where the ticket is on the merge path, and so how to re-enter it.
  defp path_for(%Issue{id: id} = task) do
    cond do
      agent_live?(id) -> {:skip, :worker_resident}
      task.state == :merging and present?(task.pr_ref) -> {:ok, :merging}
      task.state == :active and gate_parked?(task) -> {:ok, :parked}
      true -> {:skip, {:not_parked_on_the_gate, task.state}}
    end
  end

  # A registered worker only stands in the ruling's way while its run is live.
  # One left `:finished` (an escalated gate fails the run and nothing stops the
  # process) has no agent to hand the ruling to: waiting on it strands the
  # ticket, so the merge path resumes from the row.
  defp agent_live?(id) do
    case Worker.whereis(id) do
      nil -> false
      pid -> not Worker.finished?(safe_state(pid))
    end
  end

  defp safe_state(pid) do
    Worker.state(pid)
  catch
    :exit, _ -> nil
  end

  # The gate recorded its round state (`Worker.enter_review_gate/2`) — without it
  # there is no branch to merge and nothing for a verdict to be applied to.
  defp gate_parked?(%Issue{review_gate_state: %{"branch" => branch}}), do: present?(branch)
  defp gate_parked?(_task), do: false

  defp do_resume(task, resolution, path, opts) do
    stamp_reviewed_head(task, resolution)
    clear_attention(task)
    announce(task, "resumed", resolution, "merge path resumed on #{resolution.decision} ruling")

    case path do
      :parked -> resume_parked(task, resolution)
      :merging -> resume_merging(task, resolution, opts)
    end
  end

  defp resume_parked(task, resolution) do
    ruling = %{
      decision: resolution.decision,
      actor: resolution.actor,
      head_sha: resolution.head_sha,
      reasoning: resolution.reasoning
    }

    case Worker.resume_merge_after_ruling(task.id, ruling) do
      :ok ->
        announce_if_merged(task, resolution)
        {:ok, :applied_to_ticket}

      {:error, reason} ->
        Logger.warning(
          "RulingResume: task=#{task.id} could not resume the merge after the " <>
            "#{resolution.decision} ruling: #{inspect(reason)}"
        )

        {:skipped, reason}
    end
  end

  defp resume_merging(task, _resolution, opts) do
    case Watchdog.whereis(task.id) do
      pid when is_pid(pid) ->
        {:ok, :already_watching}

      nil ->
        case Watchdog.watch(task.id, watch_extra(opts)) do
          :ok -> {:ok, :watchdog_started}
          {:error, reason} -> {:skipped, {:watchdog, reason}}
        end
    end
  end

  # `watch/2` takes the test seams (a stub fix-pass dispatcher); it replaces a
  # running Watchdog, and none is running here.
  defp watch_extra(opts), do: opts |> Keyword.get(:watch_opts, []) |> Keyword.new()

  # A `direct` merge completes inside the hand-off; a forge merge happens later,
  # in the Watchdog, which announces it from `Watchdog.finish_merged/1`.
  defp announce_if_merged(task, resolution) do
    case Ash.get(Issue, task.id) do
      {:ok, %Issue{state: state}} when state in [:closed, :verifying] ->
        announce(task, "merged", resolution, "merged on #{resolution.decision} ruling")

      _ ->
        :ok
    end
  end

  # ---- the guard ------------------------------------------------------------

  # The ruled head becomes the reviewed baseline, so every stale-SHA guard binds
  # the merge to it. A ruling recorded against no head stamps nothing and covers
  # whatever the ticket merges (`MergeAuthorization`).
  defp stamp_reviewed_head(_task, %Resolution{head_sha: sha}) when sha in [nil, ""], do: :ok

  defp stamp_reviewed_head(task, %Resolution{head_sha: sha}) do
    case Ash.update(task, %{last_reviewed_sha: sha, last_reviewed_at: DateTime.utc_now()}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "RulingResume: could not stamp #{sha} as the reviewed head of task=#{task.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  # The ticket stops waiting on the gate: the park and the gate's escalation are
  # answered. Another cause (a blocked merge, a crash) is not the ruling's to clear.
  defp clear_attention(%Issue{id: id, attention_cause: cause}) do
    if is_nil(cause) or cause == :review_gate_not_converged or cause in ReviewPark.park_reasons(),
      do: Attention.clear(id, :ruling_resumed)

    :ok
  end

  # ---- events ---------------------------------------------------------------

  @doc """
  Announce a ruling outcome on the workspace `review_gate` stream, once the
  merge path has reached it: `"merged"`, `"ci_failed"`, `"head_changed"`,
  `"carried"`. Only a ticket with a standing ruling that covers (or, for
  `"head_changed"`, predates) `head` announces anything; `extra` is merged into
  the payload. Best-effort.
  """
  @spec note(String.t(), String.t() | nil, String.t(), map()) :: :ok
  def note(task_id, workspace_id, event, extra \\ %{})

  def note(task_id, workspace_id, event, extra) when is_binary(task_id) do
    with ruling when not is_nil(ruling) <- MergeAuthorization.standing_ruling(task_id),
         ws_id when is_binary(ws_id) <- workspace_id || ruling.workspace_id do
      Arbiter.Events.broadcast(
        ws_id,
        "review_gate",
        Map.merge(
          %{
            task_id: task_id,
            ruling_event: event,
            decision: Atom.to_string(ruling.decision),
            ruled_head_sha: ruling.head_sha
          },
          extra
        )
      )
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "RulingResume.note(#{event}) for task=#{task_id} swallowed: #{Exception.message(e)}"
      )

      :ok
  end

  def note(_task_id, _workspace_id, _event, _extra), do: :ok

  defp announce(task, event, resolution, message) do
    Arbiter.Events.broadcast(task.workspace_id, "review_gate", %{
      task_id: task.id,
      ruling_event: event,
      decision: Atom.to_string(resolution.decision),
      head_sha: resolution.head_sha,
      message: "#{task.id}: #{message}"
    })

    :ok
  end

  # ---- a head that moved after the ruling ----------------------------------

  @doc """
  The head moved after the ruling (`MergeAuthorization.head_changed/2`), so the
  merge is blocked and the coordinator is told, naming both SHAs: an inbox
  escalation plus a `"head_changed"` event. One page per `(ruled, head)` pair is
  the caller's to ensure — the Watchdog stops after it.
  """
  @spec head_changed(map(), String.t() | nil, Resolution.t(), String.t()) :: :ok
  def head_changed(snapshot, mr_ref, %Resolution{} = ruling, head) do
    Arbiter.Messages.CoordinatorNotifier.ruling_head_changed(
      snapshot,
      mr_ref,
      ruling.decision,
      ruling.head_sha,
      head
    )

    note(snapshot.task_id, Map.get(snapshot, :workspace_id), "head_changed", %{
      head_sha: head,
      message: "head changed since ruling: #{ruling.head_sha} -> #{head}"
    })

    :ok
  end

  @doc """
  The head moved but its net diff against the base is identical to the ruled
  head's — a rebase or a clean merge from the base — so the ruling still covers
  it. `proof` says how that was established (shown in the event and the record).
  Writes an auditable, system-authored ruling row for the new head (no resume)
  and announces `"carried"`. The caller has already checked the equality.
  """
  @spec carry_forward(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Resolution.t()} | :none
  def carry_forward(task_id, from, to, proof) do
    case MergeAuthorization.ruling_covering(task_id, from) do
      %Resolution{head_sha: ^from} = ruling ->
        attrs = %{
          task_id: task_id,
          decision: ruling.decision,
          gate: :review_gate,
          reasoning:
            "Carried from #{from} to #{to}: #{proof}. Original ruling by #{ruling.actor}: " <>
              ruling.reasoning,
          actor: "system:ruling-resume",
          round: ruling.round,
          fix_round_attempt: ruling.fix_round_attempt,
          head_sha: to
        }

        case Resolutions.record(attrs, resume: false) do
          {:ok, carried} ->
            note(task_id, ruling.workspace_id, "carried", %{
              baseline: "ruling",
              head_sha: to,
              from_sha: from,
              actor: carried.actor,
              proof: proof,
              message: "ruling carried #{from} -> #{to}: #{proof}"
            })

            {:ok, carried}

          {:error, _} ->
            :none
        end

      _ ->
        :none
    end
  end

  @doc """
  A ReviewGate APPROVE baseline moved from `from` to `to` on a proven clean sync
  (`Arbiter.ReviewGate.BaselineCarry`): announce `"carried"` on the workspace
  `review_gate` stream, the same event a carried ruling emits, so the rounds
  report lists both. Best-effort.
  """
  @spec announce_carry(String.t(), String.t() | nil, String.t(), String.t(), String.t(), String.t()) ::
          :ok
  def announce_carry(task_id, workspace_id, baseline, from, to, proof) do
    ws_id =
      workspace_id ||
        case Ash.get(Issue, task_id) do
          {:ok, %Issue{workspace_id: ws}} -> ws
          _ -> nil
        end

    Arbiter.Events.broadcast(ws_id, "review_gate", %{
      task_id: task_id,
      ruling_event: "carried",
      baseline: baseline,
      head_sha: to,
      from_sha: from,
      actor: "system:baseline-carry",
      proof: proof,
      message: "#{baseline} baseline carried #{from} -> #{to}: #{proof}"
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "RulingResume.announce_carry for task=#{task_id} swallowed: #{Exception.message(e)}"
      )

      :ok
  end

  defp present?(v), do: is_binary(v) and v != ""
end
