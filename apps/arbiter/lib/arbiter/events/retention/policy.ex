defmodule Arbiter.Events.Retention.Policy do
  @moduledoc """
  Behaviour deciding how long `Arbiter.Events.Record` rows are kept.

  `Arbiter.Events.Retention.sweep/1` asks the configured policy
  (`config :arbiter, :events_retention, policy: Mod`) for a cutoff on every
  sweep and deletes rows whose `occurred_at` is older than it. The default,
  `Arbiter.Events.Retention.Default`, is the config-driven `:retention_days`
  window (7 days unless overridden).

  A policy can hold records longer, or return `:keep` to prune nothing
  (e.g. while an exporter or sealer catches up).
  """

  @doc """
  Return the cutoff before which rows may be pruned, or `:keep` to prune
  nothing this sweep. `now` is the sweep time; `opts` are the options passed
  to `sweep/1` (e.g. `:retention_days`).
  """
  @callback cutoff(now :: DateTime.t(), opts :: keyword()) :: DateTime.t() | :keep
end
