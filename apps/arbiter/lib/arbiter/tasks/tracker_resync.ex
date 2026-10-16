defmodule Arbiter.Tasks.TrackerResync do
  @moduledoc """
  Conflict rules for re-syncing an already-claimed ticket with its tracker story
  (bd-evxsrx). A claim copies the story once; this decides what a *later* edit of
  the story does to the ticket. Pure — `Arbiter.Tasks.Claim` fetches the story
  and carries out the `decision`.

  ## The three-way comparison

  Each pulled field (`title`, `description`, `priority`) is compared across three
  values: the **tracker** now (`observed`), the **ticket** now, and the
  **snapshot** — what the tracker said when the ticket was last reconciled
  (`Issue.tracker_snapshot`, written at claim). The snapshot is the common
  ancestor, which is the only way to tell *who* changed a field:

  | tracker vs snapshot | ticket vs snapshot | outcome |
  |---|---|---|
  | same | any | nothing to do |
  | changed | same, ticket is `backlog`/`queued` | **applied** to the ticket |
  | changed | same, ticket is in flight | **mid-flight** — ticket untouched, coordinator told |
  | changed | changed (and not to the tracker's value) | **divergent** — the local value wins, coordinator told |
  | changed | changed to the tracker's value | converged — snapshot catches up, no note |

  A ticket is *in flight* once it has left `backlog`/`queued` (`active`,
  `merging`, `verifying`): a worker or reviewer is holding the old text. A local
  override wins in every state; it is never reported as anything but divergent.

  ## Closed / archived stories

  A story closed or archived upstream is **flagged** to the coordinator and the
  ticket is left exactly as it is — never closed or parked by the sync. It is
  flagged once per closing (the snapshot remembers), and flagged again if the
  story is reopened and closed later. No field is pulled from a closed story.

  ## Quiet by default

  The coordinator is told once per distinct tracker value: the snapshot's `noted`
  map remembers the tracker value each mid-flight / divergent note was about, so
  an unchanged story never re-posts on the next sync. A ticket claimed before
  snapshots existed (`tracker_snapshot` nil) *adopts* the tracker's current
  values on its first re-sync and is not otherwise touched.
  """

  alias Arbiter.Tasks.Issue

  @fields [:title, :description, :priority]
  @pullable_states [:backlog, :queued]

  # `Issue.priority`'s default; stands in for the tracker's value when the story
  # carries none, so a priority the story gains later reads as an edit to pull.
  @default_priority 2

  @typedoc "The story as the tracker serves it now, normalised."
  @type observed :: %{
          title: String.t(),
          description: String.t(),
          priority: 0..4 | nil,
          closed?: boolean()
        }

  @typedoc """
  What a re-sync does to one ticket. `applied` is the `field => value` pulled
  onto the ticket; `divergent` / `mid_flight` list the fields the coordinator is
  told about; `closed_upstream` is true only when a closed story is newly
  flagged; `snapshot` is the snapshot to store; `observed` is the tracker story the
  decision was made from, so applying a plan can decide again against the ticket
  as it is *then*.
  """
  @type decision :: %{
          applied: %{atom() => term()},
          divergent: [atom()],
          mid_flight: [atom()],
          closed_upstream: boolean(),
          snapshot: map(),
          observed: observed()
        }

  @doc "Whether `state` is one a re-sync may rewrite (the ticket is not being worked)."
  @spec pullable_state?(atom()) :: boolean()
  def pullable_state?(state), do: state in @pullable_states

  @doc "A planned decision whose work turned out to be done already: nothing left to apply or tell."
  @spec settled(decision()) :: decision()
  def settled(decision),
    do: %{decision | applied: %{}, divergent: [], mid_flight: [], closed_upstream: false}

  @doc "Read the pulled fields (and closed state) off a fetched tracker issue."
  @spec observe(module(), map()) :: observed()
  def observe(adapter, issue_map) do
    %{
      title: normalize(adapter.extract_title(issue_map)),
      description: normalize(adapter.extract_description(issue_map)),
      priority: extracted_priority(adapter, issue_map),
      closed?: adapter.issue_status(issue_map) == :closed
    }
  end

  @doc "The snapshot to store when a ticket is first claimed from `observed`."
  @spec initial_snapshot(observed()) :: map()
  def initial_snapshot(observed) do
    %{
      "title" => observed.title,
      "description" => observed.description,
      "priority" => observed.priority || @default_priority
    }
  end

  @doc """
  Decide what a re-sync does to `task` given the tracker's `observed` story.
  Returns `nil` when there is nothing to do (nothing to apply, tell or record).
  """
  @spec decide(Issue.t(), observed()) :: decision() | nil
  def decide(%Issue{} = task, observed) do
    previous = task.tracker_snapshot || %{}

    decision =
      if observed.closed?,
        do: decide_closed(previous),
        else: decide_open(task, observed, previous)

    decision = Map.put(decision, :observed, observed)

    if decision.snapshot == previous and decision.applied == %{} and
         decision.divergent == [] and decision.mid_flight == [] and
         not decision.closed_upstream,
       do: nil,
       else: decision
  end

  # A closed story: flag once, pull nothing, leave the ticket and the rest of the
  # snapshot as they were.
  defp decide_closed(previous) do
    flagged? = previous["closed_flagged"] == true

    %{
      applied: %{},
      divergent: [],
      mid_flight: [],
      closed_upstream: not flagged?,
      snapshot: Map.put(previous, "closed_flagged", true)
    }
  end

  defp decide_open(task, observed, previous) do
    # A reopened story re-arms the closed flag.
    base = Map.delete(previous, "closed_flagged")
    in_sync? = task.state in @pullable_states

    initial = %{
      applied: %{},
      divergent: [],
      mid_flight: [],
      closed_upstream: false,
      snapshot: base
    }

    Enum.reduce(@fields, initial, fn field, acc ->
      case Map.fetch!(observed, field) do
        nil -> acc
        theirs -> decide_field(acc, field, theirs, Map.get(task, field), in_sync?)
      end
    end)
  end

  defp decide_field(acc, field, theirs, ours, in_sync?) do
    key = Atom.to_string(field)
    snapshot = acc.snapshot

    case Map.fetch(snapshot, key) do
      # First sight of this field (a ticket claimed before snapshots): adopt.
      :error ->
        put_snapshot(acc, key, theirs)

      {:ok, ^theirs} ->
        # The tracker is back to (or still at) what we last reconciled.
        update_in(acc.snapshot, &drop_noted(&1, key))

      {:ok, base} ->
        ours = normalize_for(field, ours)

        cond do
          ours == theirs ->
            put_snapshot(acc, key, theirs)

          ours != base ->
            note(acc, :divergent, field, key, theirs)

          in_sync? ->
            acc
            |> put_snapshot(key, theirs)
            |> then(&%{&1 | applied: Map.put(&1.applied, field, theirs)})

          true ->
            note(acc, :mid_flight, field, key, theirs)
        end
    end
  end

  defp put_snapshot(acc, key, value),
    do: %{acc | snapshot: acc.snapshot |> Map.put(key, value) |> drop_noted(key)}

  # Tell the coordinator once per distinct tracker value.
  defp note(acc, kind, field, key, theirs) do
    noted = Map.get(acc.snapshot, "noted", %{})

    if Map.get(noted, key) == theirs do
      acc
    else
      acc = %{acc | snapshot: Map.put(acc.snapshot, "noted", Map.put(noted, key, theirs))}

      case kind do
        :divergent -> %{acc | divergent: acc.divergent ++ [field]}
        :mid_flight -> %{acc | mid_flight: acc.mid_flight ++ [field]}
      end
    end
  end

  defp drop_noted(snapshot, key) do
    case Map.get(snapshot, "noted") do
      %{^key => _} = noted ->
        case Map.delete(noted, key) do
          empty when map_size(empty) == 0 -> Map.delete(snapshot, "noted")
          rest -> Map.put(snapshot, "noted", rest)
        end

      _ ->
        snapshot
    end
  end

  defp extracted_priority(adapter, issue_map) do
    if function_exported?(adapter, :extract_priority, 1) do
      case adapter.extract_priority(issue_map) do
        {:ok, value} -> value
        nil -> nil
      end
    end
  end

  defp normalize_for(:priority, value), do: value
  defp normalize_for(_field, value), do: normalize(value)

  defp normalize(nil), do: ""
  defp normalize(value) when is_binary(value), do: String.trim(value)
end
