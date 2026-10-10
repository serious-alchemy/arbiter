defmodule Arbiter.Worker.ReviewPass do
  @moduledoc """
  The ticket-side record of a ReviewGate pass in flight (bd-2yt0d2 / #291): what
  lets a server restart bring the pass back.

  A gate is a process, and so is the reviewer or implementer it launched; both
  die with the node. What outlives it is the ticket, so every time the gate
  launches a pass it writes a `pass` marker into the ticket's
  `review_gate_state` (beside the round state `Arbiter.Worker` recorded and the
  `ci_wait` marker `Arbiter.Worker.ReviewCi` keeps), and clears it when the
  pass ends. A marker still on the ticket at boot is therefore a pass the stop
  cut off.

  The marker holds what a fresh gate needs to run the same round again on the
  same head — the phase (`reviewing` / `revising`), the round, the head it
  started on and the merge-base, plus the gate's memory of the rounds before it
  (the thread and the open findings, bounded) that `Arbiter.Worker.ReviewGate`
  would otherwise lose. `Arbiter.Worker.ReviewGate.rearm_pass/2` reads it back
  through `restore/1`; `Arbiter.Workers.Reconciler.reconcile_review_passes/1`
  decides which tickets get that.

  `current/2` is the believable view of the marker for the pure projections
  (`Arbiter.Tasks.Lifecycle.View`): one past its `expires_at` — the pass's own
  timeout plus slack — belongs to a gate that was killed with no `terminate/2`
  and is not evidence of anything.
  """

  alias Arbiter.Tasks.PullRequest

  require Logger

  # How long past its own timeout a marker stays believable. Same figure and
  # reason as `ReviewCi`'s: a killed gate never clears it.
  @slack_ms 5 * 60_000

  # Per thread entry. A transcript is already capped at 16 kB when it is
  # recorded; the marker rides on every board read of the ticket, so it is cut
  # further here. The entry that carries a round's findings is the one a
  # restarted fix round needs, and findings run well under this.
  @thread_body_cap 12_000

  @roles %{"reviewer" => :reviewer, "implementer" => :implementer, "system" => :system}
  @phases %{"reviewing" => :reviewing, "revising" => :revising}

  @type phase :: :reviewing | :revising

  @doc """
  Build the marker for the pass `state` (a gate's state) just launched.
  `timeout_ms` is the pass's own budget.
  """
  @spec marker(map(), phase(), String.t(), non_neg_integer(), DateTime.t()) :: map()
  def marker(state, phase, pass_id, timeout_ms, now \\ DateTime.utc_now()) do
    %{
      phase: phase,
      round: state.round,
      pass_id: pass_id,
      fix_round_attempt: Map.get(state, :fix_round_attempt, 0),
      head_sha: state.head_sha,
      base_sha: state.base_sha,
      thread: Enum.map(state.thread, &thread_entry/1),
      open_findings: Map.get(state, :open_findings, []),
      revise_touched_files: touched_list(Map.get(state, :revise_touched_files)),
      started_at: now,
      expires_at: DateTime.add(now, timeout_ms + @slack_ms, :millisecond)
    }
  end

  defp touched_list(%MapSet{} = files), do: files |> MapSet.to_list() |> Enum.sort()
  defp touched_list(_), do: nil

  defp thread_entry(%{body: body} = entry) do
    %{entry | body: body |> to_string() |> String.slice(0, @thread_body_cap)}
  end

  @doc "Write (or, with `nil`, clear) the ticket's `pass` marker. Best-effort."
  @spec put(String.t(), map() | nil) :: :ok
  def put(task_id, marker) when is_binary(task_id) do
    case PullRequest.record_review_gate(task_id, %{pass: marker}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("ReviewPass: write failed for #{task_id}: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.debug("ReviewPass: write raised for #{task_id}: #{Exception.message(e)}")
      :ok
  end

  @doc "The marker as stored (string keys), or `nil`. No expiry: see `current/2`."
  @spec stored(map() | nil) :: map() | nil
  def stored(%{review_gate_state: %{"pass" => %{"phase" => phase} = pass}})
      when is_map_key(@phases, phase),
      do: pass

  def stored(_ticket), do: nil

  @doc """
  The ticket's `pass` marker if it is still believable at `now`, else `nil`.
  Reads only the ticket's own `review_gate_state`.
  """
  @spec current(map() | nil, DateTime.t()) :: map() | nil
  def current(ticket, now \\ DateTime.utc_now()) do
    with %{} = pass <- stored(ticket),
         {:ok, expires, _} <- DateTime.from_iso8601(to_string(Map.get(pass, "expires_at"))),
         :lt <- DateTime.compare(now, expires) do
      pass
    else
      _ -> nil
    end
  end

  @doc """
  Read a stored marker back into the shape the gate runs on: atom phase, the
  thread with its role atoms, the open findings with theirs.
  """
  @spec restore(map()) :: %{
          phase: phase(),
          round: pos_integer(),
          fix_round_attempt: non_neg_integer(),
          head_sha: String.t() | nil,
          base_sha: String.t() | nil,
          thread: [map()],
          open_findings: [map()],
          revise_touched_files: MapSet.t(String.t()) | nil,
          held: boolean()
        }
  def restore(%{"phase" => phase} = pass) do
    _ = Code.ensure_loaded(Arbiter.Worker.ReviewFindings)

    %{
      phase: Map.fetch!(@phases, phase),
      round: positive(pass["round"], 1),
      fix_round_attempt: non_negative(pass["fix_round_attempt"]),
      head_sha: string(pass["head_sha"]),
      base_sha: string(pass["base_sha"]),
      thread: pass |> Map.get("thread") |> List.wrap() |> Enum.map(&restore_thread_entry/1),
      open_findings:
        pass |> Map.get("open_findings") |> List.wrap() |> Enum.map(&restore_finding/1),
      revise_touched_files: touched(pass["revise_touched_files"]),
      # bd-3fbj83: a fix round the gate was holding for capacity; no run was cut off.
      held: pass["held"] == true
    }
  end

  defp restore_thread_entry(entry) do
    %{
      round: positive(entry["round"], 1),
      role: Map.get(@roles, entry["role"], :system),
      subject: to_string(entry["subject"]),
      body: to_string(entry["body"])
    }
  end

  defp restore_finding(finding) do
    %{
      id: to_string(finding["id"]),
      round: positive(finding["round"], 1),
      severity: severity(finding["severity"]),
      files: finding |> Map.get("files") |> List.wrap() |> Enum.map(&to_string/1),
      text: to_string(finding["text"])
    }
  end

  # An unknown severity fails closed at Medium (`ReviewFindings.rank/1`).
  defp severity(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :unknown
  end

  defp severity(_), do: :unknown

  defp touched(files) when is_list(files), do: MapSet.new(files, &to_string/1)
  defp touched(_), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_, default), do: default

  defp non_negative(n) when is_integer(n) and n >= 0, do: n
  defp non_negative(_), do: 0
end
