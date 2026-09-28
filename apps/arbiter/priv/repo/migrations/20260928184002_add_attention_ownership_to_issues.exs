defmodule Arbiter.Repo.Migrations.AddAttentionOwnershipToIssues do
  @moduledoc """
  Ticket lifecycle 7/13 (bd-8nlez1): coordinator-first attention. See
  `docs/design/ticket-lifecycle.md` ("Child 7").

  `issues`:

    * `attention_owner` / `attention_owner_cause` — who owns the ticket's
      attention when a hand-off, a hand-back or an expired limit moved it off
      the owner table's default, and the cause that move applies to;
    * `attention_note` — the hand-off note, or the limit that expired;
    * `attention_owner_since` — when the owner last moved; a hand-back
      restarts the coordinator's clock from here;
    * `attention_resume_attempts` — how many times the ticket's run was
      resumed out of a failed run while the ticket stayed in its state.

  Every existing row starts with no override and no attempts. Hand-written,
  like the other lifecycle migrations.
  """

  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :attention_owner, :text
      add :attention_owner_cause, :text
      add :attention_note, :text
      add :attention_owner_since, :utc_datetime_usec
      add :attention_resume_attempts, :bigint, null: false, default: 0
    end
  end
end
