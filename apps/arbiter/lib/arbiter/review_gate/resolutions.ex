defmodule Arbiter.ReviewGate.Resolutions do
  @moduledoc """
  Record and read the coordinator's answer to a gate escalation (bd-4qjl0q).
  See `Arbiter.ReviewGate.Resolution` for the record and why it exists.

  `record/1` is the single write path — the MCP `review_gate_resolve` tool and
  `POST /api/issues/:id/resolve` (`arb review resolve`) both call it — so the
  decision is one call, not a hand edit of the task body.
  """

  require Ash.Query
  require Logger

  alias Arbiter.ReviewGate.{Resolution, Round}
  alias Arbiter.Tasks.Issue

  @type error :: {:invalid, String.t()} | {:not_found, String.t()}

  @decision_names Map.new(Resolution.decisions(), &{Atom.to_string(&1), &1})
  @gate_names Map.new(Resolution.gates(), &{Atom.to_string(&1), &1})

  @doc """
  Record a resolution. `attrs` (atom or string keys):

    * `task_id` (required) — must name an existing task.
    * `decision` (required) — one of `Resolution.decisions/0`, as an atom or
      string (`accept-as-is` spelling accepted).
    * `reasoning` (required, non-blank).
    * `gate` — one of `Resolution.gates/0`; default `:review_gate`.
    * `actor` — default `"coordinator"`.
    * `round` / `fix_round_attempt` — the round this answers. For a
      `:review_gate` resolution that names neither, the task's most recent
      reviewer round is linked, so the override sits next to the argument it
      ends.

  Broadcasts a `gate_resolved` event on the task's workspace stream.
  """
  @spec record(map()) :: {:ok, Resolution.t()} | {:error, error()}
  def record(attrs) when is_map(attrs) do
    with {:ok, task_id} <- required_string(attrs, :task_id),
         {:ok, decision} <- parse_enum(fetch(attrs, :decision), @decision_names, "decision"),
         {:ok, gate} <- parse_gate(fetch(attrs, :gate)),
         {:ok, reasoning} <- required_string(attrs, :reasoning),
         {:ok, round} <- optional_int(attrs, :round, 1),
         {:ok, fix_round_attempt} <- optional_int(attrs, :fix_round_attempt, 0),
         {:ok, task} <- fetch_task(task_id) do
      {round, fix_round_attempt} = link_round(gate, task.id, round, fix_round_attempt)

      Resolution
      |> Ash.Changeset.for_create(:create, %{
        task_id: task.id,
        workspace_id: task.workspace_id,
        gate: gate,
        decision: decision,
        reasoning: reasoning,
        actor: actor(fetch(attrs, :actor)),
        round: round,
        fix_round_attempt: fix_round_attempt
      })
      |> Ash.create()
      |> case do
        {:ok, resolution} ->
          broadcast(resolution)
          {:ok, resolution}

        {:error, err} ->
          {:error, {:invalid, Exception.message(err)}}
      end
    end
  end

  @doc """
  Emit a `gate_cap_hit` event: `gate` escalated `task_id` because its round /
  send-back budget ran out after `rounds` of `cap`. Counting these is what lets
  the cap be tuned by evidence — pair them with `gate_resolved` events to see
  what the coordinator decided after each one.

  Best-effort and never raises: it runs on a gate's terminal path. A nil
  workspace is a no-op (the events stream is workspace-scoped).
  """
  @spec cap_hit(%{
          workspace_id: String.t() | nil,
          task_id: String.t(),
          gate: atom(),
          rounds: non_neg_integer(),
          cap: non_neg_integer()
        }) :: :ok
  def cap_hit(%{workspace_id: ws_id, task_id: task_id, gate: gate, rounds: rounds, cap: cap})
      when is_binary(ws_id) do
    Arbiter.Events.broadcast(ws_id, "gate_cap_hit", %{
      task_id: task_id,
      gate: Atom.to_string(gate),
      rounds: rounds,
      cap: cap
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "gate_cap_hit event for task=#{task_id} not emitted: #{Exception.message(e)}"
      )

      :ok
  end

  def cap_hit(_), do: :ok

  @doc """
  The footer a gate's escalation mail ends with: the one call that records the
  coordinator's answer. If recording the decision is more work than just
  telling the implementer, it won't happen — so the mail hands over the command.
  """
  @spec escalation_footer(String.t(), atom()) :: String.t()
  def escalation_footer(task_id, gate) do
    gate_flag = if gate == :review_gate, do: "", else: " --gate #{gate}"

    """
    ---
    Record your decision once you have made it (bd-4qjl0q) — one of
    --accept-as-is / --amend / --send-back / --reject, with your reasoning:

        arb review resolve #{task_id}#{gate_flag} --amend "<why>"

    (MCP: `review_gate_resolve`.) It records the decision against the ticket;
    act on it with the usual tools.
    """
  end

  @doc "`body` followed by `escalation_footer/2` (just the footer for a non-binary body)."
  @spec append_footer(term(), String.t(), atom()) :: String.t()
  def append_footer(body, task_id, gate) when is_binary(body),
    do: body <> "\n\n" <> escalation_footer(task_id, gate)

  def append_footer(_body, task_id, gate), do: escalation_footer(task_id, gate)

  @doc "Every resolution recorded for `task_id`, oldest first."
  @spec list(String.t()) :: [Resolution.t()]
  def list(task_id) when is_binary(task_id) do
    Resolution
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  @doc """
  How a task's ReviewGate argument ended, from its rounds (sorted as
  `review_gate_rounds_list` sorts them) and its resolutions (oldest first):

    * `"resolved"` — a `:review_gate` resolution was recorded after the last
      round: the coordinator ended it, and `resolution` says how.
    * `"converged"` — the last reviewer round approved.
    * `"not_converged"` — the last reviewer round did not approve and nothing
      answers it yet (an escalation awaiting its resolution, or a loop still
      mid-flight).
    * `"none"` — no reviewer rounds and no resolution.
  """
  @spec outcome([Round.t()], [Resolution.t()]) :: String.t()
  def outcome(rounds, resolutions) do
    last_review = rounds |> Enum.filter(&(&1.role == :review)) |> List.last()
    last_row = List.last(rounds)

    last_resolution =
      resolutions |> Enum.filter(&(&1.gate == :review_gate)) |> List.last()

    cond do
      last_resolution && answers_latest?(last_resolution, last_row) -> "resolved"
      last_review && last_review.verdict == :approve -> "converged"
      last_review -> "not_converged"
      true -> "none"
    end
  end

  @doc "JSON-ready map of a resolution (MCP / REST)."
  @spec serialize(Resolution.t()) :: map()
  def serialize(%Resolution{} = r) do
    %{
      id: r.id,
      task_id: r.task_id,
      workspace_id: r.workspace_id,
      gate: r.gate,
      decision: r.decision,
      reasoning: r.reasoning,
      actor: r.actor,
      round: r.round,
      fix_round_attempt: r.fix_round_attempt,
      inserted_at: r.inserted_at && DateTime.to_iso8601(r.inserted_at)
    }
  end

  # ---- helpers --------------------------------------------------------------

  defp answers_latest?(_resolution, nil), do: true

  defp answers_latest?(resolution, last_row),
    do: DateTime.compare(resolution.inserted_at, last_row.inserted_at) != :lt

  defp link_round(:review_gate, task_id, nil, nil) do
    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review)
    |> Ash.Query.sort(fix_round_attempt: :desc, round: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [last] -> {last.round, last.fix_round_attempt}
      [] -> {nil, nil}
    end
  end

  defp link_round(_gate, _task_id, round, nil) when is_integer(round), do: {round, 0}
  defp link_round(_gate, _task_id, round, fix_round_attempt), do: {round, fix_round_attempt}

  defp fetch_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = task} -> {:ok, task}
      _ -> {:error, {:not_found, "no ticket found for #{task_id}"}}
    end
  end

  defp broadcast(%Resolution{workspace_id: ws_id} = r) when is_binary(ws_id) do
    Arbiter.Events.broadcast(ws_id, "gate_resolved", %{
      task_id: r.task_id,
      gate: Atom.to_string(r.gate),
      decision: Atom.to_string(r.decision),
      actor: r.actor,
      round: r.round,
      fix_round_attempt: r.fix_round_attempt,
      resolution_id: r.id
    })
  end

  defp broadcast(_resolution), do: :ok

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp required_string(attrs, key) do
    case fetch(attrs, key) do
      s when is_binary(s) ->
        if String.trim(s) == "",
          do: {:error, {:invalid, "`#{key}` must not be blank"}},
          else: {:ok, String.trim(s)}

      _ ->
        {:error, {:invalid, "`#{key}` is required"}}
    end
  end

  defp parse_gate(nil), do: {:ok, :review_gate}
  defp parse_gate(gate), do: parse_enum(gate, @gate_names, "gate")

  defp parse_enum(value, names, label) when is_atom(value) and not is_nil(value),
    do: parse_enum(Atom.to_string(value), names, label)

  defp parse_enum(value, names, label) when is_binary(value) do
    key = value |> String.trim() |> String.downcase() |> String.replace("-", "_")

    case Map.fetch(names, key) do
      {:ok, atom} -> {:ok, atom}
      :error -> invalid_enum(value, names, label)
    end
  end

  defp parse_enum(value, names, label), do: invalid_enum(value, names, label)

  defp invalid_enum(value, names, label) do
    {:error,
     {:invalid,
      "`#{label}` must be one of #{names |> Map.keys() |> Enum.sort() |> Enum.join(", ")}; " <>
        "got: #{inspect(value)}"}}
  end

  defp optional_int(attrs, key, min) do
    case fetch(attrs, key) do
      nil -> {:ok, nil}
      n when is_integer(n) and n >= min -> {:ok, n}
      _ -> {:error, {:invalid, "`#{key}` must be an integer >= #{min}"}}
    end
  end

  defp actor(a) when is_binary(a) do
    case String.trim(a) do
      "" -> actor(nil)
      trimmed -> trimmed
    end
  end

  # bd-6i7yzq: absent an explicit `actor`, the resolution is the caller's own —
  # the process's ambient `Arbiter.Actor` (the MCP tier, the CLI token, the
  # dashboard operator) — and only then the historical `"coordinator"` default.
  defp actor(_), do: Arbiter.Actor.resolve_label(nil) || "coordinator"
end
