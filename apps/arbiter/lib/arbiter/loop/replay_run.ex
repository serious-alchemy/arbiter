defmodule Arbiter.Loop.ReplayRun do
  @moduledoc """
  One offline replay of a closed task (R15, bd-c7lx65;
  `docs/design/paced-quota-routing-signals.md` §7.2-§7.3), written by
  `Arbiter.Loop.Replay` and nothing else.

  Replay evidence is **its own source**. It lives only here: a replay writes
  no `worker_runs`, `review_gate_rounds` or `usage_events` row, so
  `Arbiter.Loop.SubjectStats`, `Arbiter.Loop.Canary.Metrics` and the cost
  estimates never count it, and no path reads it into the competence matrix.
  `Arbiter.Loop.Replay.Evidence` summarises it, labelled as replay evidence.

  ## Fields

    * The subject: `task_id`, `workspace_id`, `repo`, the cell (`difficulty`,
      the first attempt's at dispatch, and `issue_type`), and what the live run
      used first (`live_provider`, `live_model`).
    * What was replayed: `provider` (the account's), `account_id`, `model`, the
      `pool` it draws on and the `thinking` level it ran at; the scoring
      reviewer's `reviewer_*` five.
    * Where: `base_sha`, `known_good_sha` and how they were found
      (`provenance`: `:pr_head` or `:squash_commit`).
    * `state`: `:running` from admission; then `:scored` (a verdict was read,
      or the replay changed nothing), `:unscored` (the replay ran but its
      scoring review was not admitted), `:failed`; or `:refused` (not
      admitted, nothing spent). `reason` says why for every state but a plain
      score.
    * The score: `verdict` and `converged` (round 1, by the live gate's rule),
      the CRITERIA counts, `tests` (the repo's pre-push recipe:
      `:passed | :failed | :timeout | :error | :not_run`), `file_overlap` and
      `line_overlap` with the merged change, and the `files` it touched.
    * `admission`: each pool's entry at admission (exploration budget, replays
      running, expiring headroom per window, binding).
    * `runs`: per step, its exit status, whether it timed out, its duration.

  A `:running` row holds its seats on both pools for
  `Arbiter.Loop.Replay.Admission` until it finishes, or until it is old enough
  that its node must have died (`Arbiter.Loop.Replay.running/1`); the next
  replay then finishes it as `:failed` (abandoned) and removes its checkout.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Loop,
    data_layer: AshSqlite.DataLayer

  @states [:running, :scored, :unscored, :refused, :failed]

  sqlite do
    table "replay_runs"
    repo Arbiter.Repo

    custom_indexes do
      index [:state]
      index [:task_id]
      index [:provider, :model, :difficulty, :issue_type]
    end
  end

  actions do
    defaults [:read]

    create :start do
      primary? true

      accept [
        :task_id,
        :workspace_id,
        :repo,
        :difficulty,
        :issue_type,
        :provider,
        :account_id,
        :model,
        :pool,
        :thinking,
        :reviewer_provider,
        :reviewer_account_id,
        :reviewer_model,
        :reviewer_pool,
        :reviewer_thinking,
        :live_provider,
        :live_model,
        :base_sha,
        :known_good_sha,
        :provenance,
        :state,
        :reason,
        :admission,
        :started_at,
        :finished_at
      ]
    end

    update :finish do
      primary? true

      accept [
        :state,
        :reason,
        :verdict,
        :converged,
        :criteria_total,
        :criteria_unmet,
        :tests,
        :file_overlap,
        :line_overlap,
        :files,
        :runs,
        :finished_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :task_id, :string, allow_nil?: false, public?: true
    attribute :workspace_id, :string, public?: true
    attribute :repo, :string, public?: true
    attribute :difficulty, :integer, public?: true
    attribute :issue_type, :string, public?: true

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :account_id, :string, public?: true
    attribute :model, :string, allow_nil?: false, public?: true
    attribute :pool, :string, public?: true
    attribute :thinking, :string, public?: true

    attribute :reviewer_provider, :string, public?: true
    attribute :reviewer_account_id, :string, public?: true
    attribute :reviewer_model, :string, public?: true
    attribute :reviewer_pool, :string, public?: true
    attribute :reviewer_thinking, :string, public?: true

    attribute :live_provider, :string, public?: true
    attribute :live_model, :string, public?: true

    attribute :base_sha, :string, public?: true
    attribute :known_good_sha, :string, public?: true

    attribute :provenance, :atom do
      public? true
      constraints one_of: [:pr_head, :squash_commit]
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: @states
    end

    attribute :reason, :string, public?: true

    attribute :verdict, :atom do
      public? true
      constraints one_of: [:approve, :request_changes, :no_verdict]
    end

    attribute :converged, :boolean, public?: true
    attribute :criteria_total, :integer, public?: true
    attribute :criteria_unmet, :integer, public?: true

    attribute :tests, :atom do
      public? true
      constraints one_of: [:passed, :failed, :timeout, :error, :not_run]
    end

    attribute :file_overlap, :float, public?: true
    attribute :line_overlap, :float, public?: true
    attribute :files, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :admission, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :runs, :map, allow_nil?: false, default: %{}, public?: true

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc "Every state a replay record can be in."
  @spec states() :: [atom()]
  def states, do: @states
end
