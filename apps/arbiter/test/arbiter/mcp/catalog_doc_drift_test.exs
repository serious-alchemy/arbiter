defmodule Arbiter.MCP.CatalogDocDriftTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog

  setup_all do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Catalog)
    %{doc: doc}
  end

  test "every Catalog.all/0 tool has a moduledoc table row with its tiers", %{doc: doc} do
    rows =
      for line <- String.split(doc, "\n"),
          [_, cell, tiers] <- [Regex.run(~r/^\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|/, line)],
          do: {cell, tiers}

    for tool <- Catalog.all() do
      assert {_cell, tiers} = Enum.find(rows, fn {cell, _} -> cell =~ "`#{tool.name}`" end),
             "#{tool.name} has no row in the Catalog moduledoc table"

      for tier <- tool.tiers do
        assert tiers =~ to_string(tier),
               "#{tool.name}: moduledoc tiers #{inspect(tiers)} omit #{tier}"
      end
    end
  end

  test "the moduledoc table names no tool that is not in the catalog", %{doc: doc} do
    names = MapSet.new(Catalog.all(), & &1.name)

    documented =
      ~r/^\s*\|\s*`([a-z_]+)`/m |> Regex.scan(doc) |> Enum.map(&List.last/1)

    assert Enum.reject(documented, &MapSet.member?(names, &1)) == []
  end

  test "no ticket schema advertises the removed `assignee`" do
    for name <- ~w(ticket_create ticket_update) do
      {:ok, tool} = Catalog.fetch(name)
      refute Map.has_key?(tool.input_schema["properties"], "assignee")
    end
  end

  test "ticket_handoff requires a note" do
    {:ok, tool} = Catalog.fetch("ticket_handoff")
    assert "note" in tool.input_schema["required"]
  end

  test "worker_dispatch provider enum is Agents.valid_agent_types/0" do
    {:ok, tool} = Catalog.fetch("worker_dispatch")
    enum = tool.input_schema["properties"]["provider"]["enum"]
    assert Enum.sort(enum) == Enum.sort(Arbiter.Agents.valid_agent_types())
  end
end
