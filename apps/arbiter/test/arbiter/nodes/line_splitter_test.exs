defmodule Arbiter.Nodes.LineSplitterTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.LineSplitter, as: L

  test "whole lines" do
    assert {[{:eol, "a"}, {:eol, "bc"}], ""} = L.split("", "a\nbc\n")
  end

  test "a partial line is held across calls" do
    assert {[{:eol, "one"}], "tw"} = L.split("", "one\ntw")
    assert {[{:eol, "two"}, {:eol, "x"}], ""} = L.split("tw", "o\nx\n")
  end

  test "an empty line is a line" do
    assert {[{:eol, ""}, {:eol, "a"}], ""} = L.split("", "\na\n")
  end

  test "a line over max arrives as noeol pieces and then eol, like {:line, max}" do
    assert {[{:noeol, "abcd"}, {:noeol, "efgh"}, {:eol, "ij"}], ""} =
             L.split("", "abcdefghij\n", 4)

    assert {[{:noeol, "abcd"}], "ef"} = L.split("", "abcdef", 4)
    assert {[{:eol, "abcd"}], ""} = L.split("", "abcd\n", 4)
  end

  test "flush delivers what is held as noeol" do
    assert L.flush("tail") == [{:noeol, "tail"}]
    assert L.flush("") == []
  end

  test "the result is independent of how the bytes were chunked" do
    data = "alpha\nbeta\n" <> String.duplicate("z", 20) <> "\nlast"
    whole = L.split("", data, 8)

    {frames, partial} =
      data
      |> :binary.bin_to_list()
      |> Enum.chunk_every(3)
      |> Enum.reduce({[], ""}, fn chunk, {acc, held} ->
        {f, held} = L.split(held, :binary.list_to_bin(chunk), 8)
        {acc ++ f, held}
      end)

    assert {frames, partial} == whole
  end
end
