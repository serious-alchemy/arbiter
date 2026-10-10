defmodule Arbiter.Workers.PrepushStep do
  @moduledoc """
  One step of the pre-push check recipe (`Arbiter.Worker.PrepushCheck`) as it
  ran for a worker run, per attempt (bd-8wdrql): the result the commit gate saw
  before it pushed or sent the failure back to the session.

  Written by `Arbiter.Workers.PrepushSteps.record/4` — best-effort, like
  `Arbiter.Workers.RunStep`: a write failure logs a warning and never fails the
  run. Read back by `arb worker show` through `Arbiter.Workers.Serializer`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Workers,
    data_layer: AshSqlite.DataLayer

  @statuses [:passed, :failed, :timeout, :skipped, :error]

  sqlite do
    table "worker_prepush_steps"
    repo Arbiter.Repo

    custom_indexes do
      index [:run_id, :occurred_at]
      index [:task_id]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :run_id,
        :task_id,
        :attempt,
        :position,
        :name,
        :cmd,
        :scope,
        :status,
        :exit_status,
        :duration_ms,
        :output,
        :occurred_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :run_id, :uuid do
      public? true
      description "The Arbiter.Workers.Run this step ran for. Not a hard FK (best-effort)."
    end

    attribute :task_id, :string do
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :attempt, :integer do
      allow_nil? false
      public? true
      default 1

      description "Which pass of the gate this was: 1 for the first check, 2 after the first send-back, …"
    end

    attribute :position, :integer do
      allow_nil? false
      public? true
      default 0
      description "The step's index in the recipe."
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :cmd, :string do
      public? true
      constraints max_length: 2048, trim?: true
      description "The configured command (placeholders unexpanded)."
    end

    attribute :scope, :string do
      public? true
      constraints max_length: 16, trim?: true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: @statuses
    end

    attribute :exit_status, :integer, public?: true

    attribute :duration_ms, :integer, public?: true

    attribute :output, :string do
      public? true
      description "The bounded tail of the step's output (empty for a passing step)."
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end
end
