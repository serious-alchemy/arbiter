defmodule ArbiterCli.FieldExposureTest do
  @moduledoc """
  CLI half of the field-exposure guard (parity audit P-30; the MCP and REST halves
  are `Arbiter.Parity.FieldExposureTest` in `arbiter`). Each field the manifest
  (`apps/arbiter/priv/parity/field_exposure.exs`) says `arb` takes must be a
  switch of the verb, and each field it rules absent from the CLI must not be.
  Switches that are not fields (`--json`, `--force`, ...) are not policed: the
  manifest enumerates fields, and the `arbiter` tests fail when one is unclassified.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Parity.FieldExposure
  alias ArbiterCli.Cmd.{Account, Create, Dispatch, Update}

  @manifest FieldExposure.load!()

  defp switch_names(op) do
    switches =
      case op do
        "issue/create" -> Create.switches()
        "issue/update" -> Update.edit_switches()
        "dispatch" -> Dispatch.switches()
        "account/" <> _ -> Account.switches()
      end

    MapSet.new(switches, fn {name, _type} -> Atom.to_string(name) end)
  end

  for op <- FieldExposure.operations() do
    test "#{op}: the CLI switches agree with the classification" do
      op = unquote(op)
      switches = switch_names(op)

      {taken, absent} =
        Enum.reduce(@manifest[op], {[], []}, fn {field, entry}, {taken, absent} ->
          case FieldExposure.surface_name(entry, field, :cli) do
            nil -> {taken, [field | absent]}
            "positional" -> {taken, absent}
            name -> {[{field, name} | taken], absent}
          end
        end)

      missing =
        for {field, name} <- taken, not MapSet.member?(switches, name), do: "#{field} (--#{name})"

      assert missing == [],
             "#{op}: the manifest says arb takes these but no switch exists: #{inspect(missing)}"

      # `arb account create` and `set` share one switch list, so a create-only field has a
      # switch under the update op too: only the forward direction is checkable there.
      contradicted =
        if String.starts_with?(op, "account/"),
          do: [],
          else: Enum.filter(absent, &MapSet.member?(switches, &1))

      assert contradicted == [],
             "#{op}: arb has a switch for #{inspect(contradicted)} but the manifest rules it absent from the CLI"
    end
  end
end
