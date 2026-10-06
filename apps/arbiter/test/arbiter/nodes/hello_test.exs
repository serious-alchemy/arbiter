defmodule Arbiter.Nodes.HelloTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Hello

  describe "effective_max_workers/2 (RW8 operator amendment)" do
    test "with no override the node's own suggestion is the cap" do
      assert Hello.effective_max_workers(nil, %{"suggestion" => 4}) == 4
    end

    test "an override raises the cap above the suggestion" do
      assert Hello.effective_max_workers(8, %{"suggestion" => 4}) == 8
    end

    test "an override lowers the cap below the suggestion" do
      assert Hello.effective_max_workers(2, %{"suggestion" => 4}) == 2
    end

    test "a node-owner ceiling is a hard bound on an override" do
      assert Hello.effective_max_workers(8, %{"suggestion" => 4, "ceiling" => 3}) == 3
      assert Hello.effective_max_workers(2, %{"suggestion" => 4, "ceiling" => 3}) == 2
    end

    test "a ceiling below the suggestion bounds the default; one above leaves it alone" do
      assert Hello.effective_max_workers(nil, %{"suggestion" => 4, "ceiling" => 2}) == 2
      assert Hello.effective_max_workers(nil, %{"suggestion" => 2, "ceiling" => 6}) == 2
    end

    test "a ceiling with no suggestion and no override is the cap" do
      assert Hello.effective_max_workers(nil, %{"ceiling" => 5}) == 5
    end

    test "nothing known is nil" do
      assert Hello.effective_max_workers(nil, %{}) == nil
      assert Hello.effective_max_workers(nil, nil) == nil
    end
  end

  describe "cap_source/2" do
    test "names what decided the effective cap" do
      assert Hello.cap_source(nil, %{"suggestion" => 4}) == :suggestion
      assert Hello.cap_source(8, %{"suggestion" => 4}) == :override
      assert Hello.cap_source(8, %{"suggestion" => 4, "ceiling" => 3}) == :ceiling
      assert Hello.cap_source(nil, %{"suggestion" => 4, "ceiling" => 2}) == :ceiling
      assert Hello.cap_source(nil, %{}) == nil
    end
  end
end
