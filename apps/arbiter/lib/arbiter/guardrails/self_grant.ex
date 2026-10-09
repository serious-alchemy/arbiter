defmodule Arbiter.Guardrails.SelfGrant do
  @moduledoc """
  Recognises a worker's attempt to widen its own authority (G17,
  `docs/design/guardrail-profiles.md` §6.1): a write to ticket `permissions` or
  to `guardrails.*` / `permissions` config, a permission grant, or a token
  mint. Pure: `mcp?/2` answers for a tool call, `rest?/3` for an HTTP request.

  It matches the *attempt*, whatever the outcome. A worker's scope cannot do
  any of these today (the tool tiers and `ArbiterWeb.ApiPolicy` refuse them),
  but trying is the signal, and a refusal that regresses must not also drop the
  trail. The call sites record `critical` events via
  `Arbiter.Guardrails.Events.record_self_grant/3`.
  """

  @config_tools ~w(workspace_config_set workspace_config_unset installation_config_set)
  @ticket_tools ~w(ticket_create ticket_update)
  @permission_params ~w(permissions add_permissions remove_permissions)

  @doc "Whether the MCP tool call `name` with `args` is a self-grant attempt."
  @spec mcp?(String.t(), term()) :: boolean()
  def mcp?(name, args) when is_binary(name) do
    args = if is_map(args), do: args, else: %{}

    cond do
      name in @config_tools -> config_args?(args)
      name in @ticket_tools -> permission_params?(args)
      String.contains?(name, "permission_grant") -> true
      true -> false
    end
  end

  def mcp?(_name, _args), do: false

  @doc "Whether the HTTP request is a self-grant attempt. `path` is `conn.path_info`."
  @spec rest?(String.t(), [String.t()], term()) :: boolean()
  def rest?(method, path, params) do
    params = if is_map(params), do: params, else: %{}

    case {String.upcase(method), path} do
      {"POST", ["api", "mcp", "tokens"]} ->
        true

      {_, ["api", "workspaces", _, "config"]} when method in ["PATCH", "PUT", "POST"] ->
        config_args?(params)

      {_, ["api", "installation", "config"]} when method in ["PATCH", "PUT", "POST"] ->
        config_args?(params)

      {_, ["api", "issues", _, "permissions" | _]} when method != "GET" ->
        true

      {_, ["api", "issues" | _]} when method in ["POST", "PATCH", "PUT"] ->
        permission_params?(params)

      _ ->
        false
    end
  end

  # An edit that names a path through `guardrails` or `permissions`: the dotted
  # `key`, the keys of a `patch` at any depth, or an `unset_paths` entry.
  defp config_args?(args) do
    key_hit? = is_binary(args["key"]) and sensitive_path?(args["key"])

    patch_hit? =
      case args["patch"] do
        %{} = patch -> map_hit?(patch)
        _ -> false
      end

    unset_hit? =
      case args["unset_paths"] do
        list when is_list(list) -> Enum.any?(list, &(is_binary(&1) and sensitive_path?(&1)))
        _ -> false
      end

    key_hit? or patch_hit? or unset_hit? or
      map_hit?(Map.drop(args, ["key", "patch", "unset_paths"]))
  end

  defp map_hit?(%{} = map) do
    Enum.any?(map, fn {k, v} ->
      (is_binary(k) and sensitive_path?(k)) or map_hit?(v)
    end)
  end

  defp map_hit?(_), do: false

  defp sensitive_path?(path),
    do: path |> String.split(".") |> Enum.any?(&(&1 in ["guardrails", "permissions"]))

  defp permission_params?(args),
    do: Enum.any?(@permission_params, &(args[&1] not in [nil, [], ""]))
end
