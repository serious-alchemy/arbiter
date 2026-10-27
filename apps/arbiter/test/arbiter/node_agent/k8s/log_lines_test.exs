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

  describe "numeric-offset timestamps (mesaana's kubelet stamps -04:00)" do
    @off "2026-10-27T11:14:41.173636866-04:00"
    @json ~s({"type":"assistant","message":{"content":[]}})

    test "the stamp is stripped and the cursor round-trips through since_time" do
      {_acc, lines} = feed(LogLines.new(nil), "#{@off} #{@json}\n")
      assert lines == [{"#{@off} 1", @json <> "\n"}]

      since = LogLines.since_time("#{@off} 1")
      assert LogLines.parse_ts(since) == LogLines.parse_ts("2026-10-27T15:14:41.173636866Z")

      {_acc, lines} = feed(LogLines.new("#{@off} 1"), "#{@off} #{@json}\n#{@off} next\n")
      assert lines == [{"#{@off} 2", "next\n"}]
    end

    test "an offset stamp and the same instant in UTC compare equal" do
      assert LogLines.parse_ts("2026-10-27T11:14:41-04:00") ==
               LogLines.parse_ts("2026-10-27T15:14:41Z")

      assert LogLines.parse_ts("2026-10-27T11:14:41+05:30") ==
               LogLines.parse_ts("2026-10-27T05:44:41Z")
    end

    test "a record-splice stamp with an offset is removed from a long line" do
      line = String.duplicate("x", 4096)
      tail = String.duplicate("y", 10)
      spliced = line <> "2026-10-27T11:14:41.173636866-04:00 " <> tail
      {_acc, lines} = feed(LogLines.new(nil), "#{@off} #{spliced}\n")
      assert [{_, text}] = lines
      assert text == line <> tail <> "\n"
    end
  end

  test "since_time is the cursor's timestamp" do
    assert LogLines.since_time("#{@ts1} 3") == @ts1
    assert LogLines.since_time(nil) == nil
  end

  describe "a line the runtime cut into partial records" do
    @ts3 "2026-10-10T12:00:00.000000003Z"

    test "drops the timestamps a kubelet stamps into the middle of it" do
      a = String.duplicate("a", 16_384)
      b = String.duplicate("b", 16_384)
      {_acc, lines} = feed(LogLines.new(nil), "#{@ts1} #{a}#{@ts2} #{b}#{@ts3} tail arb done\n")
      assert lines == [{"#{@ts1} 1", a <> b <> "tail arb done\n"}]
    end

    test "also at an 8 KiB record size, with the body arriving in several chunks" do
      a = String.duplicate("a", 8_192)
      raw = "#{@ts1} #{a}#{@ts2} #{a}#{@ts3} end\n"
      {acc, []} = feed(LogLines.new(nil), binary_part(raw, 0, 10_000))
      {_acc, lines} = feed(acc, binary_part(raw, 10_000, byte_size(raw) - 10_000))
      assert lines == [{"#{@ts1} 1", a <> a <> "end\n"}]
    end

    test "leaves a timestamp-looking string that is not at a record boundary alone" do
      text = String.duplicate("a", 100) <> "#{@ts2} kept"
      {_acc, lines} = feed(LogLines.new(nil), "#{@ts1} #{text}\n")
      assert lines == [{"#{@ts1} 1", text <> "\n"}]
    end

    test "leaves a boundary timestamp that is earlier than the line's own alone" do
      text = String.duplicate("a", 4_096) <> "#{@ts1} kept"
      {_acc, lines} = feed(LogLines.new(nil), "#{@ts2} #{text}\n")
      assert lines == [{"#{@ts2} 1", text <> "\n"}]
    end
  end
end
