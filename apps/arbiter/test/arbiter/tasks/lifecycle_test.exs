defmodule Arbiter.Tasks.LifecycleTest do
  @moduledoc """
  bd-842qio: the stored-state table itself — states and transitions — as pure
  functions. The resource
  tests (`Arbiter.Tasks.IssueLifecycleTest`) prove the actions obey it.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Lifecycle

  test "the six stored states, in lifecycle order" do
    assert Lifecycle.states() == [:backlog, :queued, :active, :merging, :verifying, :closed]
  end

  test "the three close reasons" do
    assert Lifecycle.close_reasons() == [:completed, :wont_do, :duplicate]
  end

  describe "the transition table" do
    test "names exactly the nine transitions" do
      assert Enum.sort(Lifecycle.transitions()) ==
               Enum.sort([
                 :promote,
                 :demote,
                 :start,
                 :open_pr,
                 :return_to_work,
                 :await_verification,
                 :close,
                 :reopen,
                 :requeue
               ])
    end

    test "each transition's sources and target" do
      assert Lifecycle.rule(:promote) == {[:backlog], :queued}
      assert Lifecycle.rule(:demote) == {[:queued, :active, :merging], :backlog}
      assert Lifecycle.rule(:start) == {[:backlog, :queued], :active}
      assert Lifecycle.rule(:requeue) == {[:active, :merging], :queued}
      assert Lifecycle.rule(:open_pr) == {[:active], :merging}
      assert Lifecycle.rule(:return_to_work) == {[:merging], :active}
      assert Lifecycle.rule(:await_verification) == {[:active, :merging], :verifying}

      assert Lifecycle.rule(:close) ==
               {[:backlog, :queued, :active, :merging, :verifying], :closed}

      assert Lifecycle.rule(:reopen) == {[:closed, :verifying], :queued}
    end

    test "allowed?/2 answers from the table" do
      assert Lifecycle.allowed?(:start, :queued)
      refute Lifecycle.allowed?(:start, :merging)
      refute Lifecycle.allowed?(:close, :closed)
      assert Lifecycle.allowed?(:reopen, :verifying)
      refute Lifecycle.allowed?(:no_such_transition, :queued)
    end
  end
end
