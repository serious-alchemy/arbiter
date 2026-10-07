defmodule Arbiter.Nodes.Bridge.CoreTest do
  @moduledoc """
  Two `Core`s wired back to back, each end's consumer under the test's control:
  the flow-control properties of `docs/design/remote-workers.md` §4.2/§8 with no
  sockets, no clock and no channel.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Bridge.{Core, Frame}

  @limits %{
    window: 64,
    frame: 16,
    node_cap: 64,
    max_streams_per_run: 3,
    max_streams_per_node: 5,
    max_stream_bytes: 10_000,
    max_node_bytes: 100_000
  }

  # `a` is the agent end, `b` the primary end. `pending[side][id]` is the bytes
  # a consumer has been handed and not yet written; `armed` the streams whose
  # local socket is being read; `log` the events that crossed the wire.
  defp sim(limits \\ %{}) do
    %{
      a: Core.new(Map.merge(@limits, limits)),
      b: Core.new(Map.merge(@limits, limits)),
      pending: %{a: %{}, b: %{}},
      written: %{a: %{}, b: %{}},
      armed: %{a: MapSet.new(), b: MapSet.new()},
      stopped: %{a: MapSet.new(), b: MapSet.new()},
      shut: %{a: MapSet.new(), b: MapSet.new()},
      log: []
    }
  end

  defp other(:a), do: :b
  defp other(:b), do: :a

  # run `fun` on one end's core, then carry out its effects (and theirs)
  defp on(sim, side, fun) do
    {core, effects} =
      case fun.(Map.fetch!(sim, side)) do
        {:ok, core, effects} -> {core, effects}
        {core, effects} -> {core, effects}
      end

    perform(Map.put(sim, side, core), side, effects)
  end

  defp perform(sim, side, effects) do
    Enum.reduce(effects, sim, fn
      {:push, event, payload}, sim ->
        sim = %{sim | log: [{side, event, payload} | sim.log]}
        {event, payload} = {event, payload}
        on(sim, other(side), &Core.remote(&1, event, payload))

      {:stream, id, :write, bytes}, sim ->
        update_in(sim.pending[side], &Map.update(&1, id, bytes, fn b -> b <> bytes end))

      {:stream, id, :rearm}, sim ->
        update_in(sim.armed[side], &MapSet.put(&1, id))

      {:stream, id, :stop}, sim ->
        update_in(sim.stopped[side], &MapSet.put(&1, id))

      {:stream, id, :shutdown_write}, sim ->
        update_in(sim.shut[side], &MapSet.put(&1, id))
    end)
  end

  defp open(sim, id, run \\ "r1", name \\ "proxy") do
    sim
    |> on(:a, &Core.open_local(&1, id, run, name))
    |> on(:b, &Core.open_remote(&1, id, run, name))
    |> then(fn sim -> update_in(sim.armed, fn a -> %{a | a: MapSet.put(a.a, id), b: MapSet.put(a.b, id)} end) end)
  end

  # the producer on `side` reads `bytes` from its local socket
  defp produce(sim, side, id, bytes) do
    sim = update_in(sim.armed[side], &MapSet.delete(&1, id))
    on(sim, side, &Core.local_data(&1, id, bytes))
  end

  # the consumer on `side` writes everything it was handed for `id`
  defp consume(sim, side, id) do
    bytes = Map.get(sim.pending[side], id, "")
    sim = update_in(sim.pending[side], &Map.delete(&1, id))
    sim = update_in(sim.written[side], &Map.update(&1, id, bytes, fn w -> w <> bytes end))
    if bytes == "", do: sim, else: on(sim, side, &Core.local_wrote(&1, id, byte_size(bytes)))
  end

  defp handed(sim, side, id), do: byte_size(Map.get(sim.pending[side], id, ""))
  defp events(sim, name), do: for({_, ^name, p} <- Enum.reverse(sim.log), do: p)

  describe "opening" do
    test "the opener announces; the other end registers" do
      sim = sim() |> open(1, "r1", "arb")
      assert [%{"run" => "r1", "name" => "arb", "stream" => 1}] = events(sim, "bridge.open")
      assert Core.stream?(sim.a, 1) and Core.stream?(sim.b, 1)
    end

    test "a stream id is used once" do
      sim = sim() |> open(1)
      assert {:error, :duplicate_stream} = Core.open_remote(sim.b, 1, "r1", "proxy")
      assert {:error, :duplicate_stream} = Core.open_local(sim.a, 1, "r1", "proxy")
      assert {:error, :bad_stream} = Core.open_remote(sim.b, 0, "r1", "proxy")
      assert {:error, :bad_stream} = Core.open_remote(sim.b, "1", "r1", "proxy")
    end

    test "streams per run and per node are capped, and a close frees the slot" do
      sim = sim() |> open(1) |> open(2) |> open(3)
      assert {:error, :run_stream_cap} = Core.open_remote(sim.b, 4, "r1", "proxy")
      assert {:error, :run_stream_cap} = Core.open_local(sim.a, 4, "r1", "proxy")

      sim = sim |> open(4, "r2") |> open(5, "r2")
      assert {:error, :node_stream_cap} = Core.open_remote(sim.b, 6, "r3", "proxy")

      sim = on(sim, :a, &Core.reset(&1, 1, :test))
      assert {:ok, _, _} = Core.open_remote(sim.b, 6, "r3", "proxy")
    end
  end

  describe "data" do
    test "arrives in order and is credited once the consumer has written it" do
      sim = sim() |> open(1) |> produce(:a, 1, "hello world")
      assert handed(sim, :b, 1) == 11
      # nothing is credited until the consumer wrote
      assert events(sim, "bridge.credit") == []
      # …but the transport acknowledged receipt at once
      assert [%{"n" => 11}] = events(sim, "bridge.recv")

      sim = consume(sim, :b, 1)
      assert sim.written.b[1] == "hello world"
      assert [%{"stream" => 1, "n" => 11}] = events(sim, "bridge.credit")
      assert MapSet.member?(sim.armed.a, 1)
    end

    test "a producer with more than a window is held until the consumer drains" do
      sim = sim() |> open(1) |> produce(:a, 1, String.duplicate("x", 200))
      # one window crossed (64), the rest is buffered, the producer is not re-armed
      assert handed(sim, :b, 1) == 64
      refute MapSet.member?(sim.armed.a, 1)

      sim = consume(sim, :b, 1)
      assert handed(sim, :b, 1) == 64
      sim = sim |> consume(:b, 1) |> consume(:b, 1) |> consume(:b, 1)
      assert sim.written.b[1] == String.duplicate("x", 200)
      assert MapSet.member?(sim.armed.a, 1)
    end

    test "a slow consumer stalls only its own stream" do
      sim = sim() |> open(1) |> open(2)
      # stream 1's consumer never writes
      sim = produce(sim, :a, 1, String.duplicate("s", 1_000))
      assert handed(sim, :b, 1) == 64

      # the link is not held by it: stream 2 goes through, both ways
      sim = produce(sim, :a, 2, "fast")
      assert handed(sim, :b, 2) == 4
      sim = consume(sim, :b, 2)
      assert sim.written.b[2] == "fast"

      sim = produce(sim, :b, 2, "back")
      assert handed(sim, :a, 2) == 4

      # and the in-flight count is back to zero for the whole node
      assert Core.inflight(sim.a) == 0
    end

    test "frames for a stream that is gone are still acknowledged to the transport" do
      sim = sim() |> open(1)
      frame = Frame.encode(0, 99, "orphan")
      {b, effects} = Core.remote(sim.b, "bridge.data", {:binary, frame})
      assert {:push, "bridge.recv", %{"n" => 6}} in effects
      refute Enum.any?(effects, &match?({:stream, _, _}, &1))
      assert b
    end
  end

  describe "a peer that does not follow the protocol" do
    setup do: %{sim: sim() |> open(1)}

    test "a frame past the stream window resets the stream", %{sim: sim} do
      {b, effects} = Core.remote(sim.b, "bridge.data", {:binary, Frame.encode(0, 1, String.duplicate("x", 16))})
      refute Enum.any?(effects, &match?({:push, "bridge.reset", _}, &1))

      {b, _} = Core.remote(b, "bridge.data", {:binary, Frame.encode(1, 1, String.duplicate("x", 16))})
      {b, _} = Core.remote(b, "bridge.data", {:binary, Frame.encode(2, 1, String.duplicate("x", 16))})
      {b, _} = Core.remote(b, "bridge.data", {:binary, Frame.encode(3, 1, String.duplicate("x", 16))})
      # 64 unwritten: the fifth frame is one too many
      {b, effects} = Core.remote(b, "bridge.data", {:binary, Frame.encode(4, 1, "x")})
      assert {:push, "bridge.reset", %{"stream" => 1, "reason" => "window_exceeded"}} in effects
      assert {:stream, 1, :stop} in effects
      refute Core.stream?(b, 1)
    end

    test "an oversized frame resets the stream", %{sim: sim} do
      {_b, effects} = Core.remote(sim.b, "bridge.data", {:binary, Frame.encode(0, 1, String.duplicate("x", 17))})
      assert {:push, "bridge.reset", %{"stream" => 1, "reason" => "frame_too_large"}} in effects
    end

    test "a sequence gap resets the stream", %{sim: sim} do
      {_b, effects} = Core.remote(sim.b, "bridge.data", {:binary, Frame.encode(5, 1, "x")})
      assert {:push, "bridge.reset", %{"stream" => 1, "reason" => "bad_sequence"}} in effects
    end

    test "something that is not a frame is a violation of the whole channel", %{sim: sim} do
      assert {_, [{:violation, :bad_frame}]} = Core.remote(sim.b, "bridge.data", {:binary, "garbage"})
    end

    test "a stream past its lifetime byte cap is reset", %{sim: sim} do
      sim = %{sim | b: Core.new(Map.merge(@limits, %{max_stream_bytes: 20}))}
      sim = on(sim, :b, &Core.open_remote(&1, 1, "r1", "proxy"))
      {b, e1} = Core.remote(sim.b, "bridge.data", {:binary, Frame.encode(0, 1, String.duplicate("x", 16))})
      refute Enum.any?(e1, &match?({:push, "bridge.reset", _}, &1))
      {_b, e2} = Core.remote(b, "bridge.data", {:binary, Frame.encode(1, 1, String.duplicate("x", 16))})
      assert {:push, "bridge.reset", %{"stream" => 1, "reason" => "stream_byte_cap"}} in e2
    end

    test "credit that is not a positive integer is ignored", %{sim: sim} do
      assert {_, []} = Core.remote(sim.a, "bridge.credit", %{"stream" => 1, "n" => -5})
      assert {_, []} = Core.remote(sim.a, "bridge.credit", %{"stream" => 1, "n" => "x"})
      assert {_, []} = Core.remote(sim.a, "bridge.recv", %{"n" => "x"})
    end
  end

  describe "the per-node byte cap" do
    test "resets a stream that crosses it, and refuses new streams once it is reached" do
      sim = sim(%{max_node_bytes: 20}) |> open(1)
      sim = produce(sim, :a, 1, String.duplicate("x", 16))
      {_a, effects} = Core.local_data(sim.a, 1, String.duplicate("y", 16))
      assert {:push, "bridge.reset", %{"stream" => 1, "reason" => "node_byte_cap"}} in effects

      sim = produce(sim, :a, 1, "four")
      assert {:error, :node_byte_cap} = Core.open_local(sim.a, 2, "r1", "proxy")
      assert {:error, :node_byte_cap} = Core.open_remote(sim.b, 2, "r1", "proxy")
    end
  end

  describe "closing" do
    test "a half close is delivered after the data, and a stream closed both ways is gone" do
      sim = sim() |> open(1) |> produce(:a, 1, "bye")
      sim = on(sim, :a, &Core.local_eof(&1, 1))
      assert MapSet.member?(sim.shut.b, 1)
      assert Core.stream?(sim.a, 1)

      sim = on(sim, :b, &Core.local_eof(&1, 1))
      assert MapSet.member?(sim.shut.a, 1)
      refute Core.stream?(sim.a, 1)
      refute Core.stream?(sim.b, 1)
      assert MapSet.member?(sim.stopped.a, 1) and MapSet.member?(sim.stopped.b, 1)
    end

    test "a reset ends the stream on both sides at once" do
      sim = sim() |> open(1) |> produce(:a, 1, String.duplicate("x", 200))
      sim = on(sim, :b, &Core.reset(&1, 1, :consumer_gone))
      refute Core.stream?(sim.a, 1)
      refute Core.stream?(sim.b, 1)
      assert MapSet.member?(sim.stopped.a, 1)
    end
  end
end
