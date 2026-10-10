defmodule Arbiter.Nodes.StdoutFrameTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.StdoutFrame

  test "an ARB1 frame round-trips its integer offset (machine nodes, unchanged)" do
    frame = StdoutFrame.encode("run-1", 4096, "hello\n")
    assert {:ok, "run-1", 4096, "hello\n"} = StdoutFrame.decode(frame)
    assert binary_part(frame, 0, 4) == "ARB1"
  end

  test "an ARB2 frame carries an opaque cursor string, uninterpreted (A4)" do
    cursor = "2026-10-06T10:11:12.123456789Z"
    frame = StdoutFrame.encode_cursor("run-1", cursor, "line\n")
    assert binary_part(frame, 0, 4) == "ARB2"
    assert {:ok, "run-1", {:cursor, ^cursor}, "line\n"} = StdoutFrame.decode(frame)
  end

  test "an ARB2 cursor may be empty bytes and need not look like anything" do
    frame = StdoutFrame.encode_cursor("r", "any opaque \x00 value", "")
    assert {:ok, "r", {:cursor, "any opaque \x00 value"}, ""} = StdoutFrame.decode(frame)
  end

  test "a truncated or foreign frame is a bad frame" do
    assert {:error, :bad_frame} = StdoutFrame.decode("ARB2")
    assert {:error, :bad_frame} = StdoutFrame.decode(<<"ARB2", 0, 5, "ab">>)
    assert {:error, :bad_frame} = StdoutFrame.decode("nope")
  end
end
