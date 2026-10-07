defmodule ArbiterWeb.Api.AccountJSON do
  @moduledoc """
  Render functions for `Arbiter.Accounts.ProviderAccount` and friends.

  The wire shape is `Arbiter.Accounts.Serializer`, shared with the MCP
  `account_list` / `account_show` tools. `show` includes the account's
  credentials (kind/fingerprint/active only — **never** the secret value, per
  P11's acceptance bar) and attached workspaces, so `arb account show <slug>`
  is a single round trip.
  """

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Serializer

  def index(%{accounts: accounts}), do: %{data: Enum.map(accounts, &data/1)}

  def show(%{account: account}), do: data(account, detailed?: true)

  def attach(%{link: link}), do: Serializer.link(link)

  def credential(%{credential: credential}), do: Serializer.credential(credential)

  def data(%ProviderAccount{} = account, opts \\ []), do: Serializer.data(account, opts)
end
