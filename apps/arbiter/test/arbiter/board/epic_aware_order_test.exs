defmodule Arbiter.Board.EpicAwareOrderTest do
  @moduledoc """
  ES3 (bd-73uipb): the §4 order key through `Arbiter.Board.Snapshot.derive/1`,
  with `docs/design/epic-aware-scheduling.md` §5's worked examples as fixtures.

  The fixture is the design's real Ready queue: 18 unblocked cards, 3 slots.
  Ranks run in "today's" order (§5.1's left column), so today's order is
  `{priority, rank}`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.QueueOrder
  alias Arbiter.Board.Snapshot

  @now ~U[2026-10-02 12:00:00Z]
  @earlier ~U[2026-10-02 09:00:00Z]

  # {id, own priority, epic or nil} in today's `{priority, rank}` order.
  @ready [
    {"bd-4h5ikn", 1, "reports"},
    {"bd-89z02x", 2, "codex"},
    {"bd-agsn2b", 2, "codex"},
    {"bd-avgph4", 2, nil},
    {"bd-d89n5f", 2, "codex"},
    {"bd-dnut1o", 2, "codex"},
    {"bd-yoiv39", 2, "codex"},
    {"bd-7o4h44", 2, "reports"},
    {"bd-836iuz", 2, "reports"},
    {"bd-cl2rtd", 2, "reports"},
    {"bd-tbimna", 2, "reports"},
    {"bd-7nbwix", 2, nil},
    {"bd-jk49nc", 2, "guardrails"},
    {"bd-9q25ck", 3, "codex"},
    {"bd-48prlb", 3, nil},
    {"bd-59x0gb", 3, "reports"},
    {"bd-2xc0aa", 3, nil},
    {"bd-5kt9sk", 4, "reports"}
  ]

  @today ~w(bd-4h5ikn bd-89z02x bd-agsn2b bd-avgph4 bd-d89n5f bd-dnut1o bd-yoiv39 bd-7o4h44
            bd-836iuz bd-cl2rtd bd-tbimna bd-7nbwix bd-jk49nc bd-9q25ck bd-48prlb bd-59x0gb
            bd-2xc0aa bd-5kt9sk)

  # §5.1's right column.
  @finish_first ~w(bd-4h5ikn bd-7o4h44 bd-836iuz bd-cl2rtd bd-tbimna bd-89z02x bd-agsn2b
                   bd-d89n5f bd-dnut1o bd-yoiv39 bd-jk49nc bd-avgph4 bd-7nbwix bd-59x0gb
                   bd-9q25ck bd-48prlb bd-2xc0aa bd-5kt9sk)

  @epics %{"reports" => "bd-ibiwci", "codex" => "bd-de2g19", "guardrails" => "bd-guard1"}

  defp issue(id, attrs) do
    Map.merge(
      %{
        id: id,
        title: id,
        state: :queued,
        priority: 2,
        rank: 1024,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        created_at: @earlier,
        updated_at: @earlier,
        closed_at: nil,
        close_reason: nil,
        floor_priority: nil
      },
      Map.new(attrs)
    )
  end

  defp epic(id, floor), do: issue(id, issue_type: :epic, state: :queued, floor_priority: floor)

  # The design board: epics carry the open leaves §5.1 counts (Reports 8, Codex 18,
  # Guardrails 18) as Ready cards plus Backlog leaves, and one leaf closed
  # `completed` each so the epic counts as in progress.
  defp board(floors \\ %{}) do
    ready =
      @ready
      |> Enum.with_index(1)
      |> Enum.map(fn {{id, p, _epic}, i} -> issue(id, priority: p, rank: i * 1024) end)

    ready_edges = for {id, _p, epic} <- @ready, epic, do: {@epics[epic], id}

    tails =
      for {epic, ready_open, open} <- [{"reports", 7, 8}, {"codex", 6, 18}, {"guardrails", 1, 18}],
          reduce: {[], []} do
        {issues, edges} ->
          id = @epics[epic]
          filler = for n <- 1..(open - ready_open), do: "#{id}-open#{n}"
          done = "#{id}-done"

          {issues ++
             [issue(done, state: :closed, close_reason: :completed, closed_at: @earlier)] ++
             Enum.map(filler, &issue(&1, state: :backlog, priority: 3)),
           edges ++ Enum.map([done | filler], &{id, &1})}
      end

    {tail_issues, tail_edges} = tails

    epics = Enum.map(@epics, fn {key, id} -> epic(id, Map.get(floors, key)) end)

    %{issues: epics ++ ready ++ tail_issues, parent_of: ready_edges ++ tail_edges}
  end

  defp derive(board, extra \\ []) do
    Snapshot.derive(
      Map.merge(
        %{
          issues: board.issues,
          parent_of: board.parent_of,
          workers: [],
          blocked_by: %{},
          now: @now,
          slots_total: 3,
          quota: :ok
        },
        Map.new(extra)
      )
    )
  end

  defp ready_ids(snapshot), do: Enum.map(snapshot.ready, & &1.id)
  defp card(snapshot, id), do: Enum.find(snapshot.ready, &(&1.id == id)).card

  defp finish_first(extra \\ []),
    do: [scheduling: %{finish_first: true}] ++ extra

  describe "with no floors and finish-first off" do
    test "the Ready queue sorts exactly as {priority, rank, created_at} does today" do
      snapshot = derive(board())
      assert ready_ids(snapshot) == @today
    end

    test "every card carries the order fields at their neutral values" do
      snapshot = derive(board())

      for %{card: card} <- snapshot.ready do
        assert card.effective_priority == card.priority
        assert card.priority_via == nil
        assert card.priority_lift == nil
        assert card.finish_class == 0
        assert card.open_leaves == 0
      end
    end

    test "the kill switch makes floors inert, and so does clearing the settings" do
      floors = %{"reports" => 1, "codex" => 1}

      assert ready_ids(derive(board(floors), scheduling: %{epic_floors_enabled: false})) ==
               @today

      assert ready_ids(derive(board(floors), scheduling: %{epic_floors_enabled: true})) !=
               @today
    end
  end

  describe "§5.1 finish-first on, no floors" do
    test "Reports goes ahead of Codex parity; the parentless P2 bug drops behind both" do
      snapshot = derive(board(), finish_first())

      assert ready_ids(snapshot) == @finish_first
    end

    test "class 1 cards carry their epic's open leaves; the rest are class 2" do
      snapshot = derive(board(), finish_first())

      assert %{finish_class: 1, open_leaves: 8} = card(snapshot, "bd-7o4h44")
      assert %{finish_class: 1, open_leaves: 18} = card(snapshot, "bd-89z02x")
      assert %{finish_class: 1, open_leaves: 18} = card(snapshot, "bd-jk49nc")
      assert %{finish_class: 2, open_leaves: 0} = card(snapshot, "bd-avgph4")
    end

    test "a parentless card that waited more than 24h escapes the tiebreak and sorts 2nd" do
      aged = %{"bd-avgph4" => DateTime.add(@now, -25 * 3600)}
      snapshot = derive(board(), finish_first(ready_since: aged))

      assert Enum.take(ready_ids(snapshot), 2) == ["bd-4h5ikn", "bd-avgph4"]
      assert %{finish_class: 0} = card(snapshot, "bd-avgph4")
    end

    test "a card ready for less than the threshold is not aged; the threshold is a setting" do
      since = %{"bd-avgph4" => DateTime.add(@now, -5 * 3600)}

      refute "bd-avgph4" ==
               Enum.at(ready_ids(derive(board(), finish_first(ready_since: since))), 1)

      snapshot =
        derive(
          board(),
          scheduling: %{finish_first: true, finish_first_max_wait_hours: 4},
          ready_since: since
        )

      assert Enum.at(ready_ids(snapshot), 1) == "bd-avgph4"
    end
  end

  describe "§5.2 Reports floored at P1" do
    test "the P1 band is bd-4h5ikn then the lifted Reports children by own priority" do
      snapshot = derive(board(%{"reports" => 1}), finish_first())

      assert Enum.take(ready_ids(snapshot), 7) ==
               ~w(bd-4h5ikn bd-7o4h44 bd-836iuz bd-cl2rtd bd-tbimna bd-59x0gb bd-5kt9sk)

      # Then P2 continues as in §5.1 from bd-89z02x.
      assert Enum.at(ready_ids(snapshot), 7) == "bd-89z02x"
    end

    test "a lifted card names its epic and its own priority" do
      snapshot = derive(board(%{"reports" => 1}), finish_first())

      assert %{
               priority: 3,
               effective_priority: 1,
               priority_via: "bd-ibiwci",
               priority_lift: :applied
             } = card(snapshot, "bd-59x0gb")

      assert %{effective_priority: 1, priority_via: nil, priority_lift: nil} =
               card(snapshot, "bd-4h5ikn")
    end

    test "own priority orders the lifted children even with finish-first off" do
      snapshot = derive(board(%{"reports" => 1}))

      assert Enum.take(ready_ids(snapshot), 7) ==
               ~w(bd-4h5ikn bd-7o4h44 bd-836iuz bd-cl2rtd bd-tbimna bd-59x0gb bd-5kt9sk)
    end

    test "the lift cap: two lifted tickets in flight send the rest back to their own bands" do
      b = board(%{"reports" => 1})

      running = ~w(bd-7o4h44 bd-836iuz)

      issues =
        Enum.map(b.issues, fn i ->
          if i.id in running, do: %{i | state: :active}, else: i
        end)

      snapshot = derive(%{b | issues: issues}, finish_first())
      ids = Enum.reject(ready_ids(snapshot), &(&1 in running))

      # bd-4h5ikn is own P1; bd-cl2rtd and bd-tbimna fall to P2, where
      # finish-first still puts them first; bd-59x0gb to P3, bd-5kt9sk to P4.
      assert Enum.take(ids, 3) == ~w(bd-4h5ikn bd-cl2rtd bd-tbimna)
      assert List.last(ids) == "bd-5kt9sk"

      assert %{
               effective_priority: 2,
               priority: 2,
               priority_via: "bd-ibiwci",
               priority_lift: :capped
             } = card(snapshot, "bd-cl2rtd")

      assert %{effective_priority: 4, priority_lift: :capped} = card(snapshot, "bd-5kt9sk")
    end

    test "one lifted ticket in flight is under the cap of 2: lifts still apply" do
      b = board(%{"reports" => 1})

      issues =
        Enum.map(b.issues, fn i -> if i.id == "bd-7o4h44", do: %{i | state: :active}, else: i end)

      snapshot = derive(%{b | issues: issues})
      assert %{priority_lift: :applied} = card(snapshot, "bd-836iuz")
    end

    test "scheduling_max_lifted_in_flight overrides the derived cap" do
      b = board(%{"reports" => 1})

      issues =
        Enum.map(b.issues, fn i -> if i.id == "bd-7o4h44", do: %{i | state: :active}, else: i end)

      snapshot = derive(%{b | issues: issues}, scheduling: %{max_lifted_in_flight: 1})
      assert %{priority_lift: :capped} = card(snapshot, "bd-836iuz")
    end

    test "an own-P1 ticket in flight is not lifted, so it does not use the cap" do
      b = board(%{"reports" => 1})

      issues =
        Enum.map(b.issues, fn i -> if i.id == "bd-4h5ikn", do: %{i | state: :active}, else: i end)

      assert %{priority_lift: :applied} = card(derive(%{b | issues: issues}), "bd-836iuz")
    end
  end

  describe "§5.3 Codex parity floored at P1 as well" do
    test "the P1 band is the Reports cards then the Codex cards; P2 shrinks to three" do
      snapshot = derive(board(%{"reports" => 1, "codex" => 1}), finish_first())

      assert Enum.take(ready_ids(snapshot), 13) ==
               ~w(bd-4h5ikn bd-7o4h44 bd-836iuz bd-cl2rtd bd-tbimna bd-59x0gb bd-5kt9sk
                  bd-89z02x bd-agsn2b bd-d89n5f bd-dnut1o bd-yoiv39 bd-9q25ck)

      assert Enum.slice(ready_ids(snapshot), 13, 3) == ~w(bd-jk49nc bd-avgph4 bd-7nbwix)
    end

    test "the lift cap is shared: two floored epics still leave one slot for unlifted work" do
      b = board(%{"reports" => 1, "codex" => 1})
      running = ~w(bd-7o4h44 bd-89z02x)

      issues =
        Enum.map(b.issues, fn i -> if i.id in running, do: %{i | state: :active}, else: i end)

      snapshot = derive(%{b | issues: issues}, finish_first())
      assert %{priority_lift: :capped, priority_via: "bd-de2g19"} = card(snapshot, "bd-agsn2b")
      assert %{priority_lift: :capped, priority_via: "bd-ibiwci"} = card(snapshot, "bd-836iuz")
    end
  end

  describe "§5.4 Login relay nested under bd-9dr65f" do
    # bd-9dr65f (parent) > bd-dqvv90 (Login relay, 4 open leaves in Backlog).
    defp login_board(parent_floor, sub_floor) do
      leaves = for n <- 1..4, do: issue("bd-login#{n}", state: :backlog, priority: 2, rank: n)
      other = issue("bd-other", state: :backlog, priority: 1, rank: 1)

      %{
        issues: [epic("bd-9dr65f", parent_floor), epic("bd-dqvv90", sub_floor), other] ++ leaves,
        parent_of: [{"bd-9dr65f", "bd-dqvv90"} | for(l <- leaves, do: {"bd-dqvv90", l.id})]
      }
    end

    test "a floor on the grandparent lifts the Backlog column and names the grandparent" do
      snapshot = derive(login_board(1, nil))

      assert Enum.map(snapshot.backlog, & &1.id) ==
               ~w(bd-other bd-login1 bd-login2 bd-login3 bd-login4)

      for id <- ~w(bd-login1 bd-login4) do
        assert %{effective_priority: 1, priority_via: "bd-9dr65f", priority_lift: :applied} =
                 Enum.find(snapshot.backlog, &(&1.id == id))
      end
    end

    test "a P2 floor on the sub-epic as well changes nothing: the strictest wins" do
      snapshot = derive(login_board(1, 2))

      assert %{effective_priority: 1, priority_via: "bd-9dr65f"} =
               Enum.find(snapshot.backlog, &(&1.id == "bd-login3"))
    end

    test "with no floor the Backlog keeps today's order" do
      snapshot = derive(login_board(nil, nil))

      assert Enum.map(snapshot.backlog, & &1.id) ==
               ~w(bd-other bd-login1 bd-login2 bd-login3 bd-login4)

      assert Enum.all?(snapshot.backlog, &(&1.priority_lift == nil))
    end
  end

  describe "Backlog and Blocked sort by the same key" do
    setup do
      leaves =
        for {id, p, rank} <- [{"b-lo", 4, 1}, {"b-mid", 3, 2}, {"b-hi", 2, 3}] do
          issue(id, state: :backlog, priority: p, rank: rank)
        end

      blocked =
        for {id, p, rank} <- [{"k-lo", 4, 1}, {"k-mid", 3, 2}, {"k-hi", 2, 3}] do
          issue(id, state: :queued, priority: p, rank: rank)
        end

      {:ok, leaves: leaves, blocked: blocked}
    end

    test "floored leaves rise in both columns; unfloored parentless cards keep their order",
         %{leaves: leaves, blocked: blocked} do
      free_b = issue("b-free", state: :backlog, priority: 3, rank: 0)
      free_k = issue("k-free", state: :queued, priority: 3, rank: 0)

      parent_of =
        [{"e", "b-lo"}, {"e", "b-mid"}, {"e", "k-lo"}, {"e", "k-mid"}]

      snapshot =
        Snapshot.derive(%{
          issues: [epic("e", 2), free_b, free_k] ++ leaves ++ blocked,
          parent_of: parent_of,
          blocked_by: Map.new(["k-lo", "k-mid", "k-hi", "k-free"], &{&1, ["bd-gate"]}),
          workers: [],
          now: @now,
          slots_total: 3,
          quota: :ok
        })

      # b-lo/b-mid are lifted to P2 (own 4 / 3); b-hi is own P2, unparented.
      # Inside P2: b-hi (rank 3, class 0), then the lifted by own priority.
      assert Enum.map(snapshot.backlog, & &1.id) == ~w(b-hi b-mid b-lo b-free)
      assert Enum.map(snapshot.blocked, & &1.id) == ~w(k-hi k-mid k-lo k-free)

      assert %{effective_priority: 2, priority_via: "e"} =
               Enum.find(snapshot.blocked, &(&1.id == "k-lo"))
    end
  end

  describe "QueueOrder" do
    test "settings/1 overlays only the known, non-nil keys" do
      assert QueueOrder.settings(nil) == QueueOrder.default_settings()

      assert %{finish_first: true, epic_floors_enabled: true, finish_first_max_wait_hours: 24} =
               QueueOrder.settings(%{finish_first: true, bogus: 1, epic_floors_enabled: nil})
    end

    test "the lift cap defaults to max(slots_total - 1, 1) and honours an override" do
      d = QueueOrder.default_settings()
      assert QueueOrder.lift_cap(d, 3) == 2
      assert QueueOrder.lift_cap(d, 1) == 1
      assert QueueOrder.lift_cap(d, 0) == 1
      assert QueueOrder.lift_cap(%{d | max_lifted_in_flight: 5}, 3) == 5
    end
  end
end
