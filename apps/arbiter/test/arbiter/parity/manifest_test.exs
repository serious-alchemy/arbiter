defmodule Arbiter.Parity.ManifestTest do
  @moduledoc """
  The MCP / CLI / REST parity manifest (`priv/parity/manifest.exs`).

  Two halves. The enumeration guards compare the manifest with what this app
  can see (the MCP catalog); the sibling tests in `arbiter_web` (router +
  `ApiPolicy`) and `arbiter_cli` (`Verbs.all/0`) do the same for theirs. The
  rest checks the manifest itself: every nil cell carries a ruling, and every
  `{:gap, "P-xx"}` names a child that is still open.
  """
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.Parity.Manifest

  describe "MCP enumeration" do
    test "every catalog tool and every deprecated alias has a manifest row" do
      known = MapSet.new(Manifest.mcp_tools())

      catalog = Enum.map(Catalog.all(), & &1.name) ++ Map.keys(Catalog.legacy_aliases())
      missing = catalog |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.sort()

      assert missing == [], Manifest.missing_message(:mcp, missing)
    end

    test "every tool the manifest names exists in the catalog" do
      catalog = MapSet.new(Enum.map(Catalog.all(), & &1.name) ++ Map.keys(Catalog.legacy_aliases()))
      stale = Manifest.mcp_tools() |> Enum.reject(&MapSet.member?(catalog, &1)) |> Enum.sort()

      assert stale == [], Manifest.stale_message(:mcp, stale)
    end
  end

  describe "the manifest itself" do
    test "it is well formed and every nil cell has a ruling" do
      assert Manifest.problems(Manifest.load!()) == []
    end

    test "problems/1 names each defect, so the guard cannot go quiet" do
      bad = %{
        children: %{"P-90" => "nobody cites me"},
        operations: [
          %{id: "x/a", title: "A", mcp: ["m"], cli: nil, rest: nil, status: :full},
          %{
            id: "x/a",
            title: "dup",
            mcp: nil,
            cli: nil,
            rest: ["GET /api/x"],
            status: {:gap, "P-91"},
            absent: %{mcp: {:gap, "P-91", "missing"}, cli: {:intentional, ""}}
          },
          %{
            id: "x/c",
            title: "C",
            mcp: nil,
            cli: ["arb c"],
            rest: ["GET /api/c"],
            status: :partial,
            absent: %{mcp: {:intentional, "why"}, rest: {:intentional, "stale: rest is present"}}
          }
        ]
      }

      problems = Enum.join(Manifest.problems(bad), "\n")

      assert problems =~ "x/a: no ruling for nil cli"
      assert problems =~ "x/a: no ruling for nil rest"
      assert problems =~ "duplicate id x/a"
      assert problems =~ "P-91 is not in `children`"
      assert problems =~ "P-90 is in `children` but no row cites it"
      assert problems =~ "cli ruling has an empty reason"
      assert problems =~ "x/c: rest has a value and a ruling"
    end

    test "a status of :full or :partial is refused while a nil cell is an open gap" do
      row = %{
        id: "x/g",
        title: "G",
        mcp: nil,
        cli: ["arb g"],
        rest: nil,
        status: :partial,
        absent: %{mcp: {:gap, "P-1", "missing"}, rest: {:intentional, "n/a"}}
      }

      problems = Manifest.problems(%{children: %{"P-1" => "t"}, operations: [row]})
      assert Enum.any?(problems, &(&1 =~ "x/g: status must be {:gap, \"P-1\"}"))
    end

    test "the failure message tells the author how to add a row" do
      message = Manifest.missing_message(:mcp, ["brand_new_tool"])

      assert message =~ "brand_new_tool"
      assert message =~ "priv/parity/manifest.exs"
      assert message =~ "mcp:"
      assert message =~ "absent:"
    end
  end
end
