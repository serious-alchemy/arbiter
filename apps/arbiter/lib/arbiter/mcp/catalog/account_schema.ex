defmodule Arbiter.MCP.Catalog.AccountSchema do
  @moduledoc """
  The `account_set` input schema, built from the account field registry
  (`Arbiter.Accounts.Fields`, bd-1kr3qf) so the tool's arguments cannot drift
  from what REST, the CLI and the Providers form accept.
  """

  alias Arbiter.Accounts.Fields

  @doc "JSON schema for `account_set`: `ref` plus every `Fields.names(:mcp)`."
  @spec account_set() :: map()
  def account_set do
    attrs =
      for name <- Fields.names(:mcp), name != "quota_config", into: %{} do
        spec = Fields.get(name)
        {name, %{"type" => json_type(spec), "description" => spec.doc}}
      end

    properties =
      attrs
      |> Map.put("ref", %{
        "type" => "string",
        "description" => "Account id, `provider:slug` or bare slug."
      })
      |> Map.put("quota_config", quota_config())

    %{
      "type" => "object",
      "properties" => properties,
      "required" => ["ref"],
      "additionalProperties" => false
    }
  end

  defp quota_config do
    %{
      "type" => "object",
      "description" => Fields.get("quota_config").doc,
      "properties" =>
        Map.new(Fields.quota_specs(), fn spec ->
          {spec.name, %{"type" => quota_type(spec.type), "description" => spec.doc}}
        end),
      "additionalProperties" => false
    }
  end

  defp json_type(%{type: :boolean}), do: "boolean"
  defp json_type(%{type: :count}), do: ["integer", "null"]
  defp json_type(%{type: :text}), do: ["string", "null"]

  # Every quota value may be null (a clear) and numbers may arrive as strings.
  defp quota_type(:fraction), do: ["number", "string", "null"]
  defp quota_type(:usd), do: ["number", "string", "null"]
  defp quota_type(:boolean), do: ["boolean", "string", "null"]
  defp quota_type(:priority), do: ["integer", "string", "null"]
  defp quota_type(:window_map), do: ["object", "null"]
  defp quota_type(_), do: ["string", "null"]
end
