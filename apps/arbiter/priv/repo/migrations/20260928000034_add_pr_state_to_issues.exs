defmodule Arbiter.Repo.Migrations.AddPrStateToIssues do
  @moduledoc """
  Ticket lifecycle 4/13 (bd-741sid): the ticket owns its open PR's state, so
  no worker has to stay resident to hold it. See
  `docs/design/ticket-lifecycle.md` ("Child 4") and `Arbiter.Tasks.PullRequest`.

    * `merger_url` — the PR's clickable URL, beside the existing `pr_ref`.
    * `merger_status` / `merger_checked_at` — the forge's last answer about the
      PR, as the ticket's Watchdog last read it, and when.
    * `merge_watch` — the lane the Watchdog watches the PR on (the adapter that
      opened it, whether the ReviewGate approved it, the pushed head and the
      reviewed-SHA baseline), so a Watchdog can be restarted from the row alone.
    * `review_gate_state` — the ReviewGate round state that used to live only
      in the parked author's memory.
    * `attention_cause` / `attention_detail` / `attention_since` — why the
      ticket needs a person. This child only writes `pr_closed`; bd-8if9zt
      renders the cause and adds the rest.

  Every column is nullable with no default and no backfill — safe to hot-run
  against the live database. Hand-written, like the other `issues` migrations
  (the resource snapshots are stale; see `20260824170000_add_refined_to_issues.exs`).
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :merger_url, :text
      add :merger_status, :map
      add :merger_checked_at, :utc_datetime_usec
      add :merge_watch, :map
      add :review_gate_state, :map
      add :attention_cause, :text
      add :attention_detail, :text
      add :attention_since, :utc_datetime_usec
    end
  end

  def down do
    alter table(:issues) do
      remove :merger_url
      remove :merger_status
      remove :merger_checked_at
      remove :merge_watch
      remove :review_gate_state
      remove :attention_cause
      remove :attention_detail
      remove :attention_since
    end
  end
end
