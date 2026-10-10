defmodule Arbiter.Tasks.ReadyHolds do
  @moduledoc """
  Why the scheduler is not dispatching each Ready card (bd-dtdeff), read from the
  board's own plan — the reason its card shows — so a card Autopilot is skipping
  reads the same on `arb prime`, `GET /api/issues/ready` and the MCP
  `ticket_ready` / `ticket_list` tools (P-13, D-T-16).

  Only cards the board holds appear. A failed board read yields none rather than
  failing the listing.
  """

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Workspace

  @scheduler_call_timeout_ms 2_000

  @doc """
  `%{ticket_id => reason}` for workspace `workspace_id`; `nil` is every
  workspace (ticket ids are globally unique, so the per-workspace maps never
  collide).
  """
  @spec for_workspace(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def for_workspace(nil) do
    Workspace |> Ash.read!() |> Enum.reduce(%{}, &Map.merge(&2, for_workspace(&1.id)))
  end

  def for_workspace(ws_id) when is_binary(ws_id) do
    [
      workspace_id: ws_id,
      paused: scheduler_idle?(),
      exclude_engagements?: true,
      idle_check: &idle_ids/1
    ]
    |> Snapshot.load()
    |> Map.get(:ready, [])
    |> Enum.filter(&(&1.state == :blocked))
    |> Map.new(&{&1.id, &1.reason})
  rescue
    _ -> %{}
  end

  # bd-3fbj83: orphaned tickets hold no slot.
  defp idle_ids(issues),
    do: Arbiter.Tasks.IdleTickets.ids(issues, queued_ids: Autopilot.deferred_resume_ids())

  # A scheduler that is not running, or does not answer, counts as paused — the
  # reading that under-promises.
  defp scheduler_idle? do
    not Autopilot.running?(Autopilot) or Autopilot.paused?(Autopilot, @scheduler_call_timeout_ms)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end
end
