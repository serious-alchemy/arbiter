defmodule Arbiter.Tasks.Lifecycle.History do
  @moduledoc """
  Replays one ticket's paper trail (`issues_versions`) into lifecycle
  transitions (bd-d8fi92; reports design v2, `docs/design/reports-design-v2.md`
  §3.2). Pure: no database, no clock. `Arbiter.Tasks.TicketTransitionBackfill`
  feeds it and writes what it returns to `ticket_transitions`.

  The paper trail spans three eras, told apart by the keys a version carries,
  not by the clock:

    * **A, legacy** — `status` only. The state is derived from a running copy
      of `status`, `refined`, `pr_ref` and `pending_merge` (the lifecycle
      migration's backfill rule):

      | `status`                | other inputs                                 | state        |
      |-------------------------|----------------------------------------------|--------------|
      | `open`                  | `refined` true                               | `:queued`    |
      | `open`                  | `refined` false / absent                     | `:backlog`   |
      | `in_progress`           | `pr_ref` non-blank or `pending_merge` set    | `:merging`   |
      | `in_progress`           | otherwise                                    | `:active`    |
      | `awaiting_verification` |                                              | `:verifying` |
      | `closed`                |                                              | `:closed`    |

    * **B, dual-write** — `status` and `state`; **C, lifecycle** — `state`
      only. `state` is authoritative.

  Precedence, per version in `at` order: a version carrying `state` sets it;
  else, while the ticket has not yet shown a `state` and the version is older
  than the install's state cutover, a change to a derivation input re-derives
  it; else nothing moves. A transition is emitted only when the state changes.

  ## The two per-install cutovers (opts)

    * `:refined_cutover` — when migration `20260824170000` added `refined`
      (and set it true on every row: "created *was* ready"). A ticket created
      before it carries no `refined` key in any version, so the replay seeds
      `refined = true` for it; without the seed every pre-cutover ticket would
      start in a fictional backlog. `nil` (an install with no such ticket)
      never seeds.
    * `:state_cutover` — when migration `20260927184052` added `state`. From
      then on `state` is the stored truth and only moves with a version that
      carries it, so a later version without `state` derives nothing (a
      `record_pr` on an `:active` ticket is not an `open_pr`). `nil` disables
      the guard.

  ## Naming

  A creation (the first row, from `nil`) is `create`. An era-B/C transition is
  named by its `(from, to)` pair exactly as the `ticket_transitions` trigger
  names a live one (`name/2`), so the legacy door `promote_to_ready` records
  `promote`. An era-A transition is `legacy:<version action>`
  (`legacy:update` when the paper trail stamped no distinct action).

  ## Diagnostics

  `unmapped` lists every `status` / `state` value outside the known sets
  (it moves nothing). `illegal` lists every era-B/C transition whose pair is
  not in the `Arbiter.Tasks.Lifecycle` table — still replayed, since the
  stored history is what happened. Era-A pairs are never illegal: the legacy
  model had no transition table.
  """

  alias Arbiter.Tasks.Lifecycle

  @type version :: %{action: String.t(), at: DateTime.t(), changes: map()}

  @type transition :: %{
          from_state: Lifecycle.state() | nil,
          to_state: Lifecycle.state(),
          transition: String.t(),
          close_reason: Lifecycle.close_reason() | nil,
          at: DateTime.t()
        }

  @type result :: %{
          transitions: [transition()],
          state: Lifecycle.state() | nil,
          unmapped: [%{at: DateTime.t(), key: String.t(), value: term()}],
          illegal: [transition()]
        }

  @states Map.new(Lifecycle.states(), &{Atom.to_string(&1), &1})
  @close_reasons Map.new(Lifecycle.close_reasons(), &{Atom.to_string(&1), &1})
  @inputs ~w(status refined pr_ref pending_merge)

  @doc """
  Replay `versions` (one ticket's, any order) into its transitions.

  Opts: `:created_at` (the ticket's; the creation row is stamped no later
  than it, so a ticket enters the history when it was created),
  `:refined_cutover`, `:state_cutover` (see the moduledoc).
  """
  @spec replay([version()], keyword()) :: result()
  def replay(versions, opts \\ []) do
    created_at = Keyword.get(opts, :created_at)
    state_cutover = Keyword.get(opts, :state_cutover)

    acc = %{
      inputs: %{"refined" => seed_refined?(created_at, Keyword.get(opts, :refined_cutover))},
      close_reason: nil,
      state: nil,
      shown_state?: false,
      transitions: [],
      unmapped: [],
      illegal: []
    }

    acc =
      versions
      |> Enum.sort_by(& &1.at, DateTime)
      |> Enum.reduce(acc, &step(&1, &2, state_cutover))

    %{
      transitions: acc.transitions |> Enum.reverse() |> stamp_creation(created_at),
      state: acc.state,
      unmapped: Enum.reverse(acc.unmapped),
      illegal: Enum.reverse(acc.illegal)
    }
  end

  @doc "Whether a ticket created at `created_at` predates the install's `refined` cutover."
  @spec seed_refined?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def seed_refined?(%DateTime{} = created_at, %DateTime{} = cutover),
    do: DateTime.compare(created_at, cutover) == :lt

  def seed_refined?(_created_at, _cutover), do: false

  @doc """
  The transition a `(from, to)` pair is, as the `ticket_transitions` trigger
  names it: `create` from `nil`, the lifecycle table's one transition for the
  pair, else `unnamed`.
  """
  @spec name(Lifecycle.state() | nil, Lifecycle.state()) :: String.t()
  def name(nil, _to), do: "create"

  def name(from, to) do
    Enum.find_value(Lifecycle.transitions(), "unnamed", fn transition ->
      if Lifecycle.rule(transition) |> match_rule?(from, to), do: Atom.to_string(transition)
    end)
  end

  defp match_rule?({sources, target}, from, to), do: target == to and from in sources

  # ---- the fold --------------------------------------------------------------

  defp step(%{changes: changes} = version, acc, state_cutover) do
    acc = track(acc, changes)

    case Map.fetch(changes, "state") do
      {:ok, value} ->
        state_step(acc, version, value)

      :error ->
        if derive?(acc, version, state_cutover),
          do: legacy_step(acc, version),
          else: acc
    end
  end

  # The running copy of every input, plus close_reason.
  defp track(acc, changes) do
    acc = %{acc | inputs: Map.merge(acc.inputs, Map.take(changes, @inputs))}

    case Map.fetch(changes, "close_reason") do
      {:ok, reason} -> %{acc | close_reason: Map.get(@close_reasons, reason)}
      :error -> acc
    end
  end

  defp derive?(acc, version, state_cutover) do
    not acc.shown_state? and
      Enum.any?(@inputs, &Map.has_key?(version.changes, &1)) and
      before?(version.at, state_cutover)
  end

  defp before?(_at, nil), do: true
  defp before?(at, cutover), do: DateTime.compare(at, cutover) == :lt

  defp state_step(acc, version, value) do
    acc = %{acc | shown_state?: true}

    case Map.fetch(@states, value) do
      {:ok, to} ->
        name = name(acc.state, to)
        emit(acc, version, to, name, acc.state != nil and name == "unnamed")

      :error ->
        unmapped(acc, version, "state", value)
    end
  end

  defp legacy_step(acc, version) do
    case derive(acc.inputs) do
      {:ok, to} ->
        name = if acc.state == nil, do: "create", else: "legacy:" <> legacy_action(version)
        emit(acc, version, to, name, false)

      {:unmapped, value} ->
        if Map.has_key?(version.changes, "status"),
          do: unmapped(acc, version, "status", value),
          else: acc
    end
  end

  defp legacy_action(%{action: action}) when is_binary(action) and action != "", do: action
  defp legacy_action(_version), do: "update"

  defp derive(%{"status" => "open"} = inputs),
    do: {:ok, if(inputs["refined"] == true, do: :queued, else: :backlog)}

  defp derive(%{"status" => "in_progress"} = inputs),
    do: {:ok, if(pr?(inputs), do: :merging, else: :active)}

  defp derive(%{"status" => "awaiting_verification"}), do: {:ok, :verifying}
  defp derive(%{"status" => "closed"}), do: {:ok, :closed}
  defp derive(inputs), do: {:unmapped, inputs["status"]}

  defp pr?(inputs), do: present?(inputs["pr_ref"]) or present?(inputs["pending_merge"])

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value) when is_list(value), do: value != []
  defp present?(_value), do: true

  defp emit(%{state: to} = acc, _version, to, _name, _illegal?), do: acc

  defp emit(acc, version, to, name, illegal?) do
    transition = %{
      from_state: acc.state,
      to_state: to,
      transition: name,
      close_reason: if(to == :closed, do: acc.close_reason || :completed),
      at: version.at
    }

    %{
      acc
      | state: to,
        transitions: [transition | acc.transitions],
        illegal: if(illegal?, do: [transition | acc.illegal], else: acc.illegal)
    }
  end

  defp unmapped(acc, version, key, value),
    do: %{acc | unmapped: [%{at: version.at, key: key, value: value} | acc.unmapped]}

  # A ticket enters the history when it was created: the paper trail's create
  # version lands a moment after the row it describes.
  defp stamp_creation([%{from_state: nil} = first | rest], %DateTime{} = created_at) do
    at = Enum.min([first.at, created_at], DateTime)
    [%{first | at: at} | rest]
  end

  defp stamp_creation(transitions, _created_at), do: transitions
end
