defmodule Arbiter.NodeAgent.StdoutBufferTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.StdoutBuffer, as: Buf
  alias Arbiter.Nodes.StdoutFrame

  defp fill(chunks), do: Enum.reduce(chunks, Buf.new(), fn c, b -> elem(Buf.append(b, c), 1) end)
  defp bytes({:ok, chunks}), do: chunks |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()

  test "append assigns consecutive offsets" do
    {:ok, b, 0} = Buf.append(Buf.new(), "abc")
    {:ok, b, 3} = Buf.append(b, "de")
    assert Buf.size(b) == 5
    assert Buf.pending(b) == 5
  end

  test "from/2 replays everything after the last ack, across chunk boundaries" do
    b = fill(["abc", "def", "ghi"])
    assert bytes(Buf.from(b, 0)) == "abcdefghi"
    assert Buf.from(b, 4) == {:ok, [{4, "ef"}, {6, "ghi"}]}

    b = Buf.ack(b, 4)
    assert Buf.acked(b) == 4
    assert bytes(Buf.from(b, 4)) == "efghi"
    assert Buf.pending(b) == 5
  end

  test "an ack never moves backwards and is clamped to what exists" do
    b = fill(["abcdef"]) |> Buf.ack(4) |> Buf.ack(2)
    assert Buf.acked(b) == 4
    assert Buf.ack(b, 999) |> Buf.pending() == 0
  end

  test "asking for bytes already acknowledged is :gone" do
    b = fill(["abcdef"]) |> Buf.ack(4)
    assert Buf.from(b, 1) == {:error, :gone}
  end

  test "an unacknowledged overflow is refused, never silently dropped" do
    b = Buf.new(8)
    {:ok, b, 0} = Buf.append(b, "12345")
    assert Buf.append(b, "6789") == {:error, :overflow}
    # an ack frees room
    assert {:ok, _b, 5} = b |> Buf.ack(5) |> Buf.append("6789")
  end

  describe "StdoutFrame" do
    test "round trips and never touches the payload" do
      payload = <<0, 255, 10, 13, 0xE2, 0x82>>
      frame = StdoutFrame.encode("run-1", 70_000, payload)
      assert {:ok, "run-1", 70_000, ^payload} = StdoutFrame.decode(frame)
    end

    test "rejects anything else" do
      assert StdoutFrame.decode("nope") == {:error, :bad_frame}
      assert StdoutFrame.decode(<<"ARB1", 0::64, 0::8>>) == {:error, :bad_frame}
    end
  end
end
