defmodule Arbiter.Boot.ProviderAccounts do
  @moduledoc """
  Resolve `:provider_accounts_enabled` for this boot (bd-cvvb02) — see
  `Arbiter.Accounts.Enablement` for the rule.

  Mirrors `Arbiter.Boot.ConfigMigrator`: a one-shot synchronous worker that
  returns `:ignore`, placed after the schema and config migrators so it reads
  a current schema, and before the boot tasks that start the per-workspace
  queues. The *resolution* is read-only and runs on every instance, so a
  duplicate boot answers `Arbiter.Accounts.enabled?/0` the same way; the
  fresh-install `<provider>:default` joins are writes, so only the
  `Arbiter.SingleInstance` primary makes them.

  Never aborts the boot: a failure resolves provider accounts off and logs.
  """

  require Logger

  alias Arbiter.Accounts.Enablement
  alias Arbiter.SingleInstance

  @doc "A one-shot temporary worker — nothing to restart."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Resolve the flag, then — on the primary instance of a fresh install —
  join every existing workspace to `<provider>:default`. Always `:ignore`.

  `:primary?` overrides the `Arbiter.SingleInstance.primary?/0` lookup (for
  tests); it is evaluated at start time so `Arbiter.Application.children/1`
  stays a pure spec builder.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    Enablement.resolve()

    if Enablement.auto_join?() and Keyword.get_lazy(opts, :primary?, &SingleInstance.primary?/0) do
      Enablement.join_defaults()
    end

    :ignore
  rescue
    e ->
      Logger.error("Boot.ProviderAccounts: #{Exception.format(:error, e, __STACKTRACE__)}")
      :ignore
  end
end
