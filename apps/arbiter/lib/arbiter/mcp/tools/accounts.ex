defmodule Arbiter.MCP.Tools.Accounts do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the read side of provider accounts and
  pauses (P-17): `account_list`, `account_show`, `provider_list`.

  Read-only and coordinator-only. Accounts render through
  `Arbiter.Accounts.Serializer`, the same shape `GET /api/accounts[/:ref]`
  returns: a credential is its kind, env var and a fingerprint *prefix* — the
  secret is never selected, so nothing here can leak it. Pauses are
  `Arbiter.Providers.Pause.to_json/0`, as `GET /api/providers/paused`.
  """

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Serializer
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Providers.Pause

  @doc """
  Accounts ordered by provider then slug. Optional `provider`,
  `include_merged` and `include_deleted` (both default false). Coordinator only.
  """
  @spec account_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def account_list(%Scope{} = _scope, args) do
    with {:ok, provider} <- provider_arg(args),
         {:ok, include_merged} <- Tools.fetch_bool(args, "include_merged", false),
         {:ok, include_deleted} <- Tools.fetch_bool(args, "include_deleted", false) do
      opts =
        [include_merged: include_merged, include_deleted: include_deleted]
        |> then(&if(provider, do: Keyword.put(&1, :provider, provider), else: &1))

      accounts = opts |> Accounts.list_accounts() |> Enum.map(&Serializer.data/1)
      {:ok, %{accounts: accounts, count: length(accounts)}}
    end
  end

  @doc """
  One account by `ref` (uuid, `provider:slug` or an unambiguous bare slug),
  with its credentials (kind + fingerprint prefix) and attached workspaces.
  Coordinator only.
  """
  @spec account_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def account_show(%Scope{} = _scope, args) do
    with {:ok, ref} <- Tools.require_string(args, "ref") do
      case Accounts.get_account(ref) do
        {:ok, account} ->
          {:ok, Serializer.data(account, detailed?: true)}

        {:error, :not_found} ->
          {:error, {:not_found, "account #{inspect(ref)} not found"}}

        {:error, :ambiguous} ->
          {:error, {:invalid, "ambiguous account reference — use provider:slug"}}
      end
    end
  end

  @doc "Every active provider / account pause (`GET /api/providers/paused`). Coordinator only."
  @spec provider_list(Scope.t(), map()) :: {:ok, map()}
  def provider_list(%Scope{} = _scope, _args), do: {:ok, %{paused: Pause.to_json()}}

  defp provider_arg(args) do
    case Tools.fetch_string(args, "provider") do
      nil ->
        {:ok, nil}

      raw ->
        case Accounts.parse_provider(raw) do
          {:ok, provider} -> {:ok, provider}
          :error -> {:error, {:invalid, "unknown provider #{inspect(raw)}"}}
        end
    end
  end
end
