defmodule Arbiter.ReviewGate.Resolution do
  @moduledoc """
  The coordinator's recorded answer to a gate escalation (bd-4qjl0q).

  A gate that cannot settle a task on its own — the ReviewGate hitting its round
  cap without converging, the notes gate or commit gate spending its send-back
  budget — escalates to the coordinator. Before this resource the escalation was
  *terminal in the data model*: the mail was read, the task moved on by whatever
  path the operator took out of band, and the decision left the system. In the
  case that motivated it (`vs-acnaup`, 2026-09-17) a coordinator amendment
  reverted a reviewer's verified fix for a standing High finding, and the only
  durable trace was a sentence in a commit message.

  One row per decision. Write it with `Arbiter.ReviewGate.Resolutions.record/1`
  (the MCP `review_gate_resolve` tool and `arb review resolve` both land there);
  `review_gate_rounds_list` returns it after the rounds it answers.

  ## Fields

    * `task_id`      — the escalated task.
    * `workspace_id` — the task's workspace, stamped at record time so the
                       resolution is queryable per workspace without a join.
    * `gate`         — which gate escalated: `:review_gate`, `:notes_gate` or
                       `:commit_gate`.
    * `decision`     — `:accept_as_is` (ship it with the finding standing),
                       `:amend` (the coordinator changes the requirement or
                       directs a specific change, on its own authority),
                       `:send_back` (return it to the implementer — **another
                       review round follows** its next completion), `:reject`
                       (abandon the work). Only `:accept_as_is` and `:amend`
                       permit a merge without a fresh reviewer APPROVE
                       (`Arbiter.ReviewGate.MergeAuthorization`).
    * `reasoning`    — why. Required and non-blank: a decision without its
                       reasoning is the gap this resource exists to close.
    * `actor`        — who decided (`"coordinator"` by default).
    * `round` / `fix_round_attempt`
                     — the ReviewGate round this answers, when there is one
                       (see `Arbiter.ReviewGate.Round` for the two axes). Nil
                       for a gate with no rounds.

    * `head_sha`     — the commit the decision was recorded against, when one
                       was known (bd-651ine). An `:accept_as_is` / `:amend`
                       authorises merging that head; a head pushed afterwards
                       needs a reviewer round or a new decision.

  ## What a resolution does NOT do

  It is a record, not an action: it does not resume, merge, close or re-open
  anything. An `:amend` closes the argument on the coordinator's authority — it
  does not pretend a confirming round 4 will follow — and whatever the
  coordinator then does (resume the worker, merge, close the ticket) goes
  through the existing verbs, as it did before. What changes is that the
  decision is addressable: who, when, which round, and why.

  It is also a *gate on merging*, in one direction only. The merge path
  (`Arbiter.ReviewGate.MergeAuthorization`) refuses a ticket whose latest
  reviewer round did not approve, and only an `:accept_as_is` / `:amend`
  recorded after that round lifts the refusal. `:send_back` and `:reject` never
  do: a `:send_back` ticket merges only after the implementer finishes and the
  gate's next reviewer round approves the new head.

  ## Retention

  Kept indefinitely, like `Arbiter.ReviewGate.Round`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.ReviewGate,
    data_layer: AshSqlite.DataLayer

  @gates ~w(review_gate notes_gate commit_gate)a
  @decisions ~w(accept_as_is amend send_back reject)a

  sqlite do
    table "gate_resolutions"
    repo Arbiter.Repo

    custom_indexes do
      index [:task_id, :inserted_at]
      index [:workspace_id, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :task_id,
        :workspace_id,
        :gate,
        :decision,
        :reasoning,
        :actor,
        :round,
        :fix_round_attempt,
        :head_sha
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :task_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :workspace_id, :string do
      public? true
      constraints max_length: 255
    end

    attribute :gate, :atom do
      allow_nil? false
      public? true
      default :review_gate
      constraints one_of: @gates
    end

    attribute :decision, :atom do
      allow_nil? false
      public? true
      constraints one_of: @decisions
    end

    attribute :reasoning, :string do
      allow_nil? false
      public? true
      constraints trim?: true
      description "Why the coordinator decided this. Required and non-blank."
    end

    attribute :actor, :string do
      allow_nil? false
      public? true
      default "coordinator"
      constraints max_length: 255, trim?: true
    end

    attribute :round, :integer do
      public? true
      constraints min: 1
      description "The ReviewGate round this answers. Nil for a gate with no rounds."
    end

    attribute :fix_round_attempt, :integer do
      public? true
      constraints min: 0
      description "The fix-round pass `round` belongs to. Nil alongside a nil `round`."
    end

    attribute :head_sha, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "The commit the decision was recorded against, when known. See `Arbiter.ReviewGate.MergeAuthorization`."
    end

    create_timestamp :inserted_at
  end

  @doc "All valid gate atoms."
  @spec gates() :: [atom()]
  def gates, do: @gates

  @doc "All valid decision atoms."
  @spec decisions() :: [atom()]
  def decisions, do: @decisions
end
