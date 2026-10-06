defmodule Arbiter.MCP.TaskLifecycleVocabularyTest do
  @moduledoc """
  bd-6fkgvo (ticket lifecycle 10/13, AC3): MCP speaks the lifecycle
  vocabulary. `ticket_show` returns `state`, `column`, `step`, `attention` and
  `close_reason`; `ticket_list` filters by `state` and by `column`;
  `ticket_ready` is exactly the `:ready` column, in dispatch order.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Attention, Dependencies, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "vocab-#{System.unique_integer([:positive])}", prefix: "vo"})

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    # One ticket in every column.
    blocker = in_state(ws, :active, %{title: "in progress"})
    blocked = in_state(ws, :queued, %{title: "blocked"})
    {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

    tickets = %{
      backlog: in_state(ws, :backlog, %{title: "backlog"}),
      blocked: blocked,
      ready_low: in_state(ws, :queued, %{title: "ready low", priority: 3}),
      ready_high: in_state(ws, :queued, %{title: "ready high", priority: 0}),
      in_progress: blocker,
      merging: in_state(ws, :merging, %{title: "merging"}),
      verifying: in_state(ws, :verifying, %{title: "verifying"}),
      closed: in_state(ws, :closed, %{title: "closed"})
    }

    %{ws: ws, coordinator: coordinator, t: tickets}
  end

  defp in_state(ws, state, attrs)

  defp in_state(ws, :backlog, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp in_state(ws, :queued, attrs), do: ws |> in_state(:backlog, attrs) |> transition!(:promote)
  defp in_state(ws, :active, attrs), do: ws |> in_state(:queued, attrs) |> transition!(:start)
  defp in_state(ws, :merging, attrs), do: ws |> in_state(:active, attrs) |> transition!(:open_pr)

  defp in_state(ws, :verifying, attrs),
    do: ws |> in_state(:active, attrs) |> transition!(:await_verification)

  defp in_state(ws, :closed, attrs),
    do: ws |> in_state(:backlog, attrs) |> transition!(:close, %{close_reason: :duplicate})

  defp transition!(issue, transition, args \\ %{}) do
    {:ok, next} = Ash.update(issue, args, action: transition)
    next
  end

  defp ids(tasks), do: tasks |> Enum.map(& &1.id) |> Enum.sort()

  describe "ticket_show" do
    test "the slim view carries state, column, step, attention and close_reason", ctx do
      id = ctx.t.in_progress.id
      {:ok, _} = Attention.raise_cause(id, :run_crashed, "boom")

      assert {:ok, shown} = Catalog.call(ctx.coordinator, "ticket_show", %{"id" => id})

      assert shown.state == "active"
      assert shown.column == "in_progress"
      assert shown.step == "implementing"
      assert shown.close_reason == nil
      assert %{owner: "coordinator", cause: "run_crashed", reason: reason} = shown.attention
      assert is_binary(reason)
      # bd-36ytcl: the legacy status is gone.
      refute Map.has_key?(shown, :status)
    end

    test "the full view carries them too, and a closed ticket its close reason", ctx do
      assert {:ok, shown} =
               Catalog.call(ctx.coordinator, "ticket_show", %{
                 "id" => ctx.t.closed.id,
                 "full" => true
               })

      assert %{state: "closed", column: "closed", step: nil, attention: nil} = shown
      assert shown.close_reason == "duplicate"
    end

    test "a queued ticket behind an open blocker reads as blocked, naming it", ctx do
      assert {:ok, shown} =
               Catalog.call(ctx.coordinator, "ticket_show", %{"id" => ctx.t.blocked.id})

      assert shown.column == "blocked"
      assert shown.blocked_by == [ctx.t.in_progress.id]
    end

    test "a merging ticket's step names where its PR is", ctx do
      assert {:ok, shown} =
               Catalog.call(ctx.coordinator, "ticket_show", %{"id" => ctx.t.merging.id})

      assert shown.column == "merging"
      assert shown.step in ~w(waiting_ci in_merge_queue behind_base merge_blocked)
    end
  end

  describe "ticket_list" do
    test "filters by state", ctx do
      assert {:ok, %{tasks: tasks}} =
               Catalog.call(ctx.coordinator, "ticket_list", %{"state" => "queued"})

      assert ids(tasks) == ids([ctx.t.blocked, ctx.t.ready_low, ctx.t.ready_high])
      assert Enum.all?(tasks, &(&1.state == "queued"))
    end

    test "filters by column", ctx do
      assert {:ok, %{tasks: blocked}} =
               Catalog.call(ctx.coordinator, "ticket_list", %{"column" => "blocked"})

      assert ids(blocked) == ids([ctx.t.blocked])
      assert [%{column: "blocked", blocked_by: [_]}] = blocked

      assert {:ok, %{tasks: ready}} =
               Catalog.call(ctx.coordinator, "ticket_list", %{"column" => "ready"})

      assert ids(ready) == ids([ctx.t.ready_low, ctx.t.ready_high])

      for {column, key} <- [
            {"backlog", :backlog},
            {"in_progress", :in_progress},
            {"merging", :merging},
            {"verifying", :verifying},
            {"closed", :closed}
          ] do
        assert {:ok, %{tasks: tasks}} =
                 Catalog.call(ctx.coordinator, "ticket_list", %{"column" => column})

        assert ids(tasks) == ids([ctx.t[key]]), "column #{column}"
      end
    end

    test "every listed task carries its state and column", ctx do
      assert {:ok, %{tasks: tasks}} = Catalog.call(ctx.coordinator, "ticket_list", %{})

      by_id = Map.new(tasks, &{&1.id, &1})
      assert by_id[ctx.t.verifying.id].column == "verifying"
      assert by_id[ctx.t.verifying.id].state == "verifying"
      assert by_id[ctx.t.verifying.id].attention.cause == "awaiting_verification"
    end

    test "rejects an unknown state or column", ctx do
      assert {:tool_error, "`state` must be one of" <> _, _type} =
               Catalog.call(ctx.coordinator, "ticket_list", %{"state" => "in_progress"})

      assert {:tool_error, "`column` must be one of" <> _, _type} =
               Catalog.call(ctx.coordinator, "ticket_list", %{"column" => "waiting"})
    end
  end

  describe "ticket_ready" do
    test "returns exactly the :ready column, in dispatch order", ctx do
      assert {:ok, %{tasks: tasks, count: 2}} = Catalog.call(ctx.coordinator, "ticket_ready", %{})

      assert Enum.map(tasks, & &1.id) == [ctx.t.ready_high.id, ctx.t.ready_low.id]
      assert Enum.all?(tasks, &(&1.column == "ready"))
    end
  end

  describe "catalog descriptions" do
    test "the task tools describe tickets in the lifecycle vocabulary" do
      for name <-
            ~w(ticket_show ticket_list ticket_ready ticket_promote ticket_demote ticket_create ticket_verify) do
        tool = Enum.find(Catalog.all(), &(&1.name == name))
        text = tool.description <> inspect(tool.input_schema)

        refute text =~ "refined", "#{name} still says refined"
        refute text =~ ~r/parks? at `awaiting_verification`/, "#{name} still parks at a status"
      end

      for name <- ~w(ticket_show ticket_list ticket_ready) do
        %{description: description} = Enum.find(Catalog.all(), &(&1.name == name))
        assert description =~ "column", "#{name} does not name the column"
        assert description =~ "attention", "#{name} does not name attention"
      end
    end
  end
end
