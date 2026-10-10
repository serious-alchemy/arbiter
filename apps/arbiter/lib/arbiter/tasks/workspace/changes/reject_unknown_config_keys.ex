defmodule Arbiter.Tasks.Workspace.Changes.RejectUnknownConfigKeys do
  @moduledoc """
  Refuses a `:patch_config` write whose `patch` sets a top-level key that is not
  in `Arbiter.Tasks.Workspace.ConfigSchema.known_top_level_keys/0` (bd-311cun).

  `arb config set sandbox.backend podman` used to succeed and do nothing: the
  sandbox is only read from `agent.security.sandbox`. One check in the change
  chain, so the CLI, REST and MCP all refuse, naming the canonical path when
  `ConfigSchema.suggest_path/1` knows it. `force: true` overrides.

  Only what the write *sets* is checked: configs already holding an unknown key
  still load, and an unrelated patch is never blocked by it.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.Workspace.ConfigSchema
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    known = ConfigSchema.known_top_level_keys()

    with false <- Changeset.get_argument(changeset, :force) == true,
         %{} = patch <- Changeset.get_argument(changeset, :patch),
         [_ | _] = unknown <- Enum.reject(patch, fn {k, _} -> k in known end) do
      Changeset.add_error(changeset, field: :config, message: message(unknown))
    else
      _ -> changeset
    end
  end

  # DC1: `conductor` is a known-removed key, so it says what replaced it.
  defp message(unknown) do
    if Enum.any?(unknown, fn {k, _} -> k == "conductor" end) do
      ConfigSchema.conductor_removed_message()
    else
      "unknown top-level config key #{Enum.map_join(unknown, "; ", &describe/1)} " <>
        "(see `arb config schema`; pass force to write it anyway)"
    end
  end

  # `sandbox` => %{"backend" => ..} reads as the typed path `sandbox.backend`,
  # which is what `ConfigSchema.suggest_path/1` maps.
  defp describe({key, value}) do
    suggestions =
      value
      |> leaf_paths([to_string(key)])
      |> Enum.map(&ConfigSchema.suggest_path/1)
      |> Enum.reject(&is_nil/1)

    case suggestions do
      [] -> inspect(key)
      paths -> "#{inspect(key)} (did you mean #{Enum.map_join(paths, ", ", &"`#{&1}`")}?)"
    end
  end

  defp leaf_paths(%{} = map, prefix) when map_size(map) > 0 do
    Enum.flat_map(map, fn {k, v} -> leaf_paths(v, prefix ++ [to_string(k)]) end)
  end

  defp leaf_paths(_, prefix), do: [Enum.join(prefix, ".")]
end
