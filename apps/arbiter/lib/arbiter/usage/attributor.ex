defmodule Arbiter.Usage.Attributor do
  @moduledoc """
  Write-time hook that stamps attribution dimensions on a `usage_events` row.

  Chargeback over history needs the dimension on rows written *now*; a row
  written without it can never be attributed retroactively. `Usage.Event`'s
  `:create` action calls `resolve/1` in a `before_action`, so every writer
  (worker, session ingest, external review, ...) is covered without touching
  each call site.

  The result lands in the nullable `attribution` map column (string keys).
  Select an implementation with

      config :arbiter, :usage_attributor, MyPackage.Attributor

  The default, `Arbiter.Usage.Attributor.Default`, records the dimensions core
  already knows (workspace, repo, provider, model, step, source). A custom
  attributor's keys are merged over those, so it can add team, cost-centre,
  tag or user dimensions or override a core one. A raising attributor or a
  non-map return is logged and ignored: the ledger row is never dropped.
  """

  alias Arbiter.Usage.Attributor.Default

  require Logger

  @doc "Returns the dimensions for a row about to be created; `attrs` is the changeset's attribute map."
  @callback attribute(attrs :: map()) :: %{optional(String.t()) => term()}

  @core_keys ~w(workspace_id repo provider model step source)a

  @doc false
  @spec resolve(map()) :: map()
  def resolve(attrs) do
    base = Default.attribute(attrs)

    case Application.get_env(:arbiter, :usage_attributor) do
      nil -> base
      Default -> base
      mod -> Map.merge(base, custom(mod, attrs))
    end
  end

  @doc false
  def core_keys, do: @core_keys

  defp custom(mod, attrs) do
    case mod.attribute(attrs) do
      %{} = dims -> Map.new(dims, fn {k, v} -> {to_string(k), v} end)
      other -> bad(mod, "returned #{inspect(other)}")
    end
  rescue
    e -> bad(mod, Exception.message(e))
  end

  defp bad(mod, why) do
    Logger.warning("Usage.Attributor #{inspect(mod)} ignored: #{why}")
    %{}
  end
end
