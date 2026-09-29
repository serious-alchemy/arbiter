defmodule Arbiter.Tasks.AttentionOwnershipTest do
  @moduledoc """
  bd-8nlez1 (ticket lifecycle 7/13): coordinator-first attention — the
  coordinator's hand-off to the operator and the operator's hand-back, the
  limits that promote an unresolved coordinator-owned item, the computed
  coordinator queue, and the `inbox` events that wake the coordinator.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Escalation
  alias Arbiter.Tasks.{Attention, AttentionLimits, AttentionSweep, Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ownership-#{System.unique_integer([:positive])}",
        prefix: "ow"
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "ownership", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    assert task.state == :active

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    %{ws: ws, task: task, coordinator: coordinator}
  end

  defp raise_crash(task), do: {:ok, _} = Attention.raise_cause(task.id, :run_crashed, "boom")

  defp attention_event(event, task_id) do
    receive do
      {:event, %{topic: "inbox", kind: "attention", event: ^event, task_id: ^task_id} = payload} ->
        payload
    after
      1_000 -> flunk("no inbox #{event} event for #{task_id}")
    end
  end

  defp drain_events do
    receive do
      {:event, _} -> drain_events()
    after
      0 -> :ok
    end
  end

  describe "hand-off and hand-back" do
    test "the coordinator hands a ticket's attention to the operator with a note", ctx do
      raise_crash(ctx.task)

      assert {:ok, %{} = res} =
               Catalog.call(ctx.coordinator, "ticket_handoff", %{
                 "id" => ctx.task.id,
                 "note" => "needs a credential only you have"
               })

      assert res.attention.owner == "operator"

      issue = Ash.get!(Issue, ctx.task.id)
      assert issue.attention_owner == :operator
      assert issue.attention_owner_cause == :run_crashed
      assert issue.attention_note == "needs a credential only you have"

      assert %{owner: :operator, note: "needs a credential only you have"} =
               Attention.current(issue)

      assert {:ok, slim} = Catalog.call(ctx.coordinator, "ticket_show", %{"id" => ctx.task.id})
      assert slim.attention.note == "needs a credential only you have"

      assert {:ok, shown} =
               Catalog.call(ctx.coordinator, "ticket_show", %{"id" => ctx.task.id, "full" => true})

      assert shown.attention_owner == "operator"
      assert shown.attention_note == "needs a credential only you have"
      assert shown.attention.owner == "operator"
      assert shown.attention.note == "needs a credential only you have"

      payload = attention_event("handed_off", ctx.task.id)
      assert payload.owner == "operator"
      assert payload.note == "needs a credential only you have"
    end

    test "a hand-off needs a note, and attention to hand off", ctx do
      assert {:error, :no_attention} = Attention.hand_off(ctx.task.id, :operator, "why")

      raise_crash(ctx.task)
      assert {:error, :note_required} = Attention.hand_off(ctx.task.id, :operator, "  ")

      assert {:tool_error, _} =
               Catalog.call(ctx.coordinator, "ticket_handoff", %{"id" => ctx.task.id})
    end

    test "the operator hands it back, with a fresh clock and attempt budget", ctx do
      raise_crash(ctx.task)
      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "stuck")
      drain_events()

      assert {:ok, res} =
               Catalog.call(ctx.coordinator, "ticket_handback", %{
                 "id" => ctx.task.id,
                 "note" => "rotated the key, try again"
               })

      assert res.attention.owner == "coordinator"

      issue = Ash.get!(Issue, ctx.task.id)
      assert issue.attention_owner == :coordinator
      assert issue.attention_note == "rotated the key, try again"
      assert issue.attention_resume_attempts == 0
      assert %DateTime{} = issue.attention_owner_since
      assert %{owner: :coordinator} = Attention.current(issue)

      assert attention_event("handed_back", ctx.task.id).owner == "coordinator"

      assert {:error, {:already_owned, :coordinator}} =
               Attention.hand_off(ctx.task.id, :coordinator, nil)
    end

    test "the move goes when the attention clears", ctx do
      raise_crash(ctx.task)
      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "stuck")
      {:ok, _} = Attention.clear(ctx.task.id, :test)

      issue = Ash.get!(Issue, ctx.task.id)
      assert issue.attention_owner == nil
      assert issue.attention_note == nil
    end

    test "a different cause starts back at the owner table", ctx do
      raise_crash(ctx.task)
      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "stuck")
      {:ok, _} = Attention.raise_cause(ctx.task.id, :pr_closed, "closed")

      issue = Ash.get!(Issue, ctx.task.id)
      assert issue.attention_owner == nil
      assert %{owner: :coordinator, cause: :pr_closed} = Attention.current(issue)
    end
  end

  describe "limits" do
    test "the defaults are readable through workspace_config_get", ctx do
      assert {:ok, %{value: 240}} =
               Catalog.call(ctx.coordinator, "workspace_config_get", %{
                 "key" => "attention.coordinator_limit_minutes"
               })

      assert {:ok, %{value: 3}} =
               Catalog.call(ctx.coordinator, "workspace_config_get", %{
                 "key" => "attention.run_crashed_max_resumes"
               })

      assert {:ok, %{value: %{"attention" => attention}}} =
               Catalog.call(ctx.coordinator, "workspace_config_get", %{})

      assert attention == AttentionLimits.defaults()
    end

    test "a coordinator-owned item past the time limit moves to the operator", ctx do
      raise_crash(ctx.task)
      drain_events()
      now = DateTime.utc_now()

      assert %{promoted: []} = AttentionSweep.run(now: DateTime.add(now, 3 * 3600, :second))
      assert Ash.get!(Issue, ctx.task.id).attention_owner == nil

      assert %{promoted: [id]} = AttentionSweep.run(now: DateTime.add(now, 5 * 3600, :second))
      assert id == ctx.task.id

      issue = Ash.get!(Issue, ctx.task.id)
      assert issue.attention_owner == :operator
      assert issue.attention_note == "coordinator did not resolve within 4h"

      assert %{owner: :operator, note: "coordinator did not resolve within 4h"} =
               Attention.current(issue)

      payload = attention_event("promoted", ctx.task.id)
      assert payload.note == "coordinator did not resolve within 4h"

      # Already the operator's: a later sweep leaves it alone.
      assert %{promoted: []} = AttentionSweep.run(now: DateTime.add(now, 9 * 3600, :second))
    end

    test "the supervised sweeper promotes on its tick, on the primary instance only", ctx do
      raise_crash(ctx.task)
      later = DateTime.add(DateTime.utc_now(), 5 * 3600, :second)

      secondary =
        start_supervised!(
          {AttentionSweep,
           name: nil, enabled: false, primary?: fn -> false end, clock: fn -> later end},
          id: :secondary
        )

      send(secondary, :sweep)
      _ = :sys.get_state(secondary)
      assert Ash.get!(Issue, ctx.task.id).attention_owner == nil

      primary =
        start_supervised!(
          {AttentionSweep,
           name: nil, enabled: false, primary?: fn -> true end, clock: fn -> later end},
          id: :primary
        )

      send(primary, :sweep)
      _ = :sys.get_state(primary)

      assert Ash.get!(Issue, ctx.task.id).attention_note ==
               "coordinator did not resolve within 4h"
    end

    test "the workspace sets the time limit, and 0 turns it off", ctx do
      {:ok, _} =
        Ash.update(ctx.ws, %{config: %{"attention" => %{"coordinator_limit_minutes" => 30}}})

      raise_crash(ctx.task)
      now = DateTime.utc_now()

      assert %{promoted: [_]} = AttentionSweep.run(now: DateTime.add(now, 31 * 60, :second))

      assert Ash.get!(Issue, ctx.task.id).attention_note ==
               "coordinator did not resolve within 30m"

      {:ok, _} = Attention.hand_off(ctx.task.id, :coordinator, nil)

      {:ok, _} =
        Ash.update(Ash.get!(Workspace, ctx.ws.id), %{
          config: %{"attention" => %{"coordinator_limit_minutes" => 0}}
        })

      assert %{promoted: []} = AttentionSweep.run(now: DateTime.add(now, 100 * 3600, :second))
    end

    test "a hand-back restarts the coordinator's clock", ctx do
      raise_crash(ctx.task)
      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "stuck")
      {:ok, _} = Attention.hand_off(ctx.task.id, :coordinator, nil)
      now = DateTime.utc_now()

      assert %{promoted: []} = AttentionSweep.run(now: DateTime.add(now, 3 * 3600, :second))
      assert %{promoted: [_]} = AttentionSweep.run(now: DateTime.add(now, 5 * 3600, :second))
    end

    test "a run_crashed item past its resume attempts moves to the operator", ctx do
      for _ <- 1..3 do
        raise_crash(ctx.task)
        {:ok, _} = Attention.clear(ctx.task.id, :run_restarted, resumed_from_failure: true)
      end

      assert Ash.get!(Issue, ctx.task.id).attention_resume_attempts == 3

      raise_crash(ctx.task)

      assert %{promoted: [_]} = AttentionSweep.run(now: DateTime.utc_now())

      assert Ash.get!(Issue, ctx.task.id).attention_note ==
               "coordinator did not resolve within 3 resume attempts"
    end

    test "a resumed run counts an attempt only when it resumes a failed run", ctx do
      for {outcome, expected} <- [{:succeeded, 0}, {:failed, 1}] do
        prior =
          Ash.create!(Run, %{
            task_id: ctx.task.id,
            repo: "arbiter",
            workspace_id: ctx.ws.id,
            state: :finished,
            outcome: outcome,
            started_at: DateTime.add(DateTime.utc_now(), -600, :second)
          })

        {:ok, pid} =
          Worker.start(
            task_id: ctx.task.id,
            repo: "arbiter",
            workspace_id: ctx.ws.id,
            meta: %{resume: true, resumed_from_run_id: prior.id}
          )

        assert Ash.get!(Issue, ctx.task.id).attention_resume_attempts == expected

        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end
    end

    test "a transition resets the resume attempts", ctx do
      {:ok, _} = Attention.clear(ctx.task.id, :run_restarted, resumed_from_failure: true)
      assert Ash.get!(Issue, ctx.task.id).attention_resume_attempts == 1

      {:ok, _} = Ash.update(Ash.get!(Issue, ctx.task.id), %{status: :open})
      assert Ash.get!(Issue, ctx.task.id).attention_resume_attempts == 0
    end

    test "a tracker sync failure is the coordinator's first, then the operator's", ctx do
      {:ok, _} =
        Escalation.post(%{
          kind: :tracker_sync_failed,
          workspace_id: ctx.ws.id,
          task_ref: ctx.task.id,
          subject: "#{ctx.task.id} tracker sync failed — dispatched",
          body: "nope"
        })

      issue = Ash.get!(Issue, ctx.task.id)
      assert issue.attention_cause == :tracker_sync_failed
      assert %{owner: :coordinator, waiting_on: :tracker_sync} = Attention.current(issue)

      assert %{promoted: [_]} =
               AttentionSweep.run(now: DateTime.add(DateTime.utc_now(), 5 * 3600, :second))

      assert %{owner: :operator} = Attention.current(Ash.get!(Issue, ctx.task.id))
    end

    test "a tracker sync failure does not mask the cause a ticket already has", ctx do
      raise_crash(ctx.task)

      {:ok, _} =
        Escalation.post(%{
          kind: :tracker_sync_failed,
          workspace_id: ctx.ws.id,
          task_ref: ctx.task.id,
          subject: "#{ctx.task.id} tracker sync failed — dispatched",
          body: "nope"
        })

      assert Ash.get!(Issue, ctx.task.id).attention_cause == :run_crashed
    end
  end

  describe "the computed coordinator queue" do
    test "coordinator_inbox lists coordinator-owned items until the ticket moves on", ctx do
      raise_crash(ctx.task)

      assert {:ok, res} = Catalog.call(ctx.coordinator, "coordinator_inbox", %{})
      assert [item] = Enum.filter(res.attention, &(&1.ticket_id == ctx.task.id))
      assert item.cause == "run_crashed"
      assert item.owner == "coordinator"
      assert item.waiting_on == "resume"
      assert item.reason == "boom"

      # Listing is not reading: the item is still there on the next call.
      assert {:ok, again} =
               Catalog.call(ctx.coordinator, "coordinator_inbox", %{"state" => "outstanding"})

      assert Enum.any?(again.attention, &(&1.ticket_id == ctx.task.id))

      # The ticket is resolved — no clear call, and the item is gone.
      {:ok, _} = Ash.update(Ash.get!(Issue, ctx.task.id), %{}, action: :close)

      assert {:ok, after_close} = Catalog.call(ctx.coordinator, "coordinator_inbox", %{})
      refute Enum.any?(after_close.attention, &(&1.ticket_id == ctx.task.id))
    end

    test "an item handed to the operator leaves the coordinator's queue", ctx do
      raise_crash(ctx.task)
      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "yours")

      assert {:ok, res} = Catalog.call(ctx.coordinator, "coordinator_inbox", %{})
      refute Enum.any?(res.attention, &(&1.ticket_id == ctx.task.id))
      assert Enum.any?(Attention.items(owner: :operator), &(&1.ticket_id == ctx.task.id))
    end
  end

  describe "inbox events" do
    test "raising an attention item wakes the coordinator", ctx do
      raise_crash(ctx.task)

      payload = attention_event("raised", ctx.task.id)
      assert payload.cause == "run_crashed"
      assert payload.owner == "coordinator"
    end

    test "raising the cause a ticket already has says nothing new", ctx do
      raise_crash(ctx.task)
      attention_event("raised", ctx.task.id)

      raise_crash(ctx.task)
      refute_receive {:event, %{topic: "inbox", kind: "attention", event: "raised"}}, 100
    end
  end
end
