defmodule Arbiter.Parity.FieldExposureTest do
  @moduledoc """
  Field-exposure guard (parity audit P-30), MCP and REST halves; the CLI half is
  `ArbiterCli.FieldExposureTest`. Every field `Issue :create` / `:update`,
  `ProviderAccount :create` / `:update` and the dispatch params take must be
  classified in `priv/parity/field_exposure.exs`, and each surface must agree with
  its classification — so adding an `accept` entry fails here until a ruling exists.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Parity.FieldExposure

  # Call options that ride alongside the fields and are not fields themselves.
  @call_options ~w(id force workspace assignee summary ref deps)

  @manifest FieldExposure.load!()

  test "the manifest is well formed and covers exactly the known operations" do
    assert FieldExposure.problems(@manifest) == []
    assert Enum.sort(Map.keys(@manifest)) == Enum.sort(FieldExposure.operations())
  end

  for op <- FieldExposure.operations() do
    describe op do
      test "every field the code takes is classified" do
        missing = FieldExposure.governed(unquote(op)) -- Map.keys(@manifest[unquote(op)])

        assert missing == [], FieldExposure.unclassified_message(unquote(op), missing)
      end

      test "the manifest classifies no field the code no longer takes" do
        stale = Map.keys(@manifest[unquote(op)]) -- FieldExposure.governed(unquote(op))

        assert stale == [], FieldExposure.stale_message(unquote(op), stale)
      end

      for surface <- [:mcp, :rest] do
        test "#{surface} agrees with the classification" do
          op = unquote(op)
          surface = unquote(surface)
          exposed = FieldExposure.exposed(op, surface)

          expected =
            for {field, entry} <- @manifest[op],
                name = FieldExposure.surface_name(entry, field, surface),
                do: name

          absent =
            for {f, e} <- @manifest[op], FieldExposure.surface_name(e, f, surface) == nil, do: f

          assert expected -- exposed == [],
                 "#{op}: #{surface} must take #{inspect(expected -- exposed)} (manifest says exposed)"

          assert Enum.filter(absent, &(&1 in exposed)) == [],
                 "#{op}: #{surface} takes #{inspect(Enum.filter(absent, &(&1 in exposed)))} but the manifest rules it absent"

          assert (exposed -- expected) -- @call_options == [],
                 "#{op}: #{surface} takes #{inspect((exposed -- expected) -- @call_options)} with no manifest entry naming it"
        end
      end
    end
  end
end
