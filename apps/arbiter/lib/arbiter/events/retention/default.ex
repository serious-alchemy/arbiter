defmodule Arbiter.Events.Retention.Default do
  @moduledoc """
  Default `Arbiter.Events.Retention.Policy`: prune rows older than
  `:retention_days` (sweep option, else `config :arbiter, :events_retention`,
  else 7).
  """

  @behaviour Arbiter.Events.Retention.Policy

  @default_retention_days 7

  @impl true
  def cutoff(now, opts) do
    days =
      Keyword.get_lazy(opts, :retention_days, fn ->
        Arbiter.Events.Retention.config(:retention_days, @default_retention_days)
      end)

    DateTime.add(now, -days, :day)
  end
end
