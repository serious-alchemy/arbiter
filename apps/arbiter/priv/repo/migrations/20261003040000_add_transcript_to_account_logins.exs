defmodule Arbiter.Repo.Migrations.AddTranscriptToAccountLogins do
  @moduledoc """
  Login relay 5/6 (bd-2prmjm, epic bd-dqvv90): the redacted pane transcript of
  a dashboard login, linked from the Login history row. Query strings, codes
  and operator keystrokes are blanked before it is written
  (`Arbiter.Accounts.LoginTranscript`).
  """

  use Ecto.Migration

  def change do
    alter table(:account_logins) do
      add :transcript, :text
    end
  end
end
