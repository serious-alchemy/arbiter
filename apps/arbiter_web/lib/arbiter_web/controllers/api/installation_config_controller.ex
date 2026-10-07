defmodule ArbiterWeb.Api.InstallationConfigController do
  @moduledoc """
  REST access to the install-wide runtime settings — the REST twin of the
  `installation_config_get` / `installation_config_set` MCP tools and of
  `arb settings`. Key list, validation and storage all live in
  `Arbiter.Settings.Registry`, so the three surfaces cannot drift.

  Routes:

    * `GET /api/installation/config` — every key as `{key, type, description,
      allowed, value, override, overridden, default}`; `?key=` narrows to one.
      `value` is what is in force, `override` the raw persisted value
      (`null` = none; for the list keys `[]` is a real value, distinct from
      `null`), `default` what applies with no override.
    * `PATCH /api/installation/config` — body `{"key": ..., "value": ...}`;
      `"value": null` clears the override. An invalid value is a 422 and
      nothing is written; an operator-only key (`nodes.*`,
      `scheduling_epic_floors_enabled`, `scheduling_max_lifted_in_flight`) sent
      with a coordinator token that lacks operator proof is a 403
      `unauthorized` refusal (`Registry.put/3`).

  Both routes are coordinator-tier only (`ArbiterWeb.ApiPolicy`): the MCP set
  tool is coordinator-only, and `/api/server/*` and `/api/scheduler/*` read
  the same way, so REST is no weaker. Workers still read through the MCP tool.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Settings.Registry

  action_fallback(ArbiterWeb.Api.FallbackController)

  def show(conn, %{"key" => key}) do
    case Registry.describe(key) do
      nil -> {:error, :not_found}
      item -> json(conn, %{data: item})
    end
  end

  def show(conn, _params), do: json(conn, %{data: Registry.all()})

  def update(conn, %{"key" => key} = params) when is_binary(key) do
    with true <-
           Map.has_key?(params, "value") || {:invalid, "value is required (use null to clear)"},
         {:ok, _} <- Registry.put(key, Map.get(params, "value"), authority: authority(conn)) do
      json(conn, %{data: Registry.describe(key)})
    else
      {:invalid, message} -> {:error, {:invalid, message}}
      {:error, _} = error -> error
    end
  end

  def update(_conn, _params), do: {:error, {:invalid, "key is required"}}

  # The operator-only keys (`Registry.operator_only_keys/0`) need operator proof:
  # the token's authority decides, exactly as for the MCP set tool.
  defp authority(conn), do: Authority.from_scope(conn.assigns[:mcp_scope])
end
