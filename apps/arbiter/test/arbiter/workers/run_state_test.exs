defmodule Arbiter.Workers.RunStateTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workers.RunState

  test "the vocabulary is exactly the ticket's table" do
    assert RunState.kinds() == [:implement, :review, :fix_pass, :conflict]
    assert RunState.states() == [:starting, :working, :waiting, :finished]
    assert RunState.outcomes() == [:succeeded, :failed, :interrupted, :handed_off, :stopped]
  end

  describe "kind_from_meta/1" do
    test "reads the role tag a worker is started with" do
      assert RunState.kind_from_meta(%{}) == :implement
      assert RunState.kind_from_meta(%{role: :implementer}) == :implement
      assert RunState.kind_from_meta(%{role: :reviewer}) == :review
      assert RunState.kind_from_meta(%{review_only: true}) == :review
      assert RunState.kind_from_meta(%{role: :fix_pass}) == :fix_pass
      assert RunState.kind_from_meta(%{role: :conflict_resolver}) == :conflict
      assert RunState.kind_from_meta(nil) == :implement
    end
  end

  test "live?/1 is every state but :finished" do
    assert Enum.filter(RunState.states(), &RunState.live?/1) == [:starting, :working, :waiting]
  end

  test "label/2 carries the outcome once finished" do
    assert RunState.label(:working, nil) == "working"
    assert RunState.label(:finished, :handed_off) == "finished (handed_off)"
  end
end
