defmodule ArbiterWeb.ParityManifestTest do
  @moduledoc """
  REST half of the MCP / CLI / REST parity manifest
  (`apps/arbiter/priv/parity/manifest.exs`). Every `/api` route the router
  serves, `GET /events`, and every `ApiPolicy` table entry must be a row in the
  manifest, and every `/api` route the manifest names must exist. Same shape as
  `api_policy_test.exs`: it iterates the router itself, so a new route cannot
  ship without its parity ruling.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Parity.Manifest
  alias ArbiterWeb.ApiPolicy

  defp router_routes do
    for route <- ArbiterWeb.Router.__routes__(),
        String.starts_with?(route.path, "/api/") or {route.verb, route.path} == {:get, "/events"} do
      route_key(route.verb, route.path)
    end
    |> Enum.uniq()
  end

  defp route_key(verb, path), do: "#{verb |> to_string() |> String.upcase()} #{path}"

  defp checked?(route), do: String.contains?(route, " /api/") or route == "GET /events"

  test "every /api route and GET /events has a manifest row" do
    known = MapSet.new(Manifest.rest_routes())
    missing = router_routes() |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.sort()

    assert missing == [], Manifest.missing_message(:rest, missing)
  end

  test "every ApiPolicy table entry has a manifest row" do
    known = MapSet.new(Manifest.rest_routes())

    missing =
      ApiPolicy.policies()
      |> Map.keys()
      |> Enum.map(fn {verb, route} -> route_key(verb, route) end)
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.sort()

    assert missing == [], Manifest.missing_message(:rest, missing)
  end

  test "every /api route the manifest names is served by the router" do
    served = MapSet.new(router_routes())

    stale =
      Manifest.rest_routes()
      |> Enum.filter(&checked?/1)
      |> Enum.reject(&MapSet.member?(served, &1))
      |> Enum.sort()

    assert stale == [], Manifest.stale_message(:rest, stale)
  end
end
