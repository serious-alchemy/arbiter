defmodule Arbiter.Reports.CostTest do
  # async: false — the report reads the whole ledger (like the estimator).
  use Arbiter.DataCase, async: false

  alias Arbiter.Reports.Cost
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.{Estimate, Event}

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "cost-ws-#{System.unique_integer([:positive])}", prefix: "cw"})

    %{ws: ws}
  end

  defp closed_issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "cost subject", workspace_id: ws.id, issue_type: :feature}, attrs)
      )

    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
    closed
  end

  defp event!(ws, task_id, attrs) do
    base = %{
      task_id: task_id,
      source: :task,
      step: :work,
      workspace_id: ws.id,
      occurred_at: @now,
      provider: "claude",
      model: "opus"
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  defp d2_tasks!(ws, n) do
    for i <- 1..n do
      issue = closed_issue!(ws, %{difficulty: 2})
      event!(ws, issue.id, %{cost_usd: i * 1.0, occurred_at: DateTime.add(@now, -i, :day)})
      # Rework rows fold to the base ticket, whether or not base_task_id is set.
      event!(ws, issue.id <> "#review", %{cost_usd: 0.5})
      event!(ws, issue.id <> ":fixpass", %{cost_usd: 0.25, base_task_id: issue.id <> ":fixpass"})
      issue
    end
  end

  defp drain_queries(acc) do
    receive do
      {:q, q} -> drain_queries([q | acc])
    after
      0 -> acc
    end
  end

  defp d2_row(report), do: Enum.find(report.difficulties, &(&1.difficulty == 2))

  test "totals match a manual usage_events sum for the workspace", %{ws: ws} do
    d2_tasks!(ws, 12)
    event!(ws, "ext:abc", %{cost_usd: 99.0})

    report = Cost.load(%{"workspace" => ws.id}, now: @now)

    %{rows: [[manual]]} =
      Repo.query!(
        "SELECT SUM(cost_usd) FROM usage_events WHERE workspace_id = ?1 AND task_id NOT LIKE 'ext:%'",
        [ws.id]
      )

    assert_in_delta d2_row(report).cost_usd, manual, 0.001
    assert d2_row(report).tickets == 12
  end

  test "p25/median/p75/p90 equal the ticket estimate for the difficulty", %{ws: ws} do
    d2_tasks!(ws, 12)
    subject = closed_issue!(ws, %{difficulty: 2, issue_type: :bug})

    est = Estimate.for_issue(subject, now: @now, cached: false, workspace_id: ws.id)
    assert est.basis == "difficulty"

    row = d2_row(Cost.load(%{"workspace" => ws.id}, now: @now))
    assert {row.p25, row.median, row.p75, row.p90} == {est.p25, est.median, est.p75, est.p90}
    assert row.priced_tickets == est.n
  end

  test "null cost is never rendered as zero; unmetered providers keep tokens", %{ws: ws} do
    issue = closed_issue!(ws, %{difficulty: 3})

    event!(ws, issue.id, %{
      provider: "gemini",
      model: "g",
      cost_usd: nil,
      tokens_in: 100,
      tokens_out: 20
    })

    event!(ws, issue.id <> "#review", %{provider: "gemini", model: "g", cost_usd: nil})

    row =
      Enum.find(Cost.load(%{"workspace" => ws.id}, now: @now).difficulties, &(&1.difficulty == 3))

    assert row.cost_usd == nil
    assert row.median == nil
    [gem] = row.providers
    assert gem.metered? == false
    assert gem.cost_usd == nil
    assert gem.tokens == 120
    assert gem.unmetered_rows == 2
  end

  test "mixed providers are never summed into each other", %{ws: ws} do
    issue = closed_issue!(ws, %{difficulty: 1})
    event!(ws, issue.id, %{cost_usd: 2.0})
    event!(ws, issue.id <> "#review", %{provider: "codex", model: "c", cost_usd: nil})

    row =
      Enum.find(Cost.load(%{"workspace" => ws.id}, now: @now).difficulties, &(&1.difficulty == 1))

    claude = Enum.find(row.providers, &(&1.provider == "claude"))
    codex = Enum.find(row.providers, &(&1.provider == "codex"))
    assert claude.cost_usd == 2.0 and claude.metered?
    assert codex.cost_usd == nil and not codex.metered?
  end

  test "coordinator overhead is windowed and separate from ticket spend", %{ws: ws} do
    d2_tasks!(ws, 2)

    event!(ws, nil, %{source: :coordinator_session, cost_usd: 3.0})

    event!(ws, nil, %{
      source: :coordinator_session,
      cost_usd: 50.0,
      occurred_at: DateTime.add(@now, -90, :day)
    })

    o = Cost.load(%{"workspace" => ws.id}, now: @now).overhead
    assert o.cost_usd == 3.0
    assert o.share > 0 and o.share < 1
  end

  test "reads aggregates only: no raw, no per-event rows", %{ws: ws} do
    d2_tasks!(ws, 5)
    me = self()
    id = "cost-query-shape-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:arbiter, :repo, :query],
      fn _e, _m, meta, _ -> send(me, {:q, meta.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    Cost.load(%{"workspace" => ws.id}, now: @now)
    queries = drain_queries([])

    ledger = Enum.filter(queries, &String.contains?(&1, "usage_events"))
    assert length(ledger) == 2
    assert Enum.all?(ledger, &(&1 =~ "GROUP BY"))
    refute Enum.any?(queries, &(&1 =~ ~r/\braw\b/))
  end
end
