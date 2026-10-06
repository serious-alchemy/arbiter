defmodule Arbiter.Nodes.SkewTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Skew

  # The design's skew table (§6): the primary decides on `hello`.
  describe "health/2 (docs/design/remote-workers.md §6)" do
    test "same version and a supported proto is ready" do
      assert Skew.health(%{version: "0.3.0", proto: 1}, %{version: "0.3.0", min_proto: 1}) ==
               :ready
    end

    test "the leading v of a release tag is not a difference" do
      assert Skew.health(%{version: "v0.3.0", proto: 1}, %{version: "0.3.0", min_proto: 1}) ==
               :ready
    end

    test "an older agent on a supported proto is outdated" do
      assert Skew.health(%{version: "0.2.9", proto: 1}, %{version: "0.3.0", min_proto: 1}) ==
               :outdated
    end

    test "an agent below the primary's min_proto is incompatible, whatever its version" do
      assert Skew.health(%{version: "0.3.0", proto: 1}, %{version: "0.3.0", min_proto: 2}) ==
               :incompatible

      assert Skew.health(%{version: "0.9.0", proto: 0}, %{version: "0.3.0", min_proto: 1}) ==
               :incompatible
    end

    test "an agent newer than the primary (after a rollback) is ahead" do
      assert Skew.health(%{version: "0.4.0", proto: 1}, %{version: "0.3.0", min_proto: 1}) ==
               :ahead
    end

    test "a version that cannot be read is outdated, not ready" do
      assert Skew.health(%{version: "not-a-version", proto: 1}, %{
               version: "0.3.0",
               min_proto: 1
             }) == :outdated

      assert Skew.health(%{version: nil, proto: 1}, %{version: "0.3.0", min_proto: 1}) ==
               :outdated
    end

    test "a missing or non-integer proto is incompatible" do
      assert Skew.health(%{version: "0.3.0", proto: nil}, %{version: "0.3.0", min_proto: 1}) ==
               :incompatible
    end
  end

  describe "assignable?/2" do
    test "only a ready node takes new assignments, unless skew is allowed" do
      assert Skew.assignable?(:ready, false)
      for h <- [:outdated, :incompatible, :ahead], do: refute(Skew.assignable?(h, false))
      assert Skew.assignable?(:outdated, true)
      refute Skew.assignable?(:incompatible, true)
      refute Skew.assignable?(:ahead, true)
    end
  end
end
