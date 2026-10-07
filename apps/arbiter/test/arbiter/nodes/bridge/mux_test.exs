defmodule Arbiter.Nodes.Bridge.MuxTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Bridge.{Frame, Mux}

  defp frames(actions), do: for({:frame, id, bin} <- actions, do: {id, Frame.decode!(bin)})

  defp new(opts \\ []),
    do:
      Mux.new(
        Keyword.merge([window: 64, frame: 16, node_cap: 1_000, max_stream_bytes: 10_000], opts)
      )

  defp open(mux, ids), do: Enum.reduce(ids, mux, &Mux.open_stream(&2, &1))

  describe "Frame" do
    test "round trips and rejects anything that is not a bridge frame" do
      bin = Frame.encode(7, 3, "hello")
      assert {:ok, %{seq: 7, stream: 3, bytes: "hello"}} = Frame.decode(bin)
      assert Frame.decode!(bin).bytes == "hello"
      assert :error = Frame.decode(<<"NOPE", 0::64, 1::32, "x">>)
      assert :error = Frame.decode("short")
      assert :error = Frame.decode(Frame.encode(0, 1, ""))
    end
  end

  describe "local data" do
    test "is cut into frames no larger than the frame size, numbered per stream" do
      {mux, actions} = new() |> open([1]) |> Mux.local_data(1, String.duplicate("a", 40))

      assert [{1, %{seq: 0, bytes: b0}}, {1, %{seq: 1, bytes: b1}}, {1, %{seq: 2, bytes: b2}}] =
               frames(actions)

      assert {byte_size(b0), byte_size(b1), byte_size(b2)} == {16, 16, 8}
      assert {:rearm, 1} in actions
      assert Mux.buffered(mux) == 0
    end

    test "stops at the stream window and resumes when credit comes back" do
      {mux, actions} = new() |> open([1]) |> Mux.local_data(1, String.duplicate("a", 100))

      assert actions |> frames() |> Enum.map(fn {_, f} -> byte_size(f.bytes) end) |> Enum.sum() ==
               64

      refute {:rearm, 1} in actions
      assert Mux.buffered(mux) == 36

      # the peer wrote 32 of them to its socket
      {mux, actions} = Mux.credit(mux, 1, 32)

      assert actions |> frames() |> Enum.map(fn {_, f} -> byte_size(f.bytes) end) |> Enum.sum() ==
               32

      assert Mux.buffered(mux) == 4
      refute {:rearm, 1} in actions
    end

    test "unknown streams are ignored" do
      assert {_, []} = Mux.local_data(new(), 9, "x")
      assert {_, []} = Mux.credit(new(), 9, 5)
    end
  end

  describe "the node-wide in-flight cap" do
    test "is shared by every stream and released by received/2, not by credit" do
      mux = new(node_cap: 32) |> open([1, 2])
      {mux, a} = Mux.local_data(mux, 1, String.duplicate("a", 16))
      {mux, b} = Mux.local_data(mux, 2, String.duplicate("b", 32))
      # 16 from stream 1, 16 of stream 2's 32: the cap is full
      assert length(frames(a)) == 1
      assert length(frames(b)) == 1
      assert Mux.buffered(mux) == 16

      # the peer's *application* acknowledging (credit) does not free the link
      {mux, actions} = Mux.credit(mux, 1, 16)
      assert frames(actions) == []

      # the peer's *transport* having received them does
      {mux, actions} = Mux.received(mux, 16)
      assert [{2, %{bytes: bytes}}] = frames(actions)
      assert byte_size(bytes) == 16
      assert Mux.buffered(mux) == 0
    end

    test "schedules fairly: streams with data take turns" do
      mux = new(node_cap: 16, window: 1_000) |> open([1, 2, 3])
      {mux, _} = Mux.local_data(mux, 1, String.duplicate("a", 48))
      {mux, _} = Mux.local_data(mux, 2, String.duplicate("b", 48))
      {mux, _} = Mux.local_data(mux, 3, String.duplicate("c", 48))

      {order, _mux} =
        Enum.reduce(1..8, {[], mux}, fn _, {acc, m} ->
          {m, actions} = Mux.received(m, 16)
          {acc ++ Enum.map(frames(actions), &elem(&1, 0)), m}
        end)

      # 1 sent its first frame alone (when its data arrived); then the three rotate
      assert Enum.take(order, 6) == [1, 2, 3, 1, 2, 3]
    end
  end

  describe "a slow consumer" do
    test "holds only its own window: another stream keeps moving" do
      mux = new(window: 32, node_cap: 64) |> open([1, 2])
      # stream 1's peer never writes (never credits)
      {mux, a} = Mux.local_data(mux, 1, String.duplicate("a", 500))
      assert a |> frames() |> Enum.map(fn {_, f} -> byte_size(f.bytes) end) |> Enum.sum() == 32

      # the link delivered them; the node's in-flight cap is free again
      {mux, _} = Mux.received(mux, 32)

      # stream 2 is not stalled by stream 1's 468 buffered bytes
      {mux, b} = Mux.local_data(mux, 2, String.duplicate("b", 30))

      assert b |> frames() |> Enum.map(fn {id, f} -> {id, byte_size(f.bytes)} end) == [
               {2, 16},
               {2, 14}
             ]

      assert {:rearm, 2} in b
      refute {:rearm, 1} in b
      assert Mux.buffered(mux) == 468
    end
  end

  describe "close and caps" do
    test "a close is emitted only after the stream's buffer is on the wire" do
      mux = new(window: 16) |> open([1])
      {mux, _} = Mux.local_data(mux, 1, String.duplicate("a", 20))
      {mux, actions} = Mux.local_closed(mux, 1)
      refute {:close, 1} in actions

      {_mux, actions} = Mux.credit(mux, 1, 16)
      assert frames(actions) |> length() == 1
      assert List.last(actions) == {:close, 1}
    end

    test "an empty stream closes at once, and only once" do
      {mux, actions} = new() |> open([1]) |> Mux.local_closed(1)
      assert actions == [{:close, 1}]
      assert {_, []} = Mux.local_closed(mux, 1)
    end

    test "a stream past its lifetime byte cap is reset" do
      mux = new(max_stream_bytes: 40, window: 1_000) |> open([1])
      {mux, a} = Mux.local_data(mux, 1, String.duplicate("a", 30))
      assert length(frames(a)) == 2
      {_mux, b} = Mux.local_data(mux, 1, String.duplicate("a", 30))
      assert {:reset, 1, :stream_byte_cap} in b
    end

    test "drop_stream discards what is buffered" do
      mux = new(window: 16) |> open([1])
      {mux, _} = Mux.local_data(mux, 1, String.duplicate("a", 40))
      assert Mux.buffered(mux) == 24
      mux = Mux.drop_stream(mux, 1)
      assert Mux.buffered(mux) == 0
    end
  end
end
