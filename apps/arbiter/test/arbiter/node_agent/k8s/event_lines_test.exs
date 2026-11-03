defmodule Arbiter.NodeAgent.K8s.EventLinesTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.EventLines

  test "complete lines come out with the byte offset after each as the cursor" do
    {r, out} = EventLines.new(nil) |> EventLines.feed(0, "ab\ncde\n")
    assert out == {:ok, [{"e3", "ab\n"}, {"e7", "cde\n"}]}
    assert EventLines.next(r) == 7
  end

  test "a line split across chunks is held until its newline arrives" do
    {r, {:ok, []}} = EventLines.new(nil) |> EventLines.feed(0, "ab")
    assert EventLines.next(r) == 2
    {r, {:ok, lines}} = EventLines.feed(r, 2, "c\nd")
    assert lines == [{"e4", "abc\n"}]
    assert EventLines.next(r) == 5
  end

  test "bytes already taken (a retried chunk) are skipped, not repeated" do
    {r, _} = EventLines.new(nil) |> EventLines.feed(0, "ab\ncd")
    {r, {:ok, lines}} = EventLines.feed(r, 0, "ab\ncd\nef\n")
    assert lines == [{"e6", "cd\n"}, {"e9", "ef\n"}]
    assert EventLines.next(r) == 9
  end

  test "a chunk entirely behind the position changes nothing" do
    {r, _} = EventLines.new(nil) |> EventLines.feed(0, "ab\n")
    assert {^r, {:ok, []}} = EventLines.feed(r, 0, "ab")
  end

  test "a chunk that starts past the position is a gap and is not taken" do
    {r, _} = EventLines.new(nil) |> EventLines.feed(0, "ab\n")
    assert {^r, {:gap, 3}} = EventLines.feed(r, 10, "zz\n")
  end

  test "resuming from a cursor starts at its offset" do
    r = EventLines.new("e3")
    assert EventLines.next(r) == 3
    {_, {:ok, lines}} = EventLines.feed(r, 3, "cd\n")
    assert lines == [{"e6", "cd\n"}]
  end

  test "a garbled cursor resumes from the start" do
    assert EventLines.next(EventLines.new("junk")) == 0
    assert EventLines.next(EventLines.new(nil)) == 0
  end

  test "finish drops a partial final line and reports it as truncated" do
    {r, _} = EventLines.new(nil) |> EventLines.feed(0, "ab\n{\"type\":\"res")
    assert EventLines.finish(r) == {:truncated, 12}
  end

  test "finish of a clean stream is :complete" do
    {r, _} = EventLines.new(nil) |> EventLines.feed(0, "ab\n")
    assert EventLines.finish(r) == :complete
  end
end
