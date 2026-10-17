defmodule Arbiter.Tasks.ClaimResyncTest do
  @moduledoc """
  Re-sync of already-claimed tickets with their tracker story (bd-evxsrx):
  a tracker edit to priority/title/description lands on a backlog/queued
  ticket, never rewrites a ticket in flight (the coordinator is told instead),
  never overwrites a field the coordinator changed locally (reported as
  divergent), and a closed/archived story is flagged, never silently closed.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Claim, Issue, Workspace}
  alias Arbiter.Trackers.GitHub.Config, as: GHConfig

  @viewer "test-worker"
  @env_var "ARBITER_RESYNC_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "resync-test-token")

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resync-gh",
        prefix: "rsy",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{
              "owner" => "ryanrborn",
              "repo" => "arbiter",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    on_exit(fn ->
      GHConfig.clear()
      System.delete_env(@env_var)
    end)

    # The "story" as the tracker currently serves it; tests edit it with `edit_story/2`.
    story =
      start_supervised!(Supervisor.child_spec({Agent, fn -> story_payload() end}, id: :story))

    patches = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :patches))

    Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/user"} ->
          Req.Test.json(conn, %{"login" => @viewer})

        {"GET", "/repos/ryanrborn/arbiter/issues"} ->
          current = Agent.get(story, & &1)
          Req.Test.json(conn, if(current["state"] == "open", do: [current], else: []))

        {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
          Req.Test.json(conn, Agent.get(story, & &1))

        {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

        {"POST", "/repos/ryanrborn/arbiter/issues/43/assignees"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

        # A local title/description edit is pushed upstream (SyncFields). The
        # push is recorded but the served story is left alone, so the tracker
        # keeps whatever the test last set via `edit_story/2`.
        {"PATCH", "/repos/ryanrborn/arbiter/issues/43"} ->
          Agent.update(patches, &[conn.method | &1])
          Req.Test.json(conn, Agent.get(story, & &1))
      end
    end)

    {:ok, ws: ws, story: story, patches: patches}
  end

  defp story_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 43,
        "title" => "Wire up the thing",
        "body" => "Mirror me into a task.",
        "state" => "open",
        "html_url" => "https://github.com/ryanrborn/arbiter/issues/43",
        "assignees" => [%{"login" => @viewer}],
        "labels" => [%{"name" => "priority: 2"}]
      },
      overrides
    )
  end

  defp edit_story(story, overrides), do: Agent.update(story, &Map.merge(&1, overrides))

  defp claim!(ws) do
    {:ok, :created, task} = Claim.claim(ws, "43")
    task
  end

  # One full `tracker_sync`: plan, then apply.
  defp sync!(ws) do
    {:ok, plan} = Claim.plan(ws)
    {:ok, results} = Claim.apply_plan(ws, plan)
    {plan, results}
  end

  defp reload(task), do: Ash.get!(Issue, task.id)

  defp inbox_notes(task) do
    Message
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == task.id and &1.to_ref == Message.coordinator_ref()))
  end

  describe "a tracker edit lands on a backlog/queued claimed ticket" do
    test "priority, title and description on a backlog ticket", %{ws: ws, story: story} do
      task = claim!(ws)
      assert task.state == :backlog
      assert task.priority == 2

      edit_story(story, %{
        "title" => "Wire up the other thing",
        "body" => "A rewritten description.",
        "labels" => [%{"name" => "priority: 0"}]
      })

      {plan, results} = sync!(ws)

      assert [{:resync, task_id, _}] = plan
      assert task_id == task.id
      assert [{:resynced, _, _}] = results

      updated = reload(task)
      assert updated.title == "Wire up the other thing"
      assert updated.description == "A rewritten description."
      assert updated.priority == 0
      assert inbox_notes(task) == []
    end

    test "a queued ticket picks the edit up too", %{ws: ws, story: story} do
      task = ws |> claim!() |> put_state!(:queued)

      edit_story(story, %{"labels" => [%{"name" => "priority: 4"}]})
      sync!(ws)

      updated = reload(task)
      assert updated.state == :queued
      assert updated.priority == 4
    end

    test "the pull is not echoed back upstream and is idempotent", %{
      ws: ws,
      story: story,
      patches: patches
    } do
      task = claim!(ws)
      edit_story(story, %{"title" => "Renamed upstream"})

      sync!(ws)
      assert reload(task).title == "Renamed upstream"
      assert Agent.get(patches, & &1) == []

      assert {[], []} = sync!(ws)
    end

    test "an unchanged story produces no action", %{ws: ws} do
      _task = claim!(ws)
      assert {[], []} = sync!(ws)
    end
  end

  describe "a ticket in flight is never rewritten" do
    test "the change is left alone and the coordinator gets one inbox note", %{
      ws: ws,
      story: story
    } do
      task = ws |> claim!() |> put_state!(:active)

      edit_story(story, %{
        "title" => "Rescoped mid-flight",
        "labels" => [%{"name" => "priority: 0"}]
      })

      {_plan, [{:resynced, _, decision}]} = sync!(ws)
      assert Enum.sort(decision.mid_flight) == [:priority, :title]

      same = reload(task)
      assert same.title == "Wire up the thing"
      assert same.priority == 2

      assert [note] = inbox_notes(task)
      assert note.kind == :info
      assert note.body =~ "Rescoped mid-flight"
      assert note.body =~ "active"

      # Same unchanged tracker value on the next sync: no second note.
      assert {[], []} = sync!(ws)
      assert [_] = inbox_notes(task)
    end

    test "a merging ticket is in flight too", %{ws: ws, story: story} do
      task = ws |> claim!() |> put_state!(:merging)
      edit_story(story, %{"body" => "Changed under the PR."})

      sync!(ws)

      assert reload(task).description == "Mirror me into a task."
      assert [_] = inbox_notes(task)
    end

    test "a still-unapplied change lands once the ticket is back to queued", %{
      ws: ws,
      story: story
    } do
      task = ws |> claim!() |> put_state!(:active)
      edit_story(story, %{"labels" => [%{"name" => "priority: 1"}]})
      sync!(ws)
      assert reload(task).priority == 2

      task |> reload() |> put_state!(:queued)
      sync!(ws)
      assert reload(task).priority == 1
    end
  end

  describe "a locally overridden field wins and is reported as divergent" do
    test "a coordinator-set priority is not overwritten", %{ws: ws, story: story} do
      task = claim!(ws)
      Ash.update!(task, %{priority: 0})
      edit_story(story, %{"labels" => [%{"name" => "priority: 3"}]})

      {plan, [{:resynced, _, decision}]} = sync!(ws)

      assert decision.divergent == [:priority]
      assert reload(task).priority == 0

      assert [%{action: "resync", divergent: ["priority"]}] =
               Enum.map(plan, &Claim.serialize_action/1)

      assert [note] = inbox_notes(task)
      assert note.body =~ "priority"
      assert note.body =~ "divergent"

      # Reported once per tracker value, not on every sync.
      assert {[], []} = sync!(ws)
      assert [_] = inbox_notes(task)
    end

    test "a locally edited title is not overwritten, others still are", %{
      ws: ws,
      story: story
    } do
      task = claim!(ws)
      Ash.update!(task, %{title: "Coordinator's own wording"})

      edit_story(story, %{
        "title" => "Tracker's new wording",
        "body" => "New description."
      })

      {_plan, [{:resynced, _, decision}]} = sync!(ws)

      assert decision.divergent == [:title]
      updated = reload(task)
      assert updated.title == "Coordinator's own wording"
      assert updated.description == "New description."
    end

    test "a local edit that already matches the tracker is not divergent", %{
      ws: ws,
      story: story
    } do
      task = claim!(ws)
      Ash.update!(task, %{priority: 0})
      edit_story(story, %{"labels" => [%{"name" => "priority: 0"}]})

      {_plan, results} = sync!(ws)

      assert [{:resynced, _, %{divergent: []}}] = results
      assert reload(task).priority == 0
      assert inbox_notes(task) == []
    end
  end

  describe "a closed or archived story" do
    test "flags the ticket to the coordinator and never closes it", %{ws: ws, story: story} do
      task = claim!(ws)
      edit_story(story, %{"state" => "closed"})

      {plan, results} = sync!(ws)

      refute Enum.any?(plan, &match?({:close, _, _}, &1))
      assert [{:resynced, _, %{closed_upstream: true}}] = results

      assert reload(task).state == :backlog
      assert [note] = inbox_notes(task)
      assert note.body =~ "closed"

      assert {[], []} = sync!(ws)
      assert [_] = inbox_notes(task)
    end

    test "an in-flight ticket is flagged, not closed", %{ws: ws, story: story} do
      task = ws |> claim!() |> put_state!(:active)
      edit_story(story, %{"state" => "closed"})

      sync!(ws)

      assert reload(task).state == :active
      assert [_] = inbox_notes(task)
    end

    test "a reopened story can be flagged again later", %{ws: ws, story: story} do
      task = claim!(ws)

      edit_story(story, %{"state" => "closed"})
      sync!(ws)
      edit_story(story, %{"state" => "open"})
      sync!(ws)
      edit_story(story, %{"state" => "closed"})
      sync!(ws)

      assert [_, _] = inbox_notes(task)
    end
  end

  describe "tickets claimed before snapshots were recorded" do
    test "the first sync adopts the tracker's values without touching the ticket", %{
      ws: ws,
      story: story
    } do
      task = claim!(ws)
      Ash.update!(reload(task), %{tracker_snapshot: nil}, action: :record_tracker_sync)
      edit_story(story, %{"title" => "Edited before first re-sync"})

      assert {[{:resync, _, _}], [{:resynced, _, decision}]} = sync!(ws)
      assert decision.applied == %{}

      updated = reload(task)
      assert updated.title == "Wire up the thing"
      assert updated.tracker_snapshot["title"] == "Edited before first re-sync"
      assert inbox_notes(task) == []
    end
  end

  describe "serialization" do
    test "a resync action and result are JSON-shaped", %{ws: ws, story: story} do
      task = claim!(ws)
      edit_story(story, %{"title" => "Shiny"})

      {plan, results} = sync!(ws)

      assert [
               %{
                 action: "resync",
                 task_id: task_id,
                 applied: %{title: "Shiny"},
                 divergent: [],
                 mid_flight: []
               }
             ] = Enum.map(plan, &Claim.serialize_action/1)

      assert task_id == task.id

      assert [%{outcome: "resynced", task: %{title: "Shiny"}}] =
               Enum.map(results, &Claim.serialize_result/1)
    end
  end
end
