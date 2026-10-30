defmodule Arbiter.TextTest do
  use ExUnit.Case, async: true

  alias Arbiter.Text

  describe "scrub/1" do
    test "replaces invalid bytes with U+FFFD and keeps valid text" do
      assert Text.scrub(<<"ab", 0xB1, "cd">>) == "ab�cd"
      assert Text.scrub("±60 ok") == "±60 ok"
      assert String.valid?(Text.scrub(<<0xE2, 0x94>>))
    end

    test "passes nil through" do
      assert Text.scrub(nil) == nil
    end
  end

  describe "tail_bytes/2" do
    test "cut landing mid-± drops the partial codepoint" do
      text = "xx±yy"
      # last 3 bytes would be <<0xB1, ?y, ?y>>
      assert Text.tail_bytes(text, 3) == "yy"
      assert String.valid?(Text.tail_bytes(text, 3))
    end

    test "cut landing mid-box-drawing drops the partial codepoint" do
      text = "a" <> String.duplicate("─", 4) <> "z"

      for n <- 1..byte_size(text) do
        assert String.valid?(Text.tail_bytes(text, n))
        assert byte_size(Text.tail_bytes(text, n)) <= n
      end
    end

    test "short text is unchanged" do
      assert Text.tail_bytes("abc", 10) == "abc"
    end
  end

  describe "head_bytes/2" do
    test "cut landing mid-± drops the partial codepoint" do
      assert Text.head_bytes("xx±yy", 3) == "xx"
      assert Text.head_bytes("a─b", 3) == "a"
      assert Text.head_bytes("abc", 10) == "abc"
    end
  end
end
