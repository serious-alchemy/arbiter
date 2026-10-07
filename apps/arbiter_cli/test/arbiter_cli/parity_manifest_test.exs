defmodule ArbiterCli.ParityManifestTest do
  @moduledoc """
  CLI half of the MCP / CLI / REST parity manifest
  (`apps/arbiter/priv/parity/manifest.exs`, read through the test-only
  `:arbiter` dep). Every `ArbiterCli.Verbs.all/0` entry must be the first verb
  of some manifest `cli:` cell, and every first verb the manifest names must be
  a registered one (or a known orphan awaiting revival).
  """
  use ExUnit.Case, async: true

  alias Arbiter.Parity.Manifest
  alias ArbiterCli.Verbs

  test "every registered verb has a manifest row" do
    known = MapSet.new(Manifest.cli_verbs())

    missing =
      Verbs.all()
      |> Enum.map(&"arb #{&1.name}")
      |> Enum.reject(&MapSet.member?(known, String.replace_prefix(&1, "arb ", "")))
      |> Enum.sort()

    assert missing == [], Manifest.missing_message(:cli, missing)
  end

  test "every verb the manifest names is registered" do
    registered = MapSet.new(for entry <- Verbs.all() ++ Verbs.orphans(), do: entry.name)

    stale =
      Manifest.cli_verbs()
      |> Enum.reject(&MapSet.member?(registered, &1))
      |> Enum.map(&"arb #{&1}")
      |> Enum.sort()

    assert stale == [], Manifest.stale_message(:cli, stale)
  end
end
