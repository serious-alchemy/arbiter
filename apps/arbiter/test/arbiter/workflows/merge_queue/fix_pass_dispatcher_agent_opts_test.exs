defmodule Arbiter.Workflows.MergeQueue.FixPassDispatcherAgentOptsTest do
  @moduledoc """
  bd-cfktou: an agy pass's egress run is owned by the pass's worker and keyed
  by its task. The conflict/fix-pass spawn paths must hand both to the adapter.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  test "agent_opts/4 carries the worker as :owner and the ticket as :task_id" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    context = %{workspace: nil, task: %{id: "bd-pass1"}}

    opts =
      FixPassDispatcher.agent_opts([owner: worker, worktree_path: "/w"], context, "/w",
        arb_token: "t"
      )

    assert Keyword.fetch!(opts, :owner) == worker
    assert Keyword.fetch!(opts, :task_id) == "bd-pass1"
    assert Keyword.fetch!(opts, :worktree_path) == "/w"
    assert Keyword.fetch!(opts, :arb_token) == "t"
  end
end
