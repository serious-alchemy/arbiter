defmodule Arbiter.Board.AutopilotImagePendingTest do
  @moduledoc """
  bd-5fpj59: a card whose registry image is still publishing is held with a
  `hold_reason` naming the image instead of parking the board-promotion slot;
  other Ready work dispatches meanwhile, and the publish's completion wakes the
  held card without operator action.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  @image_key {:image, "vstim", :abc}
  @pending_phrase "waiting for registry image for vstim; publishing"

  defp pending_hold do
    {:no_node_capacity,
     %{
       task_id: "bd-1",
       node: nil,
       image_key: @image_key,
       phrase: @pending_phrase,
       message: "held — #{@pending_phrase}"
     }}
  end

  # Two Ready cards; the board promotes the first one not under a dispatch hold,
  # as `Arbiter.Board.Snapshot` does with `:dispatch_holds`.
  defp snapshot(test) do
    fn opts ->
      holds = Keyword.get(opts, :dispatch_holds, %{})
      send(test, {:holds, holds})

      promote = Enum.find(["bd-1", "bd-2"], &(not Map.has_key?(holds, &1)))

      %{
        ready:
          for(
            id <- ["bd-1", "bd-2"],
            do: %{id: id, state: :next, reason: "next", card: %{id: id}}
          ),
        backlog: [],
        blocked: [],
        in_progress: [],
        merging: [],
        verifying: [],
        closed_today: [],
        attention: [],
        promote: promote,
        slots_total: 4,
        slots_free: 4,
        quota: :ok,
        paused: false,
        now: DateTime.utc_now()
      }
    end
  end

  defp start(dispatch) do
    test = self()
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)

    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        interval_ms: :never,
        debounce_ms: 60_000,
        topics: [],
        follow_up: false,
        paused: false,
        registry_settled?: fn -> true end,
        now: fn -> Agent.get(clock, & &1) end,
        escalate: fn id, reason, attempts -> send(test, {:escalated, id, reason, attempts}) end,
        snapshot: snapshot(test),
        dispatch: dispatch
      )

    pid
  end

  defp dispatching(outcomes) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> outcomes end)

    fn id ->
      send(test, {:dispatch_attempt, id})

      Agent.get_and_update(agent, fn
        %{^id => [outcome | rest]} = all -> {outcome, Map.put(all, id, rest)}
        %{^id => []} = all -> {{:ok, %{task_id: id}}, all}
        all -> {{:ok, %{task_id: id}}, all}
      end)
    end
  end

  # A held refusal sends the board straight on to the next candidate, so the
  # other card dispatches on its own; wait for that pass to finish.
  defp settle(pid, tries \\ 200) do
    case Autopilot.status(pid) do
      %{dispatching: nil} ->
        :ok

      _ when tries > 0 ->
        _ = :sys.get_state(pid)
        Process.sleep(2)
        settle(pid, tries - 1)

      _ ->
        flunk("autopilot never returned to idle")
    end
  end

  describe "while the image is publishing" do
    test "the card is held with a hold_reason naming the image, the slot is free, other work dispatches" do
      pid = start(dispatching(%{"bd-1" => [{:error, pending_hold()}]}))

      assert {:error, {:no_node_capacity, %{image_key: @image_key}}} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}

      # The wait does not pin the promotion slot: the board goes straight on to
      # the other Ready card, with the hold handed to it as the card's hold_reason.
      assert_receive {:dispatch_attempt, "bd-2"}
      settle(pid)
      assert %{dispatching: nil} = Autopilot.status(pid)

      assert_received {:holds, %{"bd-1" => {:hold, hold_reason}}}
      assert hold_reason =~ "waiting for registry image"
      assert hold_reason =~ "vstim"
      refute_received {:escalated, _, _, _}
      refute_received {:dispatch_attempt, "bd-1"}
    end

    test "the publish completing releases the hold without operator action" do
      pid = start(dispatching(%{"bd-1" => [{:error, pending_hold()}]}))

      assert {:error, {:no_node_capacity, _}} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
      assert_receive {:dispatch_attempt, "bd-2"}
      settle(pid)

      # Still inside its retry window (the clock has not moved): bd-1 stays held.
      assert {:ok, "bd-2"} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-2"}
      settle(pid)
      refute_received {:dispatch_attempt, "bd-1"}

      # The publisher tells the board the image settled.
      send(pid, {:image_settled, @image_key})
      _ = :sys.get_state(pid)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
    end

    test "a completion for some other image leaves the hold in place" do
      pid = start(dispatching(%{"bd-1" => [{:error, pending_hold()}]}))

      assert {:error, {:no_node_capacity, _}} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
      assert_receive {:dispatch_attempt, "bd-2"}
      settle(pid)

      send(pid, {:image_settled, {:image, "other", :zzz}})
      _ = :sys.get_state(pid)

      assert {:ok, "bd-2"} = Autopilot.tick(pid)
      settle(pid)
      refute_received {:dispatch_attempt, "bd-1"}
    end

    test "image_notifier/1 tells the autopilot which image settled" do
      notify = Autopilot.image_notifier(self())
      notify.(@image_key, {:ok, %{ref: "r"}})
      assert_receive {:image_settled, @image_key}
    end
  end

  describe "when the publish fails" do
    test "the card keeps a clear hold_reason and the first attempt does not escalate" do
      failed =
        {:no_node_capacity,
         %{
           task_id: "bd-1",
           node: nil,
           image_error: {:push_failed, "r", 1, "denied"},
           phrase: "the registry image is not available ({:push_failed, \"r\", 1, \"denied\"})",
           message: "held — the registry image for bd-1 is not available"
         }}

      pid = start(dispatching(%{"bd-1" => [{:error, failed}]}))

      assert {:error, ^failed} = Autopilot.tick(pid)
      assert_receive {:dispatch_attempt, "bd-1"}
      assert_receive {:dispatch_attempt, "bd-2"}
      settle(pid)

      assert_received {:holds, %{"bd-1" => {:hold, hold_reason}}}
      assert hold_reason =~ "registry image is not available"
      assert hold_reason =~ "denied"
      refute_received {:escalated, _, _, _}
    end
  end
end
