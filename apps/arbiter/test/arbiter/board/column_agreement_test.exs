defmodule Arbiter.Board.ColumnAgreementTest do
  @moduledoc """
  bd-6zapbl acceptance 2: the board (`Snapshot.derive/1`), the epic mini-board
  (`Snapshot.classify_columns/3`) and the `/epics` rollup
  (`EpicRollup.children_with_status/2` and its counts) all read a ticket's
  column from `Lifecycle.view/2`, so they agree — one fixture per state ×
  {no worker, working author, succeeded author row, failed author row}.

  Acceptance 3 rides along: no combination vanishes from every column.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.{Dependency, EdgeGate, EpicRollup, Issue, Lifecycle, Workspace}

  @fixtures [:backlog, :queued, :blocked, :active, :merging, :verifying, :closed]
  @workers [:none, :working, :succeeded, :failed]

  # What the interim five-column board shows, spelled out from the ticket's
  # mapping table rather than read from the code under test.
  @expected %{
    backlog: %{none: :backlog, working: :running, succeeded: :backlog, failed: :backlog},
    queued: %{none: :ready, working: :running, succeeded: :ready, failed: :ready},
    blocked: %{none: :ready, working: :running, succeeded: :ready, failed: :ready},
    active: %{none: :waiting, working: :running, succeeded: :waiting, failed: :waiting},
    merging: %{none: :waiting, working: :waiting, succeeded: :waiting, failed: :waiting},
    verifying: %{none: :waiting, working: :waiting, succeeded: :waiting, failed: :waiting},
    closed: %{none: :closed, working: :closed, succeeded: :closed, failed: :closed}
  }

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "agree-#{System.unique_integer([:positive])}", prefix: "agr"})

    # Past the dispatch grace, so a workerless :active ticket reads as
    # orphaned the same way everywhere.
    {:ok, ws: ws, now: DateTime.add(DateTime.utc_now(), 300, :second)}
  end

  for variant <- @workers do
    @variant variant

    test "every state agrees across all three entry points — worker: #{variant}", %{
      ws: ws,
      now: now
    } do
      epic = create(ws, %{title: "epic", issue_type: :epic})
      blocker = ws |> create() |> transition!(:promote)
      tickets = Map.new(@fixtures, &{&1, fixture(ws, &1, blocker)})

      for {_key, ticket} <- tickets, do: edge!(epic, ticket, :parent_of)

      workers = for {_key, t} <- tickets, w <- List.wrap(worker(t.id, @variant)), do: w
      issues = Ash.read!(Issue) |> Enum.filter(&(&1.workspace_id == ws.id))
      deps = Ash.read!(Dependency)

      board =
        Snapshot.derive(%{
          issues: issues,
          workers: workers,
          blocked_by: EdgeGate.blockers(deps, issues),
          now: now,
          slots_total: 4
        })

      mini = Snapshot.classify_columns(Map.values(tickets), workers, now: now)

      rollup =
        epic
        |> EpicRollup.children_with_status(workers: workers, now: now)
        |> Map.new(&{&1.issue.id, &1.bucket})

      counts = EpicRollup.for_epic(epic, workers: workers, now: now, watchdog_live: nil).counts

      for {key, ticket} <- tickets do
        expected = @expected[key][@variant]
        on_board = board_columns(board, ticket.id)

        assert on_board == [expected],
               "#{key}/#{@variant}: board put it in #{inspect(on_board)}, expected #{expected}"

        assert mini[ticket.id] == expected, "#{key}/#{@variant}: classify_columns disagrees"
        assert rollup[ticket.id] == expected, "#{key}/#{@variant}: EpicRollup disagrees"

        blocked_by = Map.get(EdgeGate.blockers(deps, issues), ticket.id, [])

        assert Lifecycle.board_column(ticket, %{
                 runs: List.wrap(worker(ticket.id, @variant)),
                 blocked_by: blocked_by,
                 now: now
               }) == expected
      end

      expected_counts =
        @fixtures
        |> Enum.map(&@expected[&1][@variant])
        |> Enum.frequencies()

      for {bucket, n} <- counts, do: assert(n == Map.get(expected_counts, bucket, 0))
    end
  end

  # ---- board columns ------------------------------------------------------

  defp board_columns(board, id) do
    [
      backlog: board.backlog,
      ready: Enum.map(board.ready, & &1.card),
      running: board.running,
      waiting: board.waiting,
      closed: board.closed_today
    ]
    |> Enum.flat_map(fn {column, cards} ->
      List.duplicate(column, Enum.count(cards, &(&1.id == id)))
    end)
  end

  # ---- fixtures -----------------------------------------------------------

  defp fixture(ws, :backlog, _blocker), do: create(ws)
  defp fixture(ws, :queued, _blocker), do: ws |> create() |> transition!(:promote)

  defp fixture(ws, :blocked, blocker) do
    ticket = fixture(ws, :queued, blocker)
    edge!(ticket, blocker, :depends_on)
    ticket
  end

  defp fixture(ws, :active, b), do: ws |> fixture(:queued, b) |> transition!(:start)
  defp fixture(ws, :merging, b), do: ws |> fixture(:active, b) |> transition!(:open_pr)

  defp fixture(ws, :verifying, b),
    do: ws |> fixture(:active, b) |> transition!(:await_verification)

  defp fixture(ws, :closed, b), do: ws |> fixture(:active, b) |> transition!(:close)

  defp create(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- it works"}, attrs)
      )

    issue
  end

  defp transition!(issue, action) do
    {:ok, issue} = Ash.update(issue, %{}, action: action)
    issue
  end

  defp edge!(from, to, type) do
    {:ok, _} = Ash.create(Dependency, %{from_issue_id: from.id, to_issue_id: to.id, type: type})
  end

  defp worker(_task_id, :none), do: nil

  # A working run, or a finished one with the given outcome.
  defp worker(task_id, variant) do
    {state, outcome} = if variant == :working, do: {:working, nil}, else: {:finished, variant}

    %{
      task_id: task_id,
      state: state,
      outcome: outcome,
      waiting_on: nil,
      workspace_id: nil,
      current_step: :implement,
      started_at: DateTime.utc_now(),
      step_started_at: DateTime.utc_now(),
      mr_ref: nil,
      merger_url: nil,
      meta: %{}
    }
  end
end
