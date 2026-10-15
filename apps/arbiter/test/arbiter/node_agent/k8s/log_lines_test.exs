defmodule Arbiter.NodeAgent.K8s.LogLinesTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.LogLines

  @ts1 "2026-10-10T12:00:00.000000001Z"
  @ts2 "2026-10-10T12:00:00.000000002Z"

  defp feed(acc, chunk) do
    {acc, lines} = LogLines.feed(acc, chunk)
    {acc, lines}
  end

  test "splits timestamped lines and names the cursor after each" do
    {_acc, lines} = feed(LogLines.new(nil), "#{@ts1} hello\n#{@ts2} world\n")
    assert lines == [{"#{@ts1} 1", "hello\n"}, {"#{@ts2} 1", "world\n"}]
  end

  test "holds a partial line across chunks" do
    {acc, lines} = feed(LogLines.new(nil), "#{@ts1} hel")
    assert lines == []
    {_acc, lines} = feed(acc, "lo\n")
    assert lines == [{"#{@ts1} 1", "hello\n"}]
  end

  test "lines with an equal timestamp get distinct cursors" do
    {_acc, lines} = feed(LogLines.new(nil), "#{@ts1} a\n#{@ts1} b\n")
    assert Enum.map(lines, &elem(&1, 0)) == ["#{@ts1} 1", "#{@ts1} 2"]
  end

  test "resuming from a cursor skips what was already taken, equal timestamps included" do
    log = "#{@ts1} a\n#{@ts1} b\n#{@ts2} c\n"
    {_acc, lines} = feed(LogLines.new("#{@ts1} 1"), log)
    assert lines == [{"#{@ts1} 2", "b\n"}, {"#{@ts2} 1", "c\n"}]

    {_acc, lines} = feed(LogLines.new("#{@ts1} 2"), log)
    assert lines == [{"#{@ts2} 1", "c\n"}]
  end

  test "a resume from a second-truncated replay still skips earlier lines" do
    early = "2026-10-10T11:59:59.5Z"
    {_acc, lines} = feed(LogLines.new("#{@ts1} 1"), "#{early} old\n#{@ts1} a\n#{@ts2} b\n")
    assert lines == [{"#{@ts2} 1", "b\n"}]
  end

  test "flush turns a trailing partial line into a final line" do
    {acc, [_done]} = feed(LogLines.new(nil), "#{@ts1} done\n#{@ts2} no newline")
    assert LogLines.flush(acc) == [{"#{@ts2} 1", "no newline\n"}]
  end

  test "a line without a parsable timestamp counts as one more line at the previous timestamp" do
    {_acc, lines} = feed(LogLines.new(nil), "#{@ts1} a\ngarbage\n")
    assert lines == [{"#{@ts1} 1", "a\n"}, {"#{@ts1} 2", "garbage\n"}]
  end

  test "since_time is the cursor's timestamp" do
    assert LogLines.since_time("#{@ts1} 3") == @ts1
    assert LogLines.since_time(nil) == nil
  end
end
