defmodule Arbiter.Boot.TicketTransitions do
  @moduledoc """
  Backfill `ticket_transitions` from the paper trail on boot (bd-d8fi92;
  reports design v2 §3.4) — see `Arbiter.Tasks.TicketTransitionBackfill`.

  Mirrors `Arbiter.Boot.ProviderAccounts`: a one-shot synchronous worker that
  returns `:ignore`, placed after the schema migrator (which creates the
  table) and before the boot tasks that start the per-workspace queues, so no
  dispatch writes a live row while it runs. Only the `Arbiter.SingleInstance`
  primary writes.

  Once every ticket's history has started — after the first run, and on any
  install created after the triggers shipped — it is one indexed query.

  Never aborts the boot: a failure is logged, and the next boot retries the
  tickets it did not write. A mismatch is logged and reconciled by the
  backfill itself.
  """

  require Logger

  alias Arbiter.SingleInstance
  alias Arbiter.Tasks.TicketTransitionBackfill

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
  On the primary instance, apply the backfill. Always `:ignore`.

  `:primary?` overrides the `Arbiter.SingleInstance.primary?/0` lookup (for
  tests); it is evaluated at start time so `Arbiter.Application.children/1`
  stays a pure spec builder.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :primary?, &SingleInstance.primary?/0) do
      TicketTransitionBackfill.backfill(apply?: true, cfd_days: [])
    end

    :ignore
  rescue
    e ->
      Logger.error("Boot.TicketTransitions: #{Exception.format(:error, e, __STACKTRACE__)}")
      :ignore
  end
end
