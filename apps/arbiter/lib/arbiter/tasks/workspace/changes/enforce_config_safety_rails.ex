defmodule Arbiter.Tasks.Workspace.Changes.EnforceConfigSafetyRails do
  @moduledoc """
  The config safety rails `arb config set/unset` used to enforce on its own
  (P-20, D-C-16), now on the `:patch_config` action so MCP and REST get them:
  a write may not leave the workspace in a state the system relies on not
  being in —

    * `repo_paths` emptied (worker dispatch cannot resolve a working dir);
    * `tracker.type` other than `none` with a missing/empty `tracker.config`.

  Only a **newly** broken state is refused: a write that leaves a reason that
  was already true of the stored config (a legacy half-configured workspace)
  does not block an unrelated edit. `force: true` (the `:force` argument; the
  CLI's `--force`) overrides, because there are legitimate transitions that
  pass through an intermediate state.

  Runs after `PatchConfig` has computed the new config.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      with false <- Changeset.get_argument(changeset, :force) == true,
           %{} = new <- Changeset.get_attribute(changeset, :config),
           [_ | _] = reasons <- new_reasons(old_config(changeset), new) do
        Changeset.add_error(changeset,
          field: :config,
          message:
            "refusing — would leave config in a broken state: " <>
              Enum.join(reasons, "; ") <> " (pass force to override)"
        )
      else
        _ -> changeset
      end
    end)
  end

  defp old_config(%{data: %{config: %{} = c}}), do: c
  defp old_config(_), do: %{}

  @doc "The reasons `new` is broken that were not already true of `old`."
  @spec new_reasons(map(), map()) :: [String.t()]
  def new_reasons(old, new), do: reasons(old, new) -- reasons(old, old)

  defp reasons(old, config) do
    Enum.reject([repo_paths_reason(old, config), tracker_reason(config)], &is_nil/1)
  end

  defp repo_paths_reason(old, config) do
    emptied? =
      case Map.fetch(config, "repo_paths") do
        {:ok, m} when is_map(m) and map_size(m) == 0 -> true
        :error -> match?(%{"repo_paths" => %{} = m} when map_size(m) > 0, old)
        _ -> false
      end

    if emptied?, do: "repo_paths is empty — worker dispatch cannot resolve a working dir"
  end

  defp tracker_reason(config) do
    case Map.get(config, "tracker") do
      %{"type" => type} = tracker when is_binary(type) and type != "none" ->
        case Map.get(tracker, "config") do
          c when is_map(c) and map_size(c) > 0 -> nil
          _ -> "tracker.type is #{inspect(type)} but tracker.config is missing/empty"
        end

      _ ->
        nil
    end
  end
end
