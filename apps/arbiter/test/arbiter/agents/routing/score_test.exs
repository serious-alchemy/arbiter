defmodule Arbiter.Agents.Routing.ScoreTest do
  @moduledoc """
  bd-adtnto (R5, design §2.1, §9): the scorer reorders survivors by
  `J(c) = price + w(priority) × E[T]`. Without a draw estimate or a time term
  its order is exactly `most_quota`'s headroom order (I2), and it never drops
  a candidate.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Agents.Routing.Score
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  defp win(h), do: %{headroom: h * 1.0, window: "5h", threshold: 0.5, used: 0.0, mode: :paced}

  defp entry(index, h, extra \\ %{}) do
    windows = if h, do: [win(h)], else: []

    Map.merge(
      %{index: index, windows: windows, headroom: if(h, do: win(h)), id: "a#{index}"},
      extra
    )
  end

  defp ids(entries), do: Enum.map(entries, & &1.id)

  # Today's `ProviderRouting.rank/1`, frozen as the oracle.
  defp most_quota(entries) do
    Enum.sort_by(entries, fn entry ->
      case entry.headroom do
        %{headroom: h} -> {0, -h, entry.index}
        nil -> {1, 0, entry.index}
      end
    end)
  end

  describe "rank/2" do
    test "lowest price first: the pool with the most headroom" do
      ranked = Score.rank([entry(0, 0.1), entry(1, 0.4), entry(2, 0.2)])
      assert ids(ranked) == ["a1", "a2", "a0"]
    end

    test "ties go to configured order" do
      ranked = Score.rank([entry(0, 0.2), entry(1, 0.2), entry(2, 0.2)])
      assert ids(ranked) == ["a0", "a1", "a2"]
    end

    test "an unknown reading ranks after every priced candidate" do
      ranked = Score.rank([entry(0, nil), entry(1, 0.05)])
      assert ids(ranked) == ["a1", "a0"]
    end

    test "a draw estimate prices the candidate's own expected use" do
      # Equal headroom, but a0 is expected to need three times the draw.
      ranked = Score.rank([entry(0, 0.2, %{draw: 3.0}), entry(1, 0.2, %{draw: 1.0})])
      assert ids(ranked) == ["a1", "a0"]
    end

    test "a cheaper draw can outweigh more headroom" do
      ranked = Score.rank([entry(0, 0.4, %{draw: 4.0}), entry(1, 0.2, %{draw: 1.0})])
      assert ids(ranked) == ["a1", "a0"]
    end

    test "the time term trades price for speed, scaled by the priority weight" do
      slow = entry(0, 0.4, %{time_h: 10.0})
      fast = entry(1, 0.2, %{time_h: 1.0})

      # weight 0: price only — the roomier pool wins.
      assert ids(Score.rank([slow, fast], weight: 0)) == ["a0", "a1"]
      # weight 0.5: 2.5 + 5.0 vs 5.0 + 0.5 — speed wins.
      assert ids(Score.rank([slow, fast], weight: 0.5)) == ["a1", "a0"]
    end

    test "annotates every entry with its score breakdown" do
      [ranked] = Score.rank([entry(0, 0.25, %{draw: 0.5, time_h: 2.0})], weight: 2.0)

      assert %{price: price, draw: 0.5, time_h: 2.0, time_term: time_term, score: score} =
               ranked.score

      assert_in_delta price, 2.0, 1.0e-9
      assert_in_delta time_term, 4.0, 1.0e-9
      assert_in_delta score, 6.0, 1.0e-9
      assert ranked.score.over_line?
    end

    test "flags a draw expected to cross the line" do
      [ranked] = Score.rank([entry(0, 0.1, %{draw: 0.2})])
      assert ranked.score.over_line?
    end

    test "an infeasible window ranks after priced candidates, by headroom, and is kept" do
      ranked = Score.rank([entry(0, -0.1), entry(1, 0.0), entry(2, 0.01)])
      assert ids(ranked) == ["a2", "a1", "a0"]
    end

    test "δ by side prices author on entry windows and review on reviewer windows" do
      # Example from design §3.5:
      # Author pool headroom 0.5 (author price = 4.17 / 0.5 = 8.34)
      # Reviewer pool headroom 0.25 (reviewer price = 2.83 / 0.25 = 11.32)
      # Total price = 8.34 + 11.32 = 19.66
      agy =
        entry(0, 0.5, %{
          sides: %{author: 4.17, review: 2.83},
          reviewer_windows: [win(0.25)],
          time_h: 9.1
        })

      [ranked] = Score.rank([agy], weight: 2.0)
      assert %{price: price, time_term: time_term, score: score, sides: sides} = ranked.score
      assert_in_delta price, 19.66, 1.0e-9
      assert_in_delta time_term, 18.2, 1.0e-9
      assert_in_delta score, 37.86, 1.0e-9
      assert sides == %{author: 4.17, review: 2.83}
    end

    test "δ by side without reviewer windows prices author runs only" do
      e = entry(0, 0.5, %{sides: %{author: 2.5, review: 1.5}})
      [ranked] = Score.rank([e])
      assert %{price: price, sides: sides} = ranked.score
      assert_in_delta price, 5.0, 1.0e-9
      assert sides == %{author: 2.5, review: 1.5}
    end

    test "a projected reviewer with no windows prices the author side only" do
      unknown = entry(0, 0.5, %{sides: %{author: 2.0, review: 1.0}, reviewer_windows: []})

      priced =
        entry(1, 0.25, %{sides: %{author: 2.0, review: 1.0}, reviewer_windows: [win(0.25)]})

      [first, second] = Score.rank([priced, unknown])

      # unknown: 2.0 / 0.5 = 4.0 (review unpriced); priced: 8.0 + 4.0 = 12.0
      assert first.id == "a0"
      assert_in_delta first.score.price, 4.0, 1.0e-9
      assert first.score.reviewer_price == nil
      assert first.score.reviewer_unpriced?
      assert first.score.sides == %{author: 2.0, review: 1.0}
      refute second.score.reviewer_unpriced?
    end

    test "reviewer pool price reorders candidates when author headrooms are equal" do
      # a0 and a1 have equal author headroom (0.5), but a0's projected reviewer has
      # more headroom (0.5 vs 0.1), so a0's reviewer price is lower.
      a0 = entry(0, 0.5, %{sides: %{author: 2.0, review: 1.0}, reviewer_windows: [win(0.5)]})
      a1 = entry(1, 0.5, %{sides: %{author: 2.0, review: 1.0}, reviewer_windows: [win(0.1)]})

      assert ids(Score.rank([a1, a0])) == ["a0", "a1"]
    end

    property "I2: with no draw estimate or time term, the order is most_quota's, exactly" do
      check all(
              hs <-
                StreamData.list_of(
                  StreamData.one_of([
                    StreamData.constant(nil),
                    StreamData.member_of([0.1, 0.2, 0.5, 0.0, -0.2]),
                    StreamData.float(min: -0.5, max: 1.0)
                  ]),
                  max_length: 8
                )
            ) do
        entries = hs |> Enum.with_index() |> Enum.map(fn {h, i} -> entry(i, h) end)
        assert ids(Score.rank(entries)) == ids(most_quota(entries))
      end
    end

    property "never drops or adds a candidate" do
      check all(
              hs <- StreamData.list_of(StreamData.float(min: 0.001, max: 1.0), max_length: 6),
              draws <- StreamData.list_of(StreamData.float(min: 0.01, max: 5.0), length: 6)
            ) do
        entries =
          hs
          |> Enum.with_index()
          |> Enum.map(fn {h, i} -> entry(i, h, %{draw: Enum.at(draws, i)}) end)

        assert Enum.sort(ids(Score.rank(entries))) == Enum.sort(ids(entries))
      end
    end
  end

  describe "config/1 and weight/2" do
    defp ws(scoring), do: %Workspace{id: "ws", config: %{"routing" => %{"scoring" => scoring}}}

    test "mode defaults to shadow and only \"enforce\" enforces" do
      assert Score.config(%Workspace{id: "ws", config: %{}}).mode == :shadow
      assert Score.config(ws(%{})).mode == :shadow
      assert Score.config(ws(%{"mode" => "enforce"})).mode == :enforce
      assert Score.config(ws(%{"mode" => "bogus"})).mode == :shadow
      assert Score.config(nil).mode == :shadow
    end

    test "time weights default to zero for every priority" do
      config = Score.config(ws(%{}))
      for p <- 0..4, do: assert(Score.weight(config, %Issue{priority: p}) == 0.0)
    end

    test "reads the weight by the ticket's own priority" do
      config = Score.config(ws(%{"time_weight" => %{"P0" => 10, "P1" => 2.5}}))

      assert Score.weight(config, %Issue{priority: 0, floor_priority: 2}) == 10.0
      assert Score.weight(config, %Issue{priority: 1}) == 2.5
      assert Score.weight(config, %Issue{priority: 2}) == 0.0
      assert Score.weight(config, nil) == 0.0
    end

    test "ignores a malformed weight" do
      config = Score.config(ws(%{"time_weight" => %{"P0" => "heavy", "P1" => -3}}))
      assert Score.weight(config, %Issue{priority: 0}) == 0.0
      assert Score.weight(config, %Issue{priority: 1}) == 0.0
    end
  end
end
