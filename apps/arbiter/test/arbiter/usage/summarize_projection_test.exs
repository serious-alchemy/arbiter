defmodule Arbiter.Usage.SummarizeProjectionTest do
  # bd-5cevwg: `Usage.summarize/1` used to `Ash.read!` every `usage_events`
  # column — the `raw` JSON blob included — for every row in the window, and
  # group in Elixir. These tests pin the slim projection that replaced it:
  #
  #   * every `by:` mode returns exactly what the old full-row read returned
  #     (a verbatim copy of the old implementation lives below as the oracle),
  #   * `raw` is never selected except for `by: :session`,
  #   * `summarize_many/2` serves several groupings from one ledger read,
  #   * `:epic` still resolves parents when the window holds >1000 task ids.
  #
  # async: false — the query-capture helper attaches a global telemetry
  # handler, and Event creates invalidate the shared SpendCache ETS table.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  alias Arbiter.Usage.SummarizeOracle
  require Ash.Query

  @day1 ~U[2026-06-01 12:00:00.000000Z]
  @day2 ~U[2026-06-02 09:00:00.000000Z]
  @day3 ~U[2026-06-03 18:30:00.000000Z]

  defp event!(attrs) do
    base = %{repo: "arbiter", workspace_id: "ws-a", step: :work, occurred_at: @day1}
    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  # Collect the SQL of every `usage_events` query `fun` runs.
  defp usage_event_queries(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:arbiter, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata.source == "usage_events", do: send(parent, {:query, ref, metadata.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(ref)
    end

    Stream.repeatedly(fn ->
      receive do
        {:query, ^ref, sql} -> sql
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  # A fixture ledger that exercises every grouping's edge: ReviewGate
  # synthetic ids (`#review`, `#r2`, `#review#impl1`) that must fold to their
  # base task for `:epic`, a task with two parents, a parentless task, a task
  # id with no issue at all, a task-less pre-flight row, session rows with and
  # without the estimated-cost marker, nil costs/tokens/model/repo/provider.
  # Costs are exact binary fractions so summation order can't perturb them.
  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "usage-proj-ws", prefix: "up"})
    issue! = fn attrs -> Ash.create!(Issue, Map.put(attrs, :workspace_id, ws.id)) end

    epic1 = issue!.(%{title: "Epic one", issue_type: :epic})
    epic2 = issue!.(%{title: "Epic two", issue_type: :epic})
    t1 = issue!.(%{title: "Two parents"})
    t2 = issue!.(%{title: "One parent"})
    t3 = issue!.(%{title: "No parent"})

    for {from, to} <- [{epic1, t1}, {epic2, t1}, {epic1, t2}] do
      Ash.create!(Dependency, %{type: :parent_of, from_issue_id: from.id, to_issue_id: to.id})
    end

    # A non-parent edge must not be read as an epic link.
    Ash.create!(Dependency, %{type: :blocks, from_issue_id: t3.id, to_issue_id: t2.id})

    pa1 = Ecto.UUID.generate()
    pa2 = Ecto.UUID.generate()

    claude = %{provider: "claude", provider_account_id: pa1}

    event!(
      Map.merge(claude, %{
        task_id: t1.id,
        model: "claude-opus-4-7",
        cost_usd: 0.5,
        tokens_in: 100,
        tokens_out: 50,
        cache_creation_tokens: 3,
        cache_read_tokens: 9,
        duration_ms: 1_000,
        raw: %{"type" => "result", "total_cost_usd" => 0.5}
      })
    )

    event!(
      Map.merge(claude, %{
        task_id: t1.id <> "#review",
        step: :review,
        model: "claude-sonnet-4-6",
        cost_usd: 0.25,
        tokens_in: 10,
        tokens_out: 5,
        thinking_tokens: 2,
        duration_ms: 500,
        occurred_at: @day2
      })
    )

    event!(
      Map.merge(claude, %{
        task_id: t1.id <> "#review#impl1",
        step: :impl,
        model: "claude-sonnet-4-6",
        cost_usd: 0.125,
        tokens_in: 20,
        tokens_out: 10,
        occurred_at: @day2
      })
    )

    event!(%{
      task_id: t2.id,
      workspace_id: "ws-b",
      provider: "gemini",
      model: "gemini-3.8-flash-low",
      provider_account_id: pa2,
      cost_usd: nil,
      tokens_in: 7,
      tokens_out: 1,
      thinking_tokens: 11,
      occurred_at: @day2
    })

    event!(
      Map.merge(claude, %{
        task_id: t2.id <> "#r2",
        step: :review,
        model: "claude-opus-4-7",
        cost_usd: 1.0,
        tokens_in: 40,
        tokens_out: 4,
        occurred_at: @day3
      })
    )

    event!(%{
      task_id: t3.id,
      workspace_id: "ws-b",
      repo: nil,
      model: nil,
      provider: nil,
      cost_usd: 2.0,
      tokens_in: nil,
      tokens_out: nil,
      occurred_at: @day3
    })

    event!(Map.merge(claude, %{task_id: "bd-ghost", cost_usd: 0.0625, occurred_at: @day3}))

    event!(%{
      task_id: nil,
      source: :preflight,
      step: :other,
      workspace_id: nil,
      repo: nil,
      provider: "claude",
      provider_account_id: pa2,
      cost_usd: 0.03125,
      tokens_in: 0,
      tokens_out: 0,
      occurred_at: @day2
    })

    session = %{
      task_id: nil,
      step: :other,
      repo: nil,
      provider: "claude",
      model: "claude-opus-4-7"
    }

    event!(
      Map.merge(session, %{
        source: :coordinator_session,
        session_id: "sess-est",
        provider_account_id: pa1,
        cost_usd: 4.0,
        tokens_in: 400,
        tokens_out: 40,
        raw: %{"arb_usage_source" => %{"cost_source" => "estimated"}}
      })
    )

    event!(
      Map.merge(session, %{
        source: :coordinator_session,
        session_id: "sess-est",
        provider_account_id: pa1,
        cost_usd: 0.5,
        tokens_in: 50,
        tokens_out: 5,
        occurred_at: @day2,
        raw: %{"arb_usage_source" => %{"cost_source" => "cost_state"}}
      })
    )

    event!(
      Map.merge(session, %{
        source: :terminal_session,
        session_id: "sess-real",
        cost_usd: 8.0,
        tokens_in: 800,
        tokens_out: 80,
        occurred_at: @day3,
        raw: %{"arb_usage_source" => %{"cost_source" => "cost_state"}}
      })
    )

    event!(
      Map.merge(session, %{
        source: :terminal_session,
        session_id: "sess-odd",
        cost_usd: 0.75,
        occurred_at: @day3,
        raw: %{"arb_usage_source" => "estimated"}
      })
    )

    event!(
      Map.merge(session, %{source: :terminal_session, session_id: "sess-noraw", cost_usd: 0.375})
    )

    {:ok, epic1: epic1, epic2: epic2, t1: t1, t2: t2, t3: t3, pa1: pa1, pa2: pa2}
  end

  describe "summarize/1 matches the pre-bd-5cevwg full-row implementation" do
    test "for every grouping, with and without filters", %{pa1: pa1} do
      filter_sets = [
        [],
        [since: @day2],
        [since: @day2, until: @day2],
        [workspace_id: "ws-b"],
        [provider_account_id: pa1],
        [session_ids: ["sess-est", "sess-odd"]],
        [limit: 2]
      ]

      for by <- Usage.acceptable_groupings(), filters <- filter_sets do
        opts = [{:by, by} | filters]
        assert {:ok, expected} = SummarizeOracle.summarize(opts)
        assert Usage.summarize(opts) == {:ok, expected}, "mismatch for #{inspect(opts)}"
      end
    end

    test "epic rollup folds ReviewGate ids to the base task and counts multi-parent tasks in each",
         %{epic1: epic1, epic2: epic2} do
      {:ok, rollups} = Usage.summarize(by: :epic)
      by_group = Map.new(rollups, &{&1.group, &1})

      # epic1: t1 (0.5 + 0.25 + 0.125) + t2 (nil + 1.0)
      assert by_group[epic1.id].total_cost_usd == 1.875
      assert by_group[epic1.id].rows == 5
      # epic2: t1 only
      assert by_group[epic2.id].total_cost_usd == 0.875
      assert by_group[epic2.id].rows == 3
      # t3, bd-ghost, the pre-flight row and the four session rows
      assert by_group["(no_epic)"].rows == 8
    end

    test "task rollup keeps synthetic ids apart and drops task-less rows", %{t1: t1} do
      {:ok, rollups} = Usage.summarize(by: :task)
      groups = Enum.map(rollups, & &1.group)

      assert t1.id in groups
      assert (t1.id <> "#review") in groups
      assert (t1.id <> "#review#impl1") in groups
      refute nil in groups
      assert length(groups) == 7
    end

    test "session rollup still reads the estimated-cost marker" do
      {:ok, rollups} = Usage.summarize(by: :session)
      estimated = Map.new(rollups, &{&1.group, &1.estimated})

      assert estimated == %{
               "sess-est" => true,
               "sess-real" => false,
               "sess-odd" => false,
               "sess-noraw" => false
             }
    end
  end

  describe "the ledger read" do
    # `raw` may only appear as the argument of the SQL JSON functions that
    # compute the estimated-cost marker — never as a selected column, for any
    # grouping, `:session` included.
    test "never selects raw (or other unused columns) as a column, for any grouping" do
      for by <- Usage.valid_groupings() do
        queries = usage_event_queries(fn -> {:ok, _} = Usage.summarize(by: by) end)

        assert [sql] = queries, "#{by}: expected one usage_events read, got #{inspect(queries)}"
        refute sql =~ ~r/(?<!json_valid\(|json_extract\()u0\."raw"/, "#{by} selected raw: #{sql}"

        for unused <- ~w(cost_note exit_status worker_run_id inserted_at role) do
          refute sql =~ ~s("#{unused}"), "#{by} selected #{unused}: #{sql}"
        end
      end
    end

    test "zero_token_providers/1 does not select raw either" do
      assert [sql] = usage_event_queries(fn -> {:ok, _} = Usage.zero_token_providers() end)
      refute sql =~ ~s("raw")
    end
  end

  describe "summarize_many/2" do
    test "returns every requested grouping from a single ledger read" do
      bys = [:task, :model, :repo, :provider_account]
      opts = [since: @day2]

      queries =
        usage_event_queries(fn ->
          send(self(), {:result, Usage.summarize_many(bys, opts)})
        end)

      assert_received {:result, {:ok, many}}
      assert length(queries) == 1

      assert Map.keys(many) |> Enum.sort() == Enum.sort(bys)

      for by <- bys do
        assert {:ok, many[by]} == Usage.summarize([{:by, by} | opts])
      end
    end

    test "accepts deprecated aliases, keyed by the name the caller used" do
      {:ok, many} = Usage.summarize_many([:campaign, :account], [])

      assert {:ok, many.campaign} == Usage.summarize(by: :epic)
      assert {:ok, many.account} == Usage.summarize(by: :provider_account)
    end

    test "rejects an unknown grouping without reading" do
      queries =
        usage_event_queries(fn ->
          assert {:error, {:invalid_grouping, :nope}} = Usage.summarize_many([:task, :nope], [])
        end)

      assert queries == []
    end
  end

  describe "by: :epic over a window with more than 1000 task ids" do
    # AshSqlite expands `to_issue_id in ^ids` into one OR term per id, and
    # SQLite caps expression depth at 1000 — the old unchunked parent lookup
    # raised, was rescued to `%{}`, and put every row in `(no_epic)`. The live
    # ledger crossed 1000 distinct base task ids in 2026-09.
    test "still resolves parents instead of collapsing everything into (no_epic)",
         %{epic1: epic1} do
      filler =
        for i <- 1..1_050 do
          %{
            task_id: "bd-filler-#{i}",
            workspace_id: "ws-wide",
            step: :work,
            cost_usd: 0.0,
            occurred_at: @day1
          }
        end

      %Ash.BulkResult{status: :success} = Ash.bulk_create(filler, Event, :create)

      {:ok, rollups} = Usage.summarize(by: :epic)
      epic = Enum.find(rollups, &(&1.group == epic1.id))

      assert epic, "epic rollup collapsed: #{inspect(Enum.map(rollups, &{&1.group, &1.rows}))}"
      assert epic.total_cost_usd == 1.875
    end
  end
end
