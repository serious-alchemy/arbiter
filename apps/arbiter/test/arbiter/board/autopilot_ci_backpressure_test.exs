defmodule Arbiter.Board.AutopilotCiBackpressureTest do
  @moduledoc """
  #1126, end to end through the Autopilot: while a repo's forge CI queue is over
  `worker.repos.<repo>.ci_backpressure`, a tick starts no NEW implement run for
  that repo, and starts the next repo's card instead. P0 is exempt, and the hold
  lifts by itself when the queue drains. The forge is a stub (`:poller`); the board
  is the real `Arbiter.Board.Snapshot`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.CiBackpressure.Cache
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-10-29 12:00:00Z]

  setup do
    Cache.reset()
    n = System.unique_integer([:positive])

    ws =
      Ash.create!(Workspace, %{
        name: "apcb-#{n}",
        prefix: "apcb#{n}",
        config: %{
          "worker" => %{
            "repos" => %{"vstim" => %{"ci_backpressure" => %{"max_pending" => 4}}}
          }
        }
      })

    {:ok, forge} = Agent.start_link(fn -> 8 end)
    %{ws: ws, forge: forge}
  end

  defp issue(id, ws, extra) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 1,
        issue_type: :feature,
        workspace_id: ws.id,
        repo: "vstim",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      extra
    )
  end

  defp start_autopilot(ws, forge, issues) do
    test = self()

    # `interval_ms: 0` re-polls on every board read, so a drained queue is seen at once.
    poller = fn _ws, _repo ->
      {:ok, %{pending: Agent.get(forge, & &1), oldest_at: DateTime.add(@now, -600, :second)}}
    end

    snapshot = fn opts ->
      opts
      |> Keyword.merge(
        workspace_id: ws.id,
        issues: issues,
        workers: [],
        slots_total: 3,
        quota: :ok,
        now: @now,
        ci_backpressure: [poller: poller, async: false, now: @now, interval_ms: 0]
      )
      |> Snapshot.load()
    end

    # Linked, as `autopilot_integration_test.exs` does: the pass reads the database, so
    # the sandbox must outlive it (a supervised stop would kill it mid-checkout).
    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        interval_ms: :never,
        topics: [],
        paused: false,
        follow_up: false,
        registry_settled?: fn -> true end,
        snapshot: snapshot,
        dispatch: fn id ->
          send(test, {:dispatched, id})
          {:ok, %{task_id: id}}
        end
      )

    pid
  end

  test "a saturated repo's Ready ticket is held and the next repo's card goes", ctx do
    issues = [
      issue("t-vstim", ctx.ws, %{priority: 1}),
      issue("t-other", ctx.ws, %{repo: "other", priority: 2})
    ]

    pid = start_autopilot(ctx.ws, ctx.forge, issues)

    assert {:ok, "t-other"} = Autopilot.tick(pid)
    assert_receive {:dispatched, "t-other"}
    refute_receive {:dispatched, "t-vstim"}, 50
  end

  test "with only the saturated repo's ticket, nothing is dispatched", ctx do
    pid = start_autopilot(ctx.ws, ctx.forge, [issue("t-vstim", ctx.ws, %{})])

    assert {:idle, _} = Autopilot.tick(pid) |> idle()
    refute_receive {:dispatched, _}, 50
  end

  test "P0 is exempt", ctx do
    pid = start_autopilot(ctx.ws, ctx.forge, [issue("t-p0", ctx.ws, %{priority: 0})])

    assert {:ok, "t-p0"} = Autopilot.tick(pid)
  end

  test "the hold lifts by itself when the queue drains", ctx do
    pid = start_autopilot(ctx.ws, ctx.forge, [issue("t-vstim", ctx.ws, %{})])

    assert {:idle, _} = Autopilot.tick(pid) |> idle()

    Agent.update(ctx.forge, fn _ -> 1 end)
    assert {:ok, "t-vstim"} = Autopilot.tick(pid)
  end

  # `tick/1` answers `:idle` (or `{:idle, detail}`) when nothing was promoted.
  defp idle(:idle), do: {:idle, nil}
  defp idle({:idle, _} = result), do: result
  defp idle(other), do: other
end
