defmodule Arbiter.MCP.Tools.Account do
  @moduledoc """
  `Arbiter.MCP.Tools` handler for provider accounts (bd-1kr3qf, parity P-16):
  `account_set`.

  Coordinator-only, like `provider_pause` — the same class of fleet-routing
  lever. It edits the **non-secret** fields in `Arbiter.Accounts.Fields`
  (`names(:mcp)`: label, plan, enabled, max_concurrent and a `quota_config`
  patch) through `Arbiter.Accounts.edit_account/2`, the one write `PATCH
  /api/accounts/:ref`, `arb account set` and the Providers form use.

  There is deliberately no MCP tool to create, attach, detach, merge, delete,
  rotate or log in an account: a secret as a tool argument would sit in the model
  transcript and MCP request logs, and the rest are operator topology changes.
  The parity manifest records each as `:intentional`. A key outside the
  registry (`slug`, `secret`, ...) is refused by name, never ignored.
  """

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Fields
  alias Arbiter.MCP.Scope

  @doc """
  Edit one account. `ref` is a uuid, `provider:slug` or a bare slug; at least one
  of the `Fields.names(:mcp)` must be given, and a `null` `quota_config` value
  clears that key. Coordinator only.
  """
  @spec account_set(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def account_set(%Scope{} = _scope, args) do
    with {:ok, ref} <- require_ref(args),
         attrs = Map.drop(args, ["ref"]),
         :ok <- reject_outside_registry(attrs),
         {:ok, account} <- ref |> Accounts.edit_account(attrs) |> normalize() do
      {:ok, %{account: serialize(account)}}
    end
  end

  defp require_ref(args) do
    case Map.get(args, "ref") do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _ -> {:error, {:invalid, "missing required parameter: ref"}}
    end
  end

  defp reject_outside_registry(attrs) do
    case Map.keys(attrs) -- Fields.names(:mcp) do
      [] ->
        :ok

      unknown ->
        {:error,
         {:invalid,
          "cannot set #{Enum.join(Enum.sort(unknown), ", ")} over MCP — settable: " <>
            Enum.join(Fields.names(:mcp), ", ")}}
    end
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, :not_found}), do: {:error, {:not_found, "no such account"}}

  defp normalize({:error, :ambiguous}),
    do: {:error, {:invalid, "ambiguous account reference — use provider:slug"}}

  defp normalize({:error, {kind, message}})
       when kind in [:invalid_account, :invalid_quota_config],
       do: {:error, {:invalid, message}}

  defp normalize({:error, %Ash.Error.Invalid{} = error}),
    do: {:error, {:invalid, Exception.message(error)}}

  defp normalize({:error, other}), do: {:error, {:invalid, "could not edit: #{inspect(other)}"}}

  # Account columns only — never a credential, fingerprint or secret.
  defp serialize(account) do
    %{
      id: account.id,
      provider: to_string(account.provider),
      slug: account.slug,
      label: account.label,
      plan: account.plan,
      enabled: account.enabled,
      max_concurrent: account.max_concurrent,
      quota_config: account.quota_config || %{}
    }
  end
end
