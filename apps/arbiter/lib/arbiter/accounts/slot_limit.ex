defmodule Arbiter.Accounts.SlotLimit do
  @moduledoc """
  Which limit is *binding* when a workspace has no free worker slot, and how to
  say so (bd-48prlb).

  `Arbiter.Board.Snapshot.effective_max_concurrent/3` folds the limits into
  one number — the install's machine capacity and the provider account's
  ceiling (`Concurrency.clamp/3`). That number is a derived, workspace-framed
  figure: when the account ceiling binds it is `min(base, own + (ceiling −
  live))`, and the account's live count includes every run on the account —
  other workspaces, review and fix passes — not just the slot holders. Quoting
  it ("the cap is 1") reads as if somebody lowered the cap. This module names
  the limit that actually binds and lists every run counted against it.
  """

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.Resolver

  @typedoc "The binding limit. `:account` carries the live runs counted against it."
  @type t ::
          %{limit: :install, max: non_neg_integer()}
          | %{
              limit: :account,
              name: String.t(),
              max: non_neg_integer(),
              live: non_neg_integer(),
              runs: [String.t()]
            }

  @doc """
  Classify the binding limit from its inputs (pure).

  `account` is `nil` or `%{name:, limit:, live:, runs:}`; `own` is the
  workspace's own live count, as `Concurrency.clamp/3` takes it.
  """
  @spec classify(non_neg_integer(), map() | nil, non_neg_integer()) :: t()
  def classify(system_max, account, own) do
    case account do
      %{limit: limit, live: live} = acct when is_integer(limit) ->
        if own + max(0, limit - live) < system_max do
          %{limit: :account, name: acct.name, max: limit, live: live, runs: acct.runs}
        else
          %{limit: :install, max: system_max}
        end

      _ ->
        %{limit: :install, max: system_max}
    end
  end

  @doc "The binding limit for `workspace` (a `Workspace` struct) given its `own` live count."
  @spec binding(Arbiter.Tasks.Workspace.t(), non_neg_integer() | nil) :: t() | nil
  def binding(%Arbiter.Tasks.Workspace{} = ws, own) do
    system_max = Arbiter.Board.Snapshot.install_capacity()
    provider = Arbiter.Quota.default_provider(ws)
    account = Resolver.account(ws.id, provider)

    acct =
      with %{} <- account,
           limit when is_integer(limit) <- Concurrency.limit(account, ws) do
        runs = Concurrency.holders(account)
        %{name: account_name(account), limit: limit, live: length(runs), runs: runs}
      else
        _ -> nil
      end

    own = own || (acct && length(Concurrency.holders(account))) || 0
    classify(system_max, acct, own)
  rescue
    _ -> nil
  end

  def binding(_workspace, _own), do: nil

  @doc """
  The operator-facing phrase for a binding limit. `holders` are the slot-holding
  tickets, used only when the install cap binds.
  """
  @spec describe(t() | nil, [String.t()]) :: String.t() | nil
  def describe(%{limit: :account} = b, _holders) do
    "account #{b.name} at #{b.live}/#{b.max} live (#{runs(b.runs)})"
  end

  def describe(%{limit: :install, max: max}, holders) do
    "the install cap is #{max} and #{held_by(holders)}"
  end

  def describe(_binding, _holders), do: nil

  @doc "`\"bd-x implement, bd-y review\"` — each counted run with its role."
  @spec runs([String.t()]) :: String.t()
  def runs([]), do: "no runs"
  def runs(keys), do: Enum.map_join(keys, ", ", &"#{task_of(&1)} #{role(&1)}")

  @doc "The role a registry key names."
  @spec role(String.t()) :: String.t()
  def role(key) do
    cond do
      String.contains?(key, "#review") -> "review"
      String.contains?(key, ":fixpass") -> "fix"
      String.contains?(key, ":conflict") -> "conflict"
      true -> "implement"
    end
  end

  defp task_of(key), do: key |> String.split([":", "#"], parts: 2) |> hd()

  defp held_by([]), do: "no task is holding a slot"
  defp held_by(holders), do: "#{length(holders)} held by #{Enum.join(holders, ", ")}"

  defp account_name(%{provider: provider, slug: slug}), do: "#{provider}:#{slug}"
end
