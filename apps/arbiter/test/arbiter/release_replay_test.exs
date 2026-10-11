defmodule Arbiter.ReleaseReplayTest do
  @moduledoc """
  bd-c7lx65 (R15): the operator's entry points to the offline replay harness,
  `Arbiter.Release.replay/1`, `replay_report/1` and `replay_candidates/1`.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureIO

  alias Arbiter.LifecycleFixtures
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  test "replay_report/1 prints the report and returns it" do
    output =
      capture_io(fn ->
        assert %{counts: counts, cells: []} = Arbiter.Release.replay_report(start: false)
        assert counts == %{}
      end)

    assert output =~ "No offline replays recorded"
  end

  test "replay_candidates/1 lists closed tickets and whether each can be replayed" do
    {:ok, ws} = Ash.create(Workspace, %{name: "replay-rel-#{System.unique_integer([:positive])}"})

    {:ok, issue} =
      Ash.create(Issue, %{title: "Done already", difficulty: 2, workspace_id: ws.id})

    LifecycleFixtures.put_state!(issue, :closed)

    output =
      capture_io(fn ->
        assert [{%Issue{}, {:error, _}}] =
                 Arbiter.Release.replay_candidates(workspace_id: ws.id, start: false)
      end)

    assert output =~ issue.id
    assert output =~ "not replayable"
  end

  test "replay/1 runs a replay and prints a one-line account of it" do
    output =
      capture_io(fn ->
        assert {:error, :not_found} =
                 Arbiter.Release.replay(
                   task_id: "bd-nosuch",
                   account: "claude:none",
                   model: "claude-sonnet-5-5",
                   runner: fn _role, _spec -> flunk("nothing to run") end,
                   start: false
                 )
      end)

    assert output =~ "replay not started: :not_found"
  end

  # One that starts is `Arbiter.Loop.ReplayTest`'s, which has a task to replay.
  test "replay/1 with async: true refuses at once what cannot be replayed; nothing starts" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, :not_found} =
                 Arbiter.Release.replay(
                   task_id: "bd-nosuch",
                   account: "claude:none",
                   model: "claude-sonnet-5-5",
                   runner: fn _role, _spec -> flunk("nothing to run") end,
                   async: true,
                   start: false
                 )
      end)

    assert output =~ "replay not started: :not_found"
  end
end
