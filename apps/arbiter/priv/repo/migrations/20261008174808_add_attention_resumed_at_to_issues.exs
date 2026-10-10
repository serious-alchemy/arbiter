defmodule Arbiter.Repo.Migrations.AddAttentionResumedAtToIssues do
  @moduledoc """
  Adds `issues.attention_resumed_at` (bd-98gi5m): the timestamp when the ticket was
  last resumed from a failed run (`resumed_from_failure: true`), so the attention
  sweep's resume attempts escalation can tell attempts made after the current
  attention was raised apart from attempts from earlier ticket history.
  """

  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :attention_resumed_at, :utc_datetime_usec
    end
  end
end
