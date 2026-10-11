defmodule Arbiter.Loop.AnalysisDifficultyFeedTest do
  @moduledoc """
  bd-druqc1 (R12): the production path from `Analysis.analyze/1` (and the
  `difficulty_feed` request param) through `SubjectStats.sample/1` to a pending
  `:difficulty_override` row, against real seeded `worker_runs` / `issues`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.Analysis
  alias Arbiter.Loop.Analysis.Request
  alias Arbiter.Repo
  alias Arbiter.Tasks.Workspace

  @model "claude-haiku-4-5"

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "feed-ws", prefix: "fd"})
    seed_cell(ws.id, 5)
    %{ws: ws}
  end

  # Caller options come first: `Keyword.get/2` reads the first match, so a
  # caller's `:since` must precede the default one.
  defp analyze(ws, extra) do
    Analysis.analyze(
      extra ++
        [
          workspace_id: ws.id,
          propose?: true,
          record_cost?: false,
          since: DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
        ]
    )
  end

  defp overrides(ws), do: Loop.list_pending(workspace_id: ws.id, kind: :difficulty_override)

  test "feed on: a high raised-rate cell is queued as a pending :difficulty_override", %{ws: ws} do
    assert {:ok, _} = analyze(ws, difficulty_feed?: true)

    assert [row] = Enum.filter(overrides(ws), &(&1.payload["reason"] == "raised_rate"))
    assert row.state in [:proposed, :hypothesis]
    assert row.payload["n"] == 10
    refute Map.has_key?(row.payload, "task_id")
  end

  test "feed off (default): no raised-rate proposal is written", %{ws: ws} do
    assert {:ok, _} = analyze(ws, [])
    assert Enum.filter(overrides(ws), &(&1.payload["reason"] == "raised_rate")) == []
  end

  test "the caller's window bounds the feed's evidence", %{ws: ws} do
    future = DateTime.add(DateTime.utc_now(), 5 * 86_400, :second)

    assert {:ok, _} =
             analyze(ws,
               difficulty_feed?: true,
               since: future,
               until: DateTime.add(future, 1, :second)
             )

    assert Enum.filter(overrides(ws), &(&1.payload["reason"] == "raised_rate")) == []
  end

  describe "Request.build/2" do
    test "difficulty_feed is opt-in and absent by default" do
      assert {:ok, opts} = Request.build(%{})
      refute Keyword.has_key?(opts, :difficulty_feed?)
      assert {:ok, opts} = Request.build(%{"difficulty_feed" => true})
      assert opts[:difficulty_feed?] == true
      assert {:ok, opts} = Request.build(%{"difficulty_feed" => "false"})
      refute Keyword.has_key?(opts, :difficulty_feed?)
      assert {:error, _} = Request.build(%{"difficulty_feed" => "maybe"})
    end
  end

  # 10 closed tasks in one (claude, haiku, D2, feature) cell; `raised` of them
  # have an issue difficulty above the difficulty at dispatch.
  defp seed_cell(ws, raised) do
    now = DateTime.utc_now()
    started = DateTime.add(now, -2 * 86_400, :second)
    closed = DateTime.add(now, -86_400, :second)

    for i <- 1..10 do
      task_id = "feed-t#{i}"
      difficulty = if i <= raised, do: 3, else: 2

      Repo.query!(
        """
        INSERT INTO issues (id, workspace_id, title, issue_type, difficulty, priority,
                            tracker_type, state, created_at, updated_at)
        VALUES (?1, ?2, ?1, 'feature', ?3, 2, 'none', 'active', ?4, ?4)
        """,
        [task_id, ws, difficulty, iso(started)]
      )

      Repo.query!(
        """
        INSERT INTO worker_runs (id, task_id, base_task_id, workspace_id, repo, kind, role, model,
                                 provider, difficulty_at_dispatch, model_tier, state, outcome,
                                 started_at, inserted_at, updated_at)
        VALUES (?1, ?2, ?2, ?3, 'arbiter', 'implement', 'base', ?4, 'claude', 2, 'standard',
                'finished', 'succeeded', ?5, ?5, ?5)
        """,
        [Ecto.UUID.generate(), task_id, ws, @model, iso(started)]
      )

      Repo.query!(
        """
        UPDATE issues SET state = 'closed', close_reason = 'completed', closed_at = ?2,
                          updated_at = ?2 WHERE id = ?1
        """,
        [task_id, iso(closed)]
      )
    end
  end

  defp iso(%DateTime{} = dt),
    do: dt |> Map.put(:microsecond, {elem(dt.microsecond, 0), 6}) |> DateTime.to_iso8601()
end
