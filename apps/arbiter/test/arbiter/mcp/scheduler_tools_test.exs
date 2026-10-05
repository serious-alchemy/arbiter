defmodule Arbiter.MCP.SchedulerToolsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "scheduler-tools-ws-#{System.unique_integer([:positive])}",
        prefix: "stw#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id}

    # Start an autopilot instance for testing. Supervised rather than
    # start_link'd: a linked instance races the test process's exit, so an
    # on_exit `Process.alive?` + `GenServer.stop` could hit a dead pid.
    start_supervised!(
      {Autopilot,
       name: nil,
       paused: false,
       interval_ms: :never,
       topics: [],
       snapshot: fn opts -> default_board(opts[:paused]) end}
    )

    on_exit(fn ->
      # Reset the global Autopilot singleton to paused state to prevent test pollution
      Autopilot.pause(Autopilot)
    end)

    {:ok, ws: ws, coordinator: coordinator}
  end

  defp default_board(paused?) do
    %{
      ready: [],
      backlog: [],
      blocked: [],
      in_progress: [],
      merging: [],
      verifying: [],
      closed_today: [],
      attention: [],
      promote: nil,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: paused?,
      now: DateTime.utc_now()
    }
  end

  describe "scheduler_pause/2" do
    test "pauses the autopilot and records who", ctx do
      # Ensure we start in resumed state
      :ok = Autopilot.resume()

      assert false == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_pause(ctx.coordinator, %{})

      assert data.paused == true
      assert data.changed_by == "coordinator via mcp"
      assert %DateTime{} = data.changed_at
      assert Autopilot.paused?() == true
    end

    test "audits the pause and notifies the coordinator, naming the actor", ctx do
      :ok = Autopilot.resume()

      assert {:ok, _} = Tools.scheduler_pause(ctx.coordinator, %{})

      assert [%{paused: true, actor: "coordinator", surface: "mcp"} | _] =
               Arbiter.Settings.scheduler_changes()

      assert [msg | _] =
               Arbiter.Messages.Message
               |> Ash.read!()
               |> Enum.filter(&(&1.escalation_kind == :scheduler_paused))

      assert msg.subject =~ "coordinator"
      assert msg.body =~ "mcp"
    end

    test "returns current state when already paused", ctx do
      :ok = Autopilot.pause()
      assert true == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_pause(ctx.coordinator, %{})

      assert data.paused == true
    end
  end

  describe "scheduler_resume/2" do
    test "resumes the autopilot and records who", ctx do
      :ok = Autopilot.pause()
      assert true == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_resume(ctx.coordinator, %{})

      assert data.paused == false
      assert data.changed_by == "coordinator via mcp"
      assert %DateTime{} = data.changed_at
      assert Autopilot.paused?() == false
    end

    test "returns current state when already running", ctx do
      :ok = Autopilot.resume()
      assert false == Autopilot.paused?()

      assert {:ok, data} = Tools.scheduler_resume(ctx.coordinator, %{})

      assert data.paused == false
    end
  end

  describe "scheduler_status/2" do
    test "returns the current pause state", ctx do
      :ok = Autopilot.pause()

      assert {:ok, data} = Tools.scheduler_status(ctx.coordinator, %{})

      assert data.paused == true
    end

    test "returns running state", ctx do
      :ok = Autopilot.resume()

      assert {:ok, data} = Tools.scheduler_status(ctx.coordinator, %{})

      assert data.paused == false
    end

    # bd-9fgg04: the body is `Arbiter.Board.Drain.to_json/1` — a pause alone is
    # not "idle", so the drain state rides along with the flag.
    test "reports the drain state: running while the autopilot promotes", ctx do
      :ok = Autopilot.resume()

      assert {:ok, data} = Tools.scheduler_status(ctx.coordinator, %{})

      assert data.state == "running"
      assert data.safe_to_restart == false
      assert is_list(data.in_flight)
    end

    test "a paused scheduler with live work reports draining, naming the work", ctx do
      :ok = Autopilot.pause()
      test_pid = self()

      runner =
        spawn_link(fn ->
          Arbiter.Board.Drain.track(:external_review, %{detail: "github:o/r#9"}, fn ->
            send(test_pid, :running)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :running

      assert {:ok, data} = Tools.scheduler_status(ctx.coordinator, %{})

      assert data.paused == true
      assert data.state == "draining"
      assert data.safe_to_restart == false

      assert Enum.any?(
               data.in_flight,
               &(&1.kind == "external_review" and &1.detail == "github:o/r#9")
             )

      send(runner, :release)
    end

    test "reports when and by what the state last changed", ctx do
      :ok = Autopilot.resume(Autopilot)
      :ok = Autopilot.pause(Autopilot, "mcp")

      assert {:ok, data} = Tools.scheduler_status(ctx.coordinator, %{})

      assert data.changed_by == "mcp"
      assert %DateTime{} = data.changed_at
    end
  end
end
