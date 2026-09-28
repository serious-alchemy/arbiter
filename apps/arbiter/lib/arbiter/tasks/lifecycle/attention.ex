defmodule Arbiter.Tasks.Lifecycle.Attention do
  @moduledoc """
  The attention overlay's owner table (ticket lifecycle 6/13, bd-8if9zt;
  `docs/design/ticket-lifecycle.md` §4 and "Child 6").

  A ticket keeps its column and gains
  `attention: %{owner, waiting_on, reason}` — who has to act, on what, and
  why, in a sentence. `Arbiter.Tasks.Lifecycle.View` fills it through
  `of/3`, from the ticket's stored cause (`attention_cause` /
  `attention_detail` / `attention_since`), its state, and what its runs and
  its PR say. The map also carries the `:cause` it was read from and the
  `:since` it was raised at (nil for a derived one).

  ## The owner table

  **The coordinator comes first.** Everything the coordinator agent can act
  on is its own; a row is the operator's only when nothing in the fleet can
  move it. Child 7 (bd-8nlez1) adds the explicit hand-off and the time limits
  that move a coordinator-owned item to the operator.

  | cause | when | owner | waiting on |
  |---|---|---|---|
  | a ReviewGate park reason (`Arbiter.Tasks.ReviewPark.park_reasons/0`) | | coordinator | `:review_decision` |
  | `:pr_closed` | | coordinator | `:pr_decision` |
  | `:merge_blocked` | | coordinator | `:merge_block` |
  | `:merge_blocked` | the PR needs an approval the fleet cannot give | operator | `:approval` |
  | `:awaiting_manual_merge` | | operator | `:manual_merge` |
  | `:run_crashed` | | coordinator | `:resume` |
  | `:run_asked_question` | | coordinator | `:answer` |
  | `:awaiting_verification` | | coordinator | `:verification` |

  ## Where the cause comes from

  A stored cause wins. With none stored, one is derived:

    * `:verifying` → `:awaiting_verification`;
    * `:merging` whose PR is blocked for a reason the Watchdog does not clear
      by itself, or whose Watchdog is gone → `:merge_blocked`;
    * `:active` whose primary author run is waiting on a question →
      `:run_asked_question`;
    * `:active` whose author runs all finished without succeeding, or that
      has no run at all past the dispatch grace → `:run_crashed` — unless any
      run on the ticket is still live: a failed run with a follow-up round
      under way is the machine's turn, not anyone's attention.

  Every other ticket has no attention (`nil`).

  The stored cause is cleared when the ticket's state moves on or its run
  restarts (`Arbiter.Tasks.Attention.clear/2`), and the ticket's escalations
  are resolved in the same step.
  """

  alias Arbiter.Tasks.ReviewPark

  @type owner :: :coordinator | :operator

  @type t :: %{
          owner: owner(),
          waiting_on: atom(),
          reason: String.t(),
          cause: atom(),
          since: DateTime.t() | nil
        }

  @typedoc """
  What `Lifecycle.View` read from the ticket's runs and PR:

    * `:state` — the ticket's effective state;
    * `:run` — `:question` (the primary author run asked one), `:failed`
      (every author run finished without succeeding), `:orphaned` (no run
      at all past the dispatch grace), `:live` (a run on the ticket is still
      live) or nil;
    * `:block` — the PR's effective block reason, or nil;
    * `:watchdog_alive` — whether the ticket's Watchdog is running (nil when
      unknown).
  """
  @type facts :: %{
          optional(:state) => atom() | nil,
          optional(:run) => :question | :failed | :orphaned | :live | nil,
          optional(:block) => atom() | nil,
          optional(:watchdog_alive) => boolean() | nil
        }

  @approval_blocks [:needs_approval, :needs_nonauthor_approval]
  @auto_resolving_blocks [:behind_base, :ci_failed]

  @rows [
          {:pr_closed, nil, :coordinator, :pr_decision, "its PR was closed without merging"},
          {:merge_blocked, nil, :coordinator, :merge_block, "its PR's merge is blocked"},
          {:merge_blocked, :approval, :operator, :approval,
           "its PR needs an approval the fleet cannot give"},
          {:awaiting_manual_merge, nil, :operator, :manual_merge,
           "approved, and auto-merge is off — a person merges it"},
          {:run_crashed, nil, :coordinator, :resume, "its run stopped without finishing"},
          {:run_asked_question, nil, :coordinator, :answer, "its run asked a question"},
          {:awaiting_verification, nil, :coordinator, :verification,
           "merged — waiting on a restart-and-observe"}
        ] ++
          for(
            reason <- ReviewPark.park_reasons(),
            do:
              {reason, nil, :coordinator, :review_decision,
               "ReviewGate parked — " <> ReviewPark.subject_phrase(reason)}
          )

  @causes @rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  @doc """
  The owner table, one map per row: `:cause`, `:when` (nil, or `:approval`
  for the approval-blocked merge), `:owner`, `:waiting_on`, and the default
  `:reason` sentence.
  """
  @spec table() :: [map()]
  def table do
    for {cause, qualifier, owner, waiting_on, reason} <- @rows,
        do: %{cause: cause, when: qualifier, owner: owner, waiting_on: waiting_on, reason: reason}
  end

  @doc "Every attention cause a ticket can store (`Issue.attention_cause`)."
  @spec causes() :: [atom()]
  def causes, do: @causes

  @doc """
  The ticket's attention, from its stored cause and `facts`, or nil. See the
  moduledoc.
  """
  @spec of(map(), facts()) :: t() | nil
  def of(ticket, facts) when is_map(ticket) and is_map(facts) do
    case Map.get(facts, :state) do
      state when state in [:active, :merging, :verifying] ->
        case stored(ticket) || derived(state, facts) do
          nil -> nil
          {cause, detail, since} -> build(cause, detail, since, facts)
        end

      _ ->
        nil
    end
  end

  defp stored(ticket) do
    case Map.get(ticket, :attention_cause) do
      cause when cause in @causes ->
        {cause, Map.get(ticket, :attention_detail), Map.get(ticket, :attention_since)}

      _ ->
        nil
    end
  end

  defp derived(:verifying, _facts), do: {:awaiting_verification, nil, nil}

  defp derived(:merging, facts) do
    block = Map.get(facts, :block)

    cond do
      block != nil and block not in @auto_resolving_blocks -> {:merge_blocked, nil, nil}
      Map.get(facts, :watchdog_alive) == false -> {:merge_blocked, "no Watchdog is polling its PR", nil}
      true -> nil
    end
  end

  defp derived(:active, facts) do
    case Map.get(facts, :run) do
      :question -> {:run_asked_question, nil, nil}
      :failed -> {:run_crashed, nil, nil}
      :orphaned -> {:run_crashed, "its worker stopped — nothing is working on it", nil}
      _ -> nil
    end
  end

  defp build(cause, detail, since, facts) do
    qualifier = if cause == :merge_blocked and Map.get(facts, :block) in @approval_blocks, do: :approval

    {^cause, _, owner, waiting_on, default} =
      Enum.find(@rows, &match?({^cause, ^qualifier, _, _, _}, &1))

    %{
      owner: owner,
      waiting_on: waiting_on,
      reason: present(detail) || default,
      cause: cause,
      since: since
    }
  end

  defp present(detail) when is_binary(detail) and detail != "", do: detail
  defp present(_), do: nil
end
