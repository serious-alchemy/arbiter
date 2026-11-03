defmodule Arbiter.Worker.RunFindings do
  @moduledoc """
  Did a research run write its findings *during that run*? (bd-48ycdn)

  A `research` ticket's deliverable is a write-up in `notes`. The notes gate used
  to ask only "are the notes non-blank?", which a ticket that already carried
  coordinator-written notes (context, earlier findings, a link list) satisfied
  with no new work: on 2026-11-02 bd-4okm97 ran on a cluster node, its worker
  could not reach `research_read` or the MCP tools, wrote nothing, printed
  `arb done` ("I couldn't do the readout"), and the ticket closed `completed`
  because notes from 10-15 were already there.

  `written?/3` reads the ticket's paper-trail history (`Arbiter.Tasks.Issue.Version`)
  and answers whether the run's own actor (`worker:<ticket>`, the label the
  worker's bearer token resolves to — see `Arbiter.Actor.from_scope/1`) changed
  `notes` at or after the run's start. A coordinator's or operator's write, or any
  write from before the run, does not count.
  """

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.Tasks.Issue.Version
  alias Arbiter.Workers.Run

  # A resume chain is walked back to its first run so findings written before
  # a stop/resume still count. Bounded: a corrupt cycle must not loop.
  @max_chain 25

  @doc """
  True when `task_id`'s own worker actor changed `notes` at or after `since`.

  `{:error, reason}` for an unreadable history, so the caller can choose its
  failure policy.
  """
  @spec written?(String.t(), DateTime.t() | nil) :: boolean() | {:error, term()}
  def written?(task_id, since) when is_binary(task_id) do
    author = Actor.label(Actor.worker(task_id))

    Version
    |> Ash.Query.filter(version_source_id == ^task_id)
    |> filter_since(since)
    |> Ash.read!()
    |> Enum.any?(fn version ->
      Actor.of_version(version) == author and notes_change?(version)
    end)
  rescue
    e -> {:error, e}
  end

  @doc """
  The instant a run's findings window opens: its own start, or, for a run
  resumed out of earlier ones, the start of the first run in the chain.
  """
  @spec window_start(DateTime.t() | nil, String.t() | nil) :: DateTime.t() | nil
  def window_start(started_at, resumed_from_run_id),
    do: walk(started_at, resumed_from_run_id, @max_chain)

  defp walk(earliest, nil, _budget), do: earliest
  defp walk(earliest, _run_id, 0), do: earliest

  defp walk(earliest, run_id, budget) do
    case Ash.get(Run, run_id) do
      {:ok, %{started_at: %DateTime{} = started} = run} ->
        walk(earlier(earliest, started), Map.get(run, :resumed_from_run_id), budget - 1)

      _ ->
        earliest
    end
  rescue
    _ -> earliest
  end

  defp earlier(nil, b), do: b
  defp earlier(a, b), do: if(DateTime.compare(b, a) == :lt, do: b, else: a)

  defp filter_since(query, nil), do: query

  defp filter_since(query, %DateTime{} = since),
    do: Ash.Query.filter(query, version_inserted_at >= ^since)

  # `:changes_only` versions carry the changed attributes; an atomic
  # `append_notes` may not, so the recorded action inputs count too.
  defp notes_change?(version) do
    changes = version.changes || %{}
    inputs = version.version_action_inputs || %{}

    present?(Map.get(changes, "notes") || Map.get(changes, :notes)) or
      present?(Map.get(inputs, "notes") || Map.get(inputs, :notes)) or
      present?(Map.get(inputs, "append_notes") || Map.get(inputs, :append_notes))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
