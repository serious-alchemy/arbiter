defmodule Arbiter.Tasks.EpicFloorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Tasks.EpicFloor

  defp issue(id, attrs \\ []) do
    Map.merge(
      %{
        id: id,
        priority: 3,
        issue_type: :task,
        state: :queued,
        close_reason: nil,
        floor_priority: nil
      },
      Map.new(attrs)
    )
  end

  defp epic(id, floor, attrs \\ []),
    do: issue(id, [issue_type: :epic, floor_priority: floor, priority: 2] ++ attrs)

  test "a floored epic lifts its children and names itself as via" do
    issues = [epic("e", 1), issue("a", priority: 4), issue("b", priority: 0)]
    r = EpicFloor.resolve(issues, [{"e", "a"}, {"e", "b"}])

    assert %{own: 4, effective: 1, via: "e", lifted?: true, nearest_epic: "e", open_leaves: 2} =
             r["a"]

    assert %{own: 0, effective: 0, via: nil, lifted?: false} = r["b"]
  end

  test "strictest floor wins through nested epics; nearest epic is the sub-epic" do
    issues = [epic("top", 2), epic("sub", 1), issue("leaf", priority: 4), issue("other")]
    edges = [{"top", "sub"}, {"sub", "leaf"}, {"top", "other"}]
    r = EpicFloor.resolve(issues, edges)

    assert %{effective: 1, via: "sub", nearest_epic: "sub", open_leaves: 1} = r["leaf"]
    assert %{effective: 2, via: "top", nearest_epic: "top", open_leaves: 2} = r["other"]
  end

  test "non-epic parents are walked through and carry no floor" do
    issues = [epic("e", 1), issue("mid", floor_priority: 1), issue("leaf", priority: 4)]
    r = EpicFloor.resolve(issues, [{"e", "mid"}, {"mid", "leaf"}])
    assert %{effective: 1, via: "e", nearest_epic: "e"} = r["leaf"]
  end

  test "open leaves and in-progress counts" do
    issues = [
      epic("e", nil),
      issue("a", state: :active),
      issue("b", state: :queued),
      issue("c", state: :closed, close_reason: :completed),
      issue("d", state: :closed, close_reason: :wont_do)
    ]

    r = EpicFloor.resolve(issues, for(c <- ~w(a b c d), do: {"e", c}))
    assert %{open_leaves: 2, in_progress: 2, lifted?: false} = r["a"]
  end

  test "several parents: fewest open leaves is the nearest epic" do
    issues = [epic("big", nil), epic("small", nil), issue("x"), issue("y"), issue("z")]
    edges = [{"big", "x"}, {"big", "y"}, {"big", "z"}, {"small", "x"}]
    assert %{nearest_epic: "small"} = EpicFloor.resolve(issues, edges)["x"]
  end

  test "depth cap of 8" do
    [_ | rest] = ids = for i <- 0..10, do: "n#{i}"
    issues = [epic("n0", 1) | for(id <- rest, do: issue(id, priority: 4))]
    edges = ids |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&List.to_tuple/1)
    r = EpicFloor.resolve(issues, edges)
    assert r["n8"].lifted?
    refute r["n9"].lifted?
  end

  test "edges to unknown ids are ignored" do
    assert %{"a" => %{effective: 3}} = EpicFloor.resolve([issue("a")], [{"ghost", "a"}])
  end

  defp gen_board do
    gen all(
          n <- integer(1..8),
          ids = for(i <- 1..n, do: "t#{i}"),
          types <- list_of(member_of([:task, :epic]), length: n),
          prios <- list_of(integer(0..4), length: n),
          floors <- list_of(member_of([nil, 1, 2, 3]), length: n),
          states <- list_of(member_of([:backlog, :queued, :active, :closed]), length: n),
          edges <- list_of({member_of(ids), member_of(ids)}, max_length: 14)
        ) do
      issues =
        for {{id, t}, {p, {f, s}}} <-
              Enum.zip(Enum.zip(ids, types), Enum.zip(prios, Enum.zip(floors, states))) do
          issue(id,
            issue_type: t,
            priority: p,
            floor_priority: f,
            state: s,
            close_reason: if(s == :closed, do: :completed)
          )
        end

      {issues, edges}
    end
  end

  property "effective is never less urgent than own; unlifted means equal" do
    check all({issues, edges} <- gen_board()) do
      for {_id, r} <- EpicFloor.resolve(issues, edges) do
        assert r.effective <= r.own
        assert r.lifted? == r.effective < r.own
        assert r.lifted? == (r.via != nil)
      end
    end
  end

  property "with no floors, effective == own" do
    check all({issues, edges} <- gen_board()) do
      issues = Enum.map(issues, &%{&1 | floor_priority: nil})

      for {_id, r} <- EpicFloor.resolve(issues, edges) do
        assert r.effective == r.own
        refute r.lifted?
      end
    end
  end

  property "result is independent of edge order" do
    check all({issues, edges} <- gen_board(), shuffled <- constant(edges) |> map(&Enum.shuffle/1)) do
      assert EpicFloor.resolve(issues, edges) == EpicFloor.resolve(issues, shuffled)
      assert EpicFloor.resolve(issues, edges) == EpicFloor.resolve(issues, Enum.reverse(edges))
    end
  end

  property "cycles and self-loops terminate" do
    check all({issues, edges} <- gen_board()) do
      ids = Enum.map(issues, & &1.id)
      cyc = Enum.zip(ids, tl(ids) ++ [hd(ids)]) ++ Enum.map(ids, &{&1, &1})
      assert map_size(EpicFloor.resolve(issues, edges ++ cyc)) == length(ids)
    end
  end
end
