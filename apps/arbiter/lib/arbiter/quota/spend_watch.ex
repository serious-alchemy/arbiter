defmodule Arbiter.Quota.SpendWatch do
  @moduledoc """
  Pages the operator about a dollar spend cap (bd-a6grlr): once when an
  account's metered spend reaches 80% of its cap, and again when the cap is
  reached.

  A timer sweeps every capped, enabled account (`sweep/1`), computes its
  `Arbiter.Quota.SpendCap.status/2` - the same settled-plus-in-flight figure
  admission holds on - and keeps two system alerts (`Arbiter.Alerts`, kind
  `:spend_cap`) in step with it, keyed `<account id>:warning` and
  `<account id>:reached`:

    * spend at or past 80% and short of the cap: the warning is raised;
    * spend at or past the cap: the reached alert is raised and the warning is
      cleared (it is superseded);
    * anything else - the window reset, the cap was raised or removed, the
      account has no metered spend - clears both.

  An alert opens (and is announced to the operator's inbox) once per episode; a
  sweep that finds the same condition only refreshes its figures. After a clear,
  the next crossing pages again. Informational: the cap itself is enforced at
  admission, not here.

  ## Configuration

  `config :arbiter, :spend_watch`: `:enabled` (default `true`; `false` in test,
  where tests call `sweep/1` directly) and `:interval_ms` (default 2 minutes -
  settled spend only moves when a session ends).
  """

  use GenServer

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Quota.SpendCap

  require Logger

  @default_interval_ms :timer.minutes(2)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))
    if Keyword.get(opts, :enabled, config(:enabled, true)), do: schedule(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    sweep()
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  defp config(key, default) do
    :arbiter |> Application.get_env(:spend_watch, []) |> Keyword.get(key, default)
  end

  @doc """
  One sweep. Always returns `:ok` - a read that fails must not take the ticker
  down, and clears nothing. Options: `:status_opts` (`SpendCap.status/2`'s -
  `:now`, `:in_flight`) and `:accounts` (to supply the accounts).
  """
  @spec sweep(keyword()) :: :ok
  def sweep(opts \\ []) do
    accounts = Keyword.get_lazy(opts, :accounts, fn -> Accounts.list_accounts() end)
    status_opts = Keyword.get(opts, :status_opts, [])

    Enum.each(accounts, &check_account(&1, status_opts))

    # An account that is gone (merged, deleted) or no longer listed holds no
    # alert: drop the ones whose account the sweep did not see.
    CoordinatorNotifier.spend_cap_recovered(Enum.map(accounts, & &1.id))
    :ok
  rescue
    error ->
      Logger.warning("Quota.SpendWatch.sweep failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp check_account(%{enabled: false} = account, _status_opts),
    do: CoordinatorNotifier.spend_cap_cleared(account.id)

  defp check_account(account, status_opts) do
    case SpendCap.status(account, status_opts) do
      %{metered?: true, reached?: true} = status ->
        CoordinatorNotifier.spend_cap_alert(status, workspace_id(account), :reached)

      %{metered?: true, warn?: true} = status ->
        CoordinatorNotifier.spend_cap_alert(status, workspace_id(account), :warning)

      _ ->
        CoordinatorNotifier.spend_cap_cleared(account.id)
    end
  end

  defp workspace_id(account) do
    case Resolver.workspaces(account.id) do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end
end
