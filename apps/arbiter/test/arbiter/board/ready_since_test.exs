defmodule Arbiter.Board.ReadySinceTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.ReadySince

  @t0 ~U[2026-10-01 10:00:00Z]

  test "a ticket with no blockers is Ready since it last entered :queued" do
    assert ReadySince.compute(%{"a" => @t0}, [], []) == %{"a" => @t0}
  end

  test "the latest satisfied blocker pushes Ready-since later than the queued transition" do
    queued = %{"a" => @t0}
    early = %{id: "b1", closed_at: DateTime.add(@t0, -3600)}
    late = %{id: "b2", closed_at: DateTime.add(@t0, 7200)}

    assert ReadySince.compute(queued, [{"a", "b1"}, {"a", "b2"}], [early, late]) ==
             %{"a" => DateTime.add(@t0, 7200)}
  end

  test "a verifying blocker counts from awaiting_verification_at; unknown blockers are ignored" do
    verifying = %{id: "v", closed_at: nil, awaiting_verification_at: DateTime.add(@t0, 60)}

    assert ReadySince.compute(%{"a" => @t0}, [{"a", "v"}, {"a", "ghost"}], [verifying]) ==
             %{"a" => DateTime.add(@t0, 60)}
  end

  test "edges on tickets that are not queued are ignored" do
    blocker = %{id: "b", closed_at: DateTime.add(@t0, 60)}
    assert ReadySince.compute(%{"a" => @t0}, [{"other", "b"}], [blocker]) == %{"a" => @t0}
  end
end
