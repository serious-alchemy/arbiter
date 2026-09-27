defmodule Arbiter.Repo.Migrations.RemoveGeminiCliProvider do
  @moduledoc """
  bd-ac53wz: the upstream Gemini CLI provider (`gemini_cli`) is dropped in
  favour of Antigravity (agy, the `antigravity` provider). `:gemini_cli` is no
  longer in `ProviderAccount.provider` / `WorkspaceProviderAccount.provider`'s
  `one_of`, so any row still carrying it would fail to load — remove every
  `gemini_cli` account (on a stock install, the auto-provisioned
  `gemini_cli:default`) together with what hangs off it: its workspace joins,
  its credentials and its Cloud Code quota rows.

  Explicit deletes rather than the `ON DELETE CASCADE` foreign keys, which
  SQLite only honours with `PRAGMA foreign_keys` on.

  `usage_events` is deliberately untouched: `provider` there is a free string,
  so historical `"gemini_cli"` rows stay readable verbatim in `arb usage`, and
  a `provider_account_id` naming a removed account still groups by its raw id
  (`--by provider_account`), exactly as for any other deleted account.

  `down/0` is a no-op: the removed rows can't be reconstructed, and the
  enums no longer admit them anyway.
  """

  use Ecto.Migration

  @accounts "SELECT id FROM provider_accounts WHERE provider = 'gemini_cli'"

  def up do
    execute("DELETE FROM provider_credentials WHERE provider_account_id IN (#{@accounts})")

    execute("""
    DELETE FROM workspace_provider_accounts
    WHERE provider = 'gemini_cli' OR provider_account_id IN (#{@accounts})
    """)

    execute("""
    DELETE FROM cloud_code_quotas
    WHERE provider = 'gemini_cli' OR provider_account_id IN (#{@accounts})
    """)

    execute("DELETE FROM provider_accounts WHERE provider = 'gemini_cli'")
  end

  def down, do: :ok
end
