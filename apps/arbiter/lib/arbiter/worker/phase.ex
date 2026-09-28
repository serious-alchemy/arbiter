defmodule Arbiter.Worker.Phase do
  @moduledoc """
  What a worker is *actually doing right now*, derived (bd-aw2cyt).

  ## Why a phase and not just a status

  `status` is the worker record's FSM state, and it is honest about the
  record. It is not honest about the work: the main `claude --print` process
  exits when the author agent finishes its turn, but the worker record lives
  on to shepherd the ReviewGate, the implementer rounds, the CI fix passes and
  the merge. Through all of that it reported `:running` (or
  `:awaiting_review_gate`), so the board, `arb worker list` and the MCP tools
  all said "running" about a task with no process anywhere. On 2026-09-16 the
  coordinator saw three such cards at once.

  A phase names the stage instead:

    * `:implementing` — the author's own agent is live.
    * `:in_review` — a ReviewGate reviewer is reading the diff (or the gate is
      between rounds).
    * `:addressing_review` — an implementer round is applying review findings.
    * `:fixing_ci` — a CI fix pass is live.
    * `:resolving_conflict` — a conflict resolver is live.
    * `:waiting_ci_merge` — no agent; an MR is open and CI / the merge queue
      owns the outcome.
    * `:waiting_on_you` — the worker asked a question, or parked failed.
    * `:done` — the worker completed.

  There is no hand-off phase any more (bd-741sid). It named the window a
  worker spent between agents holding its task's slot — the `slot_handoff`
  failure of a ReviewGate fix round or a Watchdog auto-resume — and slots are
  counted by the ticket's state now (`Arbiter.Tasks.SlotGate`, bd-asxw4e), so
  no worker hands one off. A run between agents reads as its stage.

  ## Phase is not liveness

  `:in_review` says *which stage*; it does not promise a process. The gate can
  be between rounds with nothing spawned. "Is anything burning quota for this
  task" is a separate question — `any_agent_live?/2` — and the two are
  rendered separately on purpose: the board shows the phase as the label and
  the liveness as the card's own emphasis. Slot accounting reads liveness
  only, via `Arbiter.Tasks.SlotGate`.

  ## Compatibility

  `phase` is **additive**. Every surface keeps emitting `status` unchanged, so
  a consumer matching on `:running` / `"running"` keeps working; the phase
  rides alongside it. See `Arbiter.Tasks.SlotGate` for the slot half.

  ## Siblings

  A task's ReviewGate rounds run in *separate* workers: a reviewer /
  implementer under its own synthetic task id (`meta[:reviews]` /
  `meta[:revises]` points back at the author). So an author's phase is a
  function of its own snapshot plus its siblings', and `of/2` takes both.
  `annotate/1` does the grouping for a caller that has the whole list. A CI
  fix pass or conflict pass is the ticket's own run since bd-741sid —
  registered under the ticket id — and reads as its round by its `:role`.
  """

  alias Arbiter.Tasks.SlotGate

  @type t ::
          :implementing
          | :in_review
          | :addressing_review
          | :fixing_ci
          | :resolving_conflict
          | :waiting_ci_merge
          | :waiting_on_you
          | :done

  @phases [
    :implementing,
    :in_review,
    :addressing_review,
    :fixing_ci,
    :resolving_conflict,
    :waiting_ci_merge,
    :waiting_on_you,
    :done
  ]

  @labels %{
    implementing: "implementing",
    in_review: "in review",
    addressing_review: "addressing review",
    fixing_ci: "fixing CI",
    resolving_conflict: "resolving conflict",
    waiting_ci_merge: "waiting on CI / merge",
    waiting_on_you: "waiting on you",
    done: "done"
  }

  # Which round each subordinate role *is*, when its agent is live.
  @role_phases %{
    reviewer: :in_review,
    implementer: :addressing_review,
    fix_pass: :fixing_ci,
    conflict_resolver: :resolving_conflict
  }

  # The order a task's rounds outrank each other when more than one is
  # somehow live: the nearest-to-the-merge round wins, because that is the one
  # an operator is waiting on.
  @role_precedence [:conflict_resolver, :fix_pass, :implementer, :reviewer]

  @doc "Every phase, in rough lifecycle order."
  @spec phases() :: [t()]
  def phases, do: @phases

  @doc "A human label for a phase (board card, CLI, MCP)."
  @spec label(t() | nil) :: String.t() | nil
  def label(nil), do: nil
  def label(phase) when is_atom(phase), do: Map.get(@labels, phase, to_string(phase))

  @doc """
  The phase of `worker`, given `siblings` — the other live worker snapshots
  (any task). Only the ones belonging to this worker's task are consulted.
  """
  @spec of(map(), [map()]) :: t()
  def of(worker, siblings \\ [])

  def of(worker, siblings) when is_map(worker) do
    cond do
      Map.get(worker, :status) == :completed -> :done
      Map.get(worker, :status) in [:awaiting, :failed] -> :waiting_on_you
      subordinate_role(worker) -> subordinate_phase(worker)
      true -> author_phase(worker, siblings)
    end
  end

  @doc """
  Stamp `:phase` on every row of a worker list, using the list itself as the
  sibling set.
  """
  @spec annotate([map()]) :: [map()]
  def annotate(workers) when is_list(workers) do
    Enum.map(workers, fn w -> Map.put(w, :phase, of(w, workers)) end)
  end

  @doc """
  Is any agent live for this worker's task, in any role?

  `true` for unknown liveness: a snapshot that cannot answer must not be
  rendered as "nothing is running", which is a claim, not an absence.
  """
  @spec any_agent_live?(map(), [map()]) :: boolean()
  def any_agent_live?(worker, siblings \\ []) when is_map(worker) do
    SlotGate.agent_live(worker) != false or
      Enum.any?(subordinates_of(worker, siblings), &(SlotGate.agent_live(&1) == true))
  end

  @doc """
  The subset of `workers` that are subordinate rounds of `worker`'s task — a
  reviewer / implementer registered under a synthetic id pointing back here,
  or a pass sharing the task id under another key (the merge queue's per-kind
  pass keys before bd-741sid).
  """
  @spec subordinates_of(map(), [map()]) :: [map()]
  def subordinates_of(worker, workers) when is_map(worker) and is_list(workers) do
    task_id = Map.get(worker, :task_id)
    key = registry_key(worker)

    Enum.filter(workers, fn w ->
      registry_key(w) != key and role_of(w) != nil and
        (gate_author(w) == task_id or Map.get(w, :task_id) == task_id)
    end)
  end

  # ---- internals ------------------------------------------------------------

  defp author_phase(worker, siblings) do
    cond do
      SlotGate.agent_live(worker) == true -> :implementing
      round = live_round(worker, siblings) -> round
      Map.get(worker, :status) == :awaiting_review -> :waiting_ci_merge
      Map.get(worker, :status) == :awaiting_review_gate -> :in_review
      true -> :implementing
    end
  end

  defp live_round(worker, siblings) do
    live =
      worker
      |> subordinates_of(siblings)
      |> Enum.filter(&(SlotGate.agent_live(&1) == true))
      |> Enum.map(&role_of/1)

    Enum.find_value(@role_precedence, fn role ->
      if role in live, do: Map.fetch!(@role_phases, role)
    end)
  end

  # The round the pass *is*, whether or not its agent is live this instant
  # (phase is not liveness — see the moduledoc).
  defp subordinate_phase(worker), do: Map.fetch!(@role_phases, subordinate_role(worker))

  defp subordinate_role(worker) do
    role = role_of(worker)
    if is_map_key(@role_phases, role), do: role
  end

  defp role_of(worker) do
    Map.get(worker, :role) || meta_get(worker, :role)
  end

  defp gate_author(worker), do: meta_get(worker, :reviews) || meta_get(worker, :revises)

  defp registry_key(worker), do: Map.get(worker, :registry_key) || Map.get(worker, :task_id)

  defp meta_get(worker, key) do
    case Map.get(worker, :meta) do
      %{} = meta -> Map.get(meta, key) || Map.get(meta, to_string(key))
      _ -> nil
    end
  end
end
