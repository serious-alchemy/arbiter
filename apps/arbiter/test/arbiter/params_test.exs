defmodule Arbiter.ParamsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Params

  describe "boolean/1" do
    test "accepts true/\"true\"/\"1\"/1 and false/\"false\"/\"0\"/0" do
      for t <- [true, "true", "1", 1], do: assert(Params.boolean(t) == {:ok, true})
      for f <- [false, "false", "0", 0], do: assert(Params.boolean(f) == {:ok, false})
    end

    test "rejects junk instead of guessing" do
      for bad <- ["no", "yes", 2, 0.5, [], %{}, ""], do: assert(Params.boolean(bad) == :error)
    end
  end

  describe "fetch_bool/3 and fetch_optional_bool/2" do
    test "default on absent key, typed error on junk" do
      assert Params.fetch_bool(%{}, "force", false) == {:ok, false}
      assert Params.fetch_bool(%{"force" => "1"}, "force", false) == {:ok, true}
      assert {:error, {:invalid, msg}} = Params.fetch_bool(%{"force" => "no"}, "force", false)
      assert msg =~ "force"
      assert Params.fetch_optional_bool(%{}, "x") == {:ok, nil}
      assert Params.fetch_optional_bool(%{"x" => "false"}, "x") == {:ok, false}
      assert {:error, {:invalid, _}} = Params.fetch_optional_bool(%{"x" => 7}, "x")
    end
  end

  describe "integer/1 and limit/3" do
    test "integer parsing" do
      assert Params.integer(5) == {:ok, 5}
      assert Params.integer("5") == {:ok, 5}
      assert Params.integer("5x") == :error
      assert Params.integer(nil) == :error
    end

    test "limit defaults, clamps to the max, rejects non-positive" do
      assert Params.limit(nil, 50, 500) == {:ok, 50}
      assert Params.limit("", 50, 500) == {:ok, 50}
      assert Params.limit("7", 50, 500) == {:ok, 7}
      assert Params.limit(10_000, 50, 500) == {:ok, 500}
      assert {:error, {:invalid, _}} = Params.limit(0, 50, 500)
      assert {:error, {:invalid, _}} = Params.limit("abc", 50, 500)
      assert {:error, {:invalid, _}} = Params.limit(-1, 50, 500)
    end

    test "default is clamped by the max too" do
      assert Params.limit(nil, 900, 500) == {:ok, 500}
    end
  end

  describe "attribution" do
    test "strip_attribution drops every caller-asserted attribution key" do
      params = %{
        "actor" => "x",
        "created_by" => "x",
        "surface" => "x",
        "by" => "x",
        "change_origin" => "x",
        "title" => "keep"
      }

      assert Params.strip_attribution(params) == %{"title" => "keep"}
    end

    test "actor_label derives from the scope, never the caller" do
      alias Arbiter.MCP.Scope
      assert Params.actor_label(%Scope{tier: :coordinator}) == "coordinator"
      assert Params.actor_label(nil) == nil
    end
  end

  describe "MCP adapters share the coercer" do
    alias Arbiter.MCP.Tools

    test "fetch_bool/optional_bool/optional_integer/parse_bounded_limit agree with Params" do
      assert Tools.fetch_bool(%{"f" => "1"}, "f", false) == {:ok, true}
      assert {:error, {:invalid, _}} = Tools.fetch_bool(%{"f" => "yes"}, "f", false)
      assert Tools.fetch_optional_bool(%{"f" => "0"}, "f") == {:ok, false}
      assert Tools.optional_integer(%{"n" => "3"}, "n") == {:ok, 3}
      assert Tools.parse_bounded_limit(%{"limit" => 9999}, "limit", 20, 200) == {:ok, 200}
      assert Tools.parse_bounded_limit(%{"limit" => "5"}, "limit", 20, 200) == {:ok, 5}

      assert {:error, {:invalid, _}} =
               Tools.parse_bounded_limit(%{"limit" => 0}, "limit", 20, 200)

      assert Tools.optional_bounded_limit(%{}, "limit", 500) == {:ok, nil}
      assert Tools.optional_bounded_limit(%{"limit" => 9999}, "limit", 500) == {:ok, 500}
    end
  end
end
