defmodule Arbiter.Accounts.Serializer do
  @moduledoc """
  The one wire shape for `Arbiter.Accounts.ProviderAccount` — REST
  (`ArbiterWeb.Api.AccountJSON`) and the MCP `account_list` / `account_show`
  tools both render through it.

  The detailed form carries the account's credentials and attached
  workspaces. A credential is rendered as kind, env var and a fingerprint
  prefix only: the secret is never selected here (`ProviderCredential.secret`
  is `public? false`, write-only via `:create`), so no read surface can leak it.
  """

  require Ash.Query

  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}

  @fingerprint_prefix 12

  @doc """
  One account. `detailed?: true` adds `credentials` and `workspaces`.
  """
  @spec data(ProviderAccount.t(), keyword()) :: map()
  def data(%ProviderAccount{} = account, opts \\ []) do
    base = %{
      id: account.id,
      provider: account.provider,
      slug: account.slug,
      label: account.label,
      plan: account.plan,
      provider_account_ref: account.provider_account_ref,
      provider_org_ref: account.provider_org_ref,
      identity_source: account.identity_source,
      identity_verified_at: iso(account.identity_verified_at),
      max_concurrent: account.max_concurrent,
      quota_config: account.quota_config || %{},
      enabled: account.enabled,
      merged_into_id: account.merged_into_id,
      deleted_at: iso(account.deleted_at),
      inserted_at: iso(account.inserted_at),
      updated_at: iso(account.updated_at)
    }

    if Keyword.get(opts, :detailed?, false) do
      base
      |> Map.put(:credentials, Enum.map(credentials_for(account.id), &credential/1))
      |> Map.put(:workspaces, Enum.map(links_for(account.id), &link/1))
    else
      base
    end
  end

  @doc "A credential: kind, env var, fingerprint prefix and lifecycle — never the secret."
  @spec credential(ProviderCredential.t()) :: map()
  def credential(%ProviderCredential{} = credential) do
    %{
      id: credential.id,
      kind: credential.kind,
      env_var: credential.env_var,
      fingerprint: String.slice(credential.fingerprint, 0, @fingerprint_prefix),
      active: credential.active,
      scopes: credential.scopes,
      created_at: iso(credential.created_at),
      retired_at: iso(credential.retired_at)
    }
  end

  @doc "A workspace ↔ account attachment."
  @spec link(WorkspaceProviderAccount.t()) :: map()
  def link(%WorkspaceProviderAccount{} = link) do
    %{
      id: link.id,
      workspace_id: link.workspace_id,
      provider: link.provider,
      provider_account_id: link.provider_account_id,
      share: link.share
    }
  end

  defp credentials_for(account_id) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!()
  end

  defp links_for(account_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.read!()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
