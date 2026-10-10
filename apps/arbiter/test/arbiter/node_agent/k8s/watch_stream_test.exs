defmodule Arbiter.NodeAgent.K8s.WatchStreamTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.WatchStream

  defp line(type, object), do: Jason.encode!(%{"type" => type, "object" => object}) <> "\n"
  defp pod(name, rv), do: %{"metadata" => %{"name" => name, "resourceVersion" => rv}}

  test "decodes one event per newline-terminated line" do
    data =
      line("ADDED", pod("a", "1")) <>
        line("MODIFIED", pod("a", "2")) <> line("DELETED", pod("a", "3"))

    {events, stream} = WatchStream.feed(WatchStream.new(), data)

    assert [{:added, %{"metadata" => %{"resourceVersion" => "1"}}}, {:modified, _}, {:deleted, _}] =
             events

    assert WatchStream.pending(stream) == ""
  end

  test "an event split across chunks (even mid-UTF-8) is decoded once, when its line completes" do
    full = line("ADDED", pod("ünï", "7"))
    mid = div(byte_size(full), 2)
    <<head::binary-size(^mid), tail::binary>> = full

    {[], stream} = WatchStream.feed(WatchStream.new(), head)
    assert WatchStream.pending(stream) == head
    {[{:added, obj}], stream} = WatchStream.feed(stream, tail)
    assert obj["metadata"]["name"] == "ünï"
    assert WatchStream.pending(stream) == ""
  end

  test "several events in one chunk plus the start of the next" do
    next = line("MODIFIED", pod("b", "9"))
    <<next_head::binary-size(5), _::binary>> = next

    {events, stream} =
      WatchStream.feed(
        WatchStream.new(),
        line("ADDED", pod("a", "1")) <> line("ADDED", pod("b", "2")) <> next_head
      )

    assert length(events) == 2
    assert WatchStream.pending(stream) == next_head
  end

  test "BOOKMARK and ERROR are first-class" do
    data =
      line("BOOKMARK", %{"kind" => "Pod", "metadata" => %{"resourceVersion" => "42"}}) <>
        line("ERROR", %{
          "kind" => "Status",
          "code" => 410,
          "reason" => "Expired",
          "message" => "too old"
        })

    {[bookmark, error], _} = WatchStream.feed(WatchStream.new(), data)
    assert {:bookmark, %{"metadata" => %{"resourceVersion" => "42"}}} = bookmark
    assert {:error, %{"code" => 410, "reason" => "Expired"}} = error
  end

  test "blank lines are skipped; a line that is not JSON is a bad_event" do
    {events, _} =
      WatchStream.feed(WatchStream.new(), "\n" <> line("ADDED", pod("a", "1")) <> "not json\n")

    assert [{:added, _}, {:bad_event, "not json"}] = events
  end

  test "an unknown event type is a bad_event, not a crash" do
    {[event], _} = WatchStream.feed(WatchStream.new(), line("WHATEVER", pod("a", "1")))
    assert {:bad_event, _} = event
  end
end
