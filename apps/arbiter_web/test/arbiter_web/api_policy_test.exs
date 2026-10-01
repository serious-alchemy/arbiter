defmodule ArbiterWeb.ApiPolicyTest do
  @moduledoc """
  bd-asawcq: every `/api` route is classified in `ArbiterWeb.ApiPolicy`, and
  an anonymous loopback caller reaches only the routes classified
  `:anonymous`. Iterates the router itself, so a newly added route cannot
  silently stay anonymous: it has no policy entry, and this test fails.
  """
  use ArbiterWeb.ConnCase, async: true

  alias ArbiterWeb.ApiPolicy

  @write_verbs [:post, :put, :patch, :delete]

  defp api_routes do
    ArbiterWeb.Router.__routes__()
    |> Enum.filter(&String.starts_with?(&1.path, "/api/"))
  end

  # A concrete path for a route pattern: every `:param` becomes a placeholder.
  defp concrete(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> "bd-nonexistent"
      seg -> seg
    end)
  end

  defp anonymous_loopback(method, path) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(@endpoint, method, path, "{}")
  end

  test "every /api route has an explicit policy" do
    missing =
      for route <- api_routes(), ApiPolicy.policy(route.verb, route.path) == :unclassified do
        "#{route.verb |> to_string() |> String.upcase()} #{route.path}"
      end

    assert missing == [], "unclassified /api routes: #{inspect(missing)}"
  end

  test "no write route is anonymous" do
    anonymous_writes =
      for route <- api_routes(),
          route.verb in @write_verbs,
          ApiPolicy.policy(route.verb, route.path) == :anonymous,
          do: "#{route.verb} #{route.path}"

    assert anonymous_writes == []
  end

  test "an anonymous loopback request to every write route is rejected with 401" do
    accepted =
      for route <- api_routes(), route.verb in @write_verbs do
        conn = anonymous_loopback(route.verb, concrete(route.path))
        {route.verb, route.path, conn.status}
      end
      |> Enum.reject(fn {_, _, status} -> status == 401 end)

    assert accepted == [], "anonymous loopback writes not rejected: #{inspect(accepted)}"
  end

  test "an anonymous loopback request to every non-anonymous read route is rejected with 401" do
    accepted =
      for route <- api_routes(),
          route.verb == :get,
          ApiPolicy.policy(route.verb, route.path) != :anonymous do
        conn = anonymous_loopback(:get, concrete(route.path))
        {route.path, conn.status}
      end
      |> Enum.reject(fn {_, status} -> status == 401 end)

    assert accepted == [], "anonymous loopback reads not rejected: #{inspect(accepted)}"
  end

  test "the anonymous routes stay reachable without a token" do
    for route <- api_routes(), ApiPolicy.policy(route.verb, route.path) == :anonymous do
      conn = anonymous_loopback(route.verb, concrete(route.path))
      refute conn.status in [401, 403], "#{route.path} rejected an anonymous caller"
    end
  end
end
