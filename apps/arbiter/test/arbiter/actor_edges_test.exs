defmodule Arbiter.ActorEdgesTest do
  @moduledoc """
  bd-6i7yzq: the in-process edges derive an `Arbiter.Actor` — the MCP tier (by
  scope), the scheduler and the reconcilers (by process) — and what they write
  is attributed to it. Attribution only: none of these calls is refused or
  allowed differently than before.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.Board.Autopilot
  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Reviews.PrStatePoller
  alias Arbiter.Tasks.{AttentionSweep, Dependency, Issue, Skill, Workspace}
  alias Arbiter.Tasks.Issue.Version
  alias Arbiter.Workflows.PendingMergeSweeper

  @coordinator %Scope{tier: :coordinator, workspace_id: nil}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "edge-#{System.unique_integer([:positive])}", prefix: "ed"})

    {:ok, issue} =
      Ash.create(Issue, %{title: "edge", workspace_id: ws.id, acceptance: "- works"})

    on_exit(fn -> Actor.put(nil) end)
    {:ok, ws: ws, issue: issue}
  end

  defp versions(issue, action) do
    Version
    |> Ash.Query.filter(version_source_id == ^issue.id and version_action_name == ^action)
    |> Ash.read!()
  end

  defp ambient_of(pid) do
    {:dictionary, dict} = Process.info(pid, :dictionary)
    Keyword.get(dict, :arbiter_actor)
  end

  describe "MCP edge" do
    test "a coordinator's ticket_promote is attributed to the coordinator", %{issue: issue} do
      assert {:ok, _} = Catalog.call(@coordinator, "ticket_promote", %{"id" => issue.id})
      assert [%{actor: "coordinator"}] = versions(issue, :promote_to_ready)
      assert Actor.current() == nil, "the ambient actor is restored after the call"
    end

    test "an operator-proof token's ticket_demote is attributed to operator:cli", %{
      issue: issue
    } do
      {:ok, _} = Ash.update(issue, %{}, action: :promote_to_ready)
      scope = %Scope{tier: :coordinator, operator: true}

      assert {:ok, _} = Catalog.call(scope, "ticket_demote", %{"id" => issue.id})
      assert [%{actor: "operator:cli"}] = versions(issue, :return_to_backlog)
    end

    test "a worker's own progress update is attributed to worker:<ticket>", %{
      ws: ws,
      issue: issue
    } do
      scope = %Scope{tier: :worker, workspace_id: ws.id, task_id: issue.id}

      assert {:ok, _} =
               Catalog.call(scope, "ticket_update_progress", %{"notes" => "halfway"})

      assert [%{actor: actor}] = versions(issue, :update)
      assert actor == "worker:#{issue.id}"
    end

    test "ticket_close is attributed too", %{issue: issue} do
      assert {:ok, _} =
               Catalog.call(@coordinator, "ticket_close", %{"id" => issue.id, "reason" => "done"})

      assert Enum.any?(
               Version |> Ash.read!(),
               &(&1.version_source_id == issue.id and &1.actor == "coordinator" and
                   &1.version_action_name == :close)
             )
    end

    test "workspace_config_set lands on the workspace version", %{ws: ws} do
      assert {:ok, _} =
               Catalog.call(@coordinator, "workspace_config_set", %{
                 "workspace" => ws.id,
                 "key" => "merge.auto_merge",
                 "value" => true
               })

      [version | _] =
        Workspace.Version
        |> Ash.Query.filter(version_source_id == ^ws.id)
        |> Ash.Query.sort(version_inserted_at: :desc)
        |> Ash.read!()

      assert version.actor == "coordinator"
    end

    test "provider_pause / provider_resume record the actor on the pause entry" do
      assert {:ok, _} =
               Catalog.call(@coordinator, "provider_pause", %{"ref" => "codex", "reason" => "x"})

      assert [%{target: "codex", actor: "coordinator"}] = Arbiter.Providers.Pause.list()

      assert {:ok, _} = Catalog.call(@coordinator, "provider_resume", %{"ref" => "codex"})
    end

    test "review_gate_resolve defaults the resolution's actor to the caller", %{issue: issue} do
      scope = %Scope{tier: :coordinator, operator: true}

      assert {:ok, %{resolution: %{actor: "operator:cli"}}} =
               Catalog.call(scope, "review_gate_resolve", %{
                 "task_id" => issue.id,
                 "decision" => "send_back",
                 "reasoning" => "needs work",
                 "gate" => "review_gate"
               })
    end

    test "skill_create falls back to the caller when no actor is passed" do
      {:ok, ws} = Ash.create(Workspace, %{name: "skill-ws", prefix: "sk"})

      Actor.with_actor(Actor.worker("bd-1"), fn ->
        {:ok, skill} = Arbiter.Skills.create_skill(%{name: "s1", body: "b", workspace_id: ws.id})
        assert skill.actor == "worker:bd-1"
      end)

      _ = Skill
    end
  end

  describe "dependency edges" do
    test "adding and removing an edge records who", %{ws: ws, issue: issue} do
      {:ok, other} = Ash.create(Issue, %{title: "o", workspace_id: ws.id, acceptance: "- ok"})

      Actor.with_actor(Actor.operator("ryan"), fn ->
        {:ok, edge} =
          Ash.create(Dependency, %{
            from_issue_id: issue.id,
            to_issue_id: other.id,
            type: :blocks
          })

        :ok = Ash.destroy!(edge)
      end)

      actors = Dependency.Version |> Ash.read!() |> Enum.map(& &1.actor)
      assert actors != [] and Enum.all?(actors, &(&1 == "operator:ryan"))
    end
  end

  describe "events" do
    test "an event carries the ambient actor unless its payload names one" do
      Arbiter.Events.broadcast("ws-actor", "worker_done", %{task_id: "bd-1"})
      Actor.put(Actor.autopilot())
      Arbiter.Events.broadcast("ws-actor", "worker_done", %{task_id: "bd-2"})
      Arbiter.Events.broadcast("ws-actor", "worker_done", %{task_id: "bd-3", actor: "someone"})

      payloads =
        Arbiter.Events.Record
        |> Ash.Query.filter(workspace_id == "ws-actor")
        |> Ash.Query.sort(seq: :asc)
        |> Ash.read!()
        |> Enum.map(& &1.payload)

      assert [%{"task_id" => "bd-1"} = first, second, third] = Enum.map(payloads, &stringify/1)
      refute Map.has_key?(first, "actor")
      assert second["actor"] == "autopilot"
      assert third["actor"] == "someone"
    end

    test "a ticket transition's task_state event names who moved it", %{issue: issue} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(issue.workspace_id))

      Actor.with_actor(Actor.operator("ryan"), fn ->
        {:ok, _} = Ash.update(issue, %{}, action: :promote_to_ready)
      end)

      assert_receive {:event, %{topic: "task_state", task_id: id, actor: "operator:ryan"}}
      assert id == issue.id
    end
  end

  describe "scheduler and reconciler edges" do
    test "the autopilot's process acts as autopilot" do
      pid =
        start_supervised!(
          {Autopilot,
           name: nil, paused: true, topics: [], interval_ms: 3_600_000, debounce_ms: 3_600_000}
        )

      assert ambient_of(pid) == Actor.autopilot()
    end

    test "reconcilers act as system:<name>" do
      sweeper =
        start_supervised!({PendingMergeSweeper, name: nil, enabled: false}, id: :sweeper)

      attention =
        start_supervised!({AttentionSweep, name: nil, enabled: false}, id: :attention)

      poller = start_supervised!({PrStatePoller, name: nil, enabled: false}, id: :poller)

      assert ambient_of(sweeper) == Actor.system("pending_merge_sweeper")
      assert ambient_of(attention) == Actor.system("attention_sweep")
      assert ambient_of(poller) == Actor.system("pr_state_poller")
    end

    test "a write a reconciler makes is attributed to it", %{issue: issue} do
      # What init/1 does for the process, then a real write from it.
      Actor.with_actor(Actor.system("pending_merge_sweeper"), fn ->
        {:ok, _} = Ash.update(issue, %{notes: "swept"})
      end)

      assert [%{actor: "system:pending_merge_sweeper"}] = versions(issue, :update)
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
