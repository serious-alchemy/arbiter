defmodule ArbiterWeb.ApplicationRoleTest do
  # Pure: builds child specs, starts nothing.
  use ExUnit.Case, async: true

  defp child_id(spec), do: Supervisor.child_spec(spec, []).id

  test "agent mode starts no web child at all (no Endpoint, so no port is bound)" do
    assert {:ok, []} =
             ArbiterWeb.Application.supervisor_children(:agent, fn ->
               flunk("the web child list must not be built in agent mode")
             end)
  end

  test "primary mode returns the web list, with the Endpoint in it" do
    assert {:ok, children} = ArbiterWeb.Application.supervisor_children(:primary)
    assert ArbiterWeb.Endpoint in Enum.map(children, &child_id/1)
  end

  test "an unknown role starts nothing" do
    assert {:error, {:unknown_role, :bogus}} = ArbiterWeb.Application.supervisor_children(:bogus)
  end
end
