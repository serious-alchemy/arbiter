defmodule Arbiter.Reviews.ConflictReview do
  @moduledoc """
  The accounting for the conflict-resolution review path (bd-954ym8 / #134):
  how much review the path saved, readable after the fact.

  `Arbiter.Reviews.ConflictResolution` decides what a head that follows an
  approved commit adds; the ReviewGate and the Watchdog act on that and report
  each decision here, one durable `Arbiter.Events.Record` row on the
  `conflict_review` topic per decision:

    * `"auto_cover"` — a clean rebase or merge of the target: the head was
      covered with **no review round**. Carries `site` (`"review_gate"` or
      `"watchdog"`), the approved commit it derives from and why.
    * `"scoped_review"` — a hand-resolved conflict: a cheap `:conflict_review`
      round was dispatched over just the resolved hunks.
    * `"scoped_approved"` / `"scoped_rejected"` — how that round ended. A
      rejection means the resolution broke something; the finding goes to the
      implementer through the ordinary revise loop.
    * `"fallback"` — the head carries authored content (or git could not tell),
      so the ordinary full review ran. Carries the `reason`.

  `report/0` and `report/1` count them (the rows live for the
  `Arbiter.Events.Retention` window), so `auto_cover + scoped_review` against
  `fallback` is the share of re-reviews the path took off the queue.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Events

  @topic "conflict_review"
  @outcomes ~w(auto_cover scoped_review scoped_approved scoped_rejected fallback)
  @count_limit 5_000

  @typedoc "One of `outcomes/0`."
  @type outcome :: String.t()

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  Record one decision. `attrs` is merged into the event payload
  (`:task_id`, `:workspace_id`, `:mr_ref`, `:head`, `:site`, `:reason` …).
  Never raises: a lost row costs a count, not a merge.
  """
  @spec record(outcome(), map()) :: :ok
  def record(outcome, attrs) when outcome in @outcomes and is_map(attrs) do
    Logger.info(
      "ConflictReview: outcome=#{outcome} task=#{inspect(Map.get(attrs, :task_id))} " <>
        "head=#{inspect(Map.get(attrs, :head))} site=#{inspect(Map.get(attrs, :site))} " <>
        "reason=#{inspect(Map.get(attrs, :reason))}"
    )

    payload =
      attrs
      |> Map.drop([:workspace_id])
      |> Map.new(fn {k, v} -> {k, jsonable(v)} end)
      |> Map.put(:outcome, outcome)

    Events.broadcast(Map.get(attrs, :workspace_id), @topic, payload)
    :ok
  rescue
    e ->
      Logger.warning("ConflictReview: could not record #{outcome}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Counts per outcome over the retained rows — all of them, or one task's.
  Every outcome is present, zero when unseen.
  """
  @spec report(String.t() | nil) :: %{optional(outcome()) => non_neg_integer()}
  def report(task_id \\ nil) do
    counts =
      rows()
      |> Enum.filter(&(is_nil(task_id) or payload(&1, "task_id") == task_id))
      |> Enum.frequencies_by(&payload(&1, "outcome"))

    Map.new(@outcomes, &{&1, Map.get(counts, &1, 0)})
  end

  defp rows do
    Events.Record
    |> Ash.Query.filter(topic == @topic)
    |> Ash.Query.sort(seq: :desc)
    |> Ash.Query.limit(@count_limit)
    |> Ash.read!()
  rescue
    _ -> []
  end

  defp payload(record, key), do: Map.get(record.payload || %{}, key)

  defp jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp jsonable(nil), do: nil
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value), do: inspect(value, limit: 10, printable_limit: 300)
end
