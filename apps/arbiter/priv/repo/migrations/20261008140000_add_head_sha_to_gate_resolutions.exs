defmodule Arbiter.Repo.Migrations.AddHeadShaToGateResolutions do
  @moduledoc """
  The commit a gate resolution was recorded against (bd-651ine / #529).

  An `accept_as_is` / `amend` resolution authorises a merge of the head the
  coordinator looked at, not of whatever the branch grows afterwards. Nullable:
  NULL means no head was known when the resolution was recorded (no PR yet, a
  row from before this column), and covers whatever the ticket later merges.
  """

  use Ecto.Migration

  def change do
    alter table(:gate_resolutions) do
      add :head_sha, :text
    end
  end
end
