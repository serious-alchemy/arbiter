defmodule Arbiter.MCP.TicketAliasTest do
  @moduledoc """
  bd-4jojpw (ticket lifecycle 11/13, AC1): every MCP tool is named `ticket_*`,
  and each old `task_*` name keeps working for one release as a deprecated
  alias that returns exactly what the `ticket_*` name returns.

  Each alias pair is called against the same starting state: both calls run
  inside a transaction that is rolled back, so a mutating tool (`ticket_close`,
  `ticket_promote`, …) sees the same ticket both times.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, Workspace}

  @old_names ~w(task_show task_ready task_update_progress task_create task_update task_close
                task_reopen task_verify task_promote task_demote task_rank
                task_sync_upstream_close task_list)

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "alias-#{System.unique_integer([:positive])}", prefix: "al"})

    backlog = create!(ws, "backlog")
    queued = create!(ws, "queued") |> transition!(:promote)
    active = create!(ws, "active") |> transition!(:promote) |> transition!(:start)

    verifying =
      create!(ws, "verifying")
      |> transition!(:promote)
      |> transition!(:start)
      |> transition!(:await_verification)

    closed = create!(ws, "closed") |> transition!(:close, %{close_reason: :duplicate})

    %{
      ws: ws,
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true},
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: active.id},
      t: %{
        backlog: backlog,
        queued: queued,
        active: active,
        verifying: verifying,
        closed: closed
      }
    }
  end

  defp create!(ws, title) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ok"})

    issue
  end

  defp transition!(issue, transition, args \\ %{}) do
    {:ok, next} = Ash.update(issue, args, action: transition)
    next
  end

  # Arguments that drive each tool down its real (successful) path.
  defp args_for("ticket_show", t), do: %{"id" => t.active.id, "full" => true}
  defp args_for("ticket_ready", _t), do: %{}
  defp args_for("ticket_list", _t), do: %{}
  defp args_for("ticket_update_progress", t), do: %{"id" => t.active.id, "notes" => "progress"}

  defp args_for("ticket_create", _t),
    do: %{"title" => "alias probe", "acceptance" => "- probe", "priority" => 3}

  defp args_for("ticket_update", t), do: %{"id" => t.backlog.id, "title" => "renamed"}
  defp args_for("ticket_close", t), do: %{"id" => t.backlog.id, "reason" => "done"}
  defp args_for("ticket_reopen", t), do: %{"id" => t.closed.id}
  defp args_for("ticket_verify", t), do: %{"id" => t.verifying.id, "observed" => "saw it live"}
  defp args_for("ticket_promote", t), do: %{"id" => t.backlog.id}
  defp args_for("ticket_demote", t), do: %{"id" => t.queued.id}
  defp args_for("ticket_rank", t), do: %{"id" => t.queued.id, "top" => true}
  defp args_for("ticket_sync_upstream_close", t), do: %{"id" => t.closed.id}

  defp call_rolled_back(scope, name, args) do
    {:error, {:rolled_back, result}} =
      Repo.transaction(fn -> Repo.rollback({:rolled_back, Catalog.call(scope, name, args)}) end)

    result
  end

  # A created ticket gets a fresh random id and timestamps each time; blank
  # those (and only those) so the rest of the payload is compared exactly.
  defp normalize({:ok, %{} = data}, "ticket_create"),
    do: {:ok, Map.drop(data, [:id, "id", :created_at, :updated_at, "created_at", "updated_at"])}

  defp normalize(result, _name), do: strip_timestamps(result)

  defp strip_timestamps(%DateTime{}), do: :timestamp
  defp strip_timestamps(%NaiveDateTime{}), do: :timestamp
  defp strip_timestamps(%_{} = struct), do: struct

  defp strip_timestamps(%{} = map),
    do: Map.new(map, fn {k, v} -> {k, strip_timestamps(v)} end)

  defp strip_timestamps(list) when is_list(list), do: Enum.map(list, &strip_timestamps/1)

  defp strip_timestamps(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> strip_timestamps() |> List.to_tuple()

  defp strip_timestamps(other), do: other

  test "every task_* tool has a ticket_* equivalent and no canonical tool is named task_*" do
    names = Enum.map(Catalog.all(), & &1.name)

    for old <- @old_names do
      assert Map.fetch!(Catalog.legacy_aliases(), old) ==
               String.replace_prefix(old, "task_", "ticket_")

      assert String.replace_prefix(old, "task_", "ticket_") in names
    end

    refute Enum.any?(names, &String.starts_with?(&1, "task_"))

    # The alias table covers every task_* name the catalog has ever shipped,
    # and nothing else.
    assert Enum.sort(Map.keys(Catalog.legacy_aliases())) == Enum.sort(@old_names)
  end

  test "calling the task_* alias returns exactly what the ticket_* name returns", ctx do
    for {old, new} <- Catalog.legacy_aliases() do
      args = args_for(new, ctx.t)

      via_new = call_rolled_back(ctx.coordinator, new, args)
      via_old = call_rolled_back(ctx.coordinator, old, args)

      assert normalize(via_old, new) == normalize(via_new, new),
             "#{old} and #{new} disagree:\n#{inspect(via_old)}\n#{inspect(via_new)}"
    end
  end

  test "the ticket_* calls exercise the real path, not a shared error", ctx do
    for {_old, new} <- Catalog.legacy_aliases(), new != "ticket_sync_upstream_close" do
      assert {:ok, _} = call_rolled_back(ctx.coordinator, new, args_for(new, ctx.t)),
             "#{new} did not succeed with #{inspect(args_for(new, ctx.t))}"
    end
  end

  test "a worker reaches its tools under both names", ctx do
    for {old, new} <- [
          {"task_show", "ticket_show"},
          {"task_update_progress", "ticket_update_progress"}
        ] do
      args = Map.delete(args_for(new, ctx.t), "id")
      via_new = call_rolled_back(ctx.worker, new, args)
      assert {:ok, _} = via_new
      assert normalize(call_rolled_back(ctx.worker, old, args), new) == normalize(via_new, new)
    end
  end

  test "an alias is gated by its target's tiers", ctx do
    assert {:rpc_error, -32_003, _} = Catalog.call(ctx.worker, "task_update", %{"id" => "x"})
    assert {:rpc_error, -32_003, _} = Catalog.call(ctx.worker, "ticket_update", %{"id" => "x"})
  end

  describe "tools/list" do
    test "lists each alias marked deprecated, pointing at its ticket_* name", ctx do
      visible = Catalog.visible(ctx.coordinator)
      by_name = Map.new(visible, &{&1.name, &1})

      for {old, new} <- Catalog.legacy_aliases() do
        assert %{description: description, input_schema: schema} = Map.fetch!(by_name, old)
        assert description =~ "Deprecated"
        assert description =~ "`#{new}`"
        assert schema == Map.fetch!(by_name, new).input_schema
      end
    end

    test "a worker sees only the aliases of the tools it may call", ctx do
      names = ctx.worker |> Catalog.visible() |> Enum.map(& &1.name)

      assert "task_show" in names
      assert "task_update_progress" in names
      # bd-dtfe9x: a worker may file a child of its own task.
      assert "task_create" in names
      assert "ticket_create" in names
      refute "task_update" in names
      refute "ticket_update" in names
    end
  end
end
