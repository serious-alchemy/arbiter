defmodule Arbiter.Tasks.Workspace.Changes.RejectSecretConfigKeys do
  @moduledoc """
  Refuses a top-level `secret*` / `credentials*` key in the workspace `config`
  (P-20, D-C-4): secrets live in the encrypted `secrets` column, so a plaintext
  copy in the config JSON would sit unencrypted, readable by worker-tier
  `workspace_config_get` and `GET /api/workspaces`, and do nothing.

  One check in the change chain, so MCP, REST, the CLI and in-process callers
  all refuse. It runs on `:create`, `:update` and `:patch_config`, **before**
  the config is merged/validated, and only looks at what the write *sets*:

    * `:patch_config` — the top-level keys of `patch`;
    * `:create` / `:update` — a top-level key of the `config` change whose value
      is not already what is stored (so re-sending a legacy value untouched is
      not a new write, and an `unset_paths` cleanup of one is always allowed).

  Secrets keep their dedicated route: the `secrets` action argument
  (`arb workspace secret`).
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @blocked_prefixes ~w(secret credentials)

  @impl true
  def change(changeset, _opts, _context) do
    case offending(changeset) do
      [] ->
        changeset

      keys ->
        Changeset.add_error(changeset,
          field: :config,
          message:
            "cannot set #{Enum.map_join(keys, ", ", &inspect/1)} in the workspace config — " <>
              "secrets are stored encrypted; use `arb workspace secret` (the `secrets` field)"
        )
    end
  end

  @doc "Whether a top-level config key is one a config write may not set."
  @spec blocked?(term()) :: boolean()
  def blocked?(key) when is_binary(key) do
    down = key |> String.trim() |> String.downcase()
    Enum.any?(@blocked_prefixes, &String.starts_with?(down, &1))
  end

  def blocked?(_), do: false

  defp offending(%{action: %{name: :patch_config}} = changeset) do
    case Changeset.get_argument(changeset, :patch) do
      %{} = patch -> patch |> Map.keys() |> Enum.filter(&blocked?/1)
      _ -> []
    end
  end

  defp offending(changeset) do
    old = with %{config: %{} = c} <- changeset.data, do: c, else: (_ -> %{})

    case Changeset.fetch_change(changeset, :config) do
      {:ok, %{} = new} ->
        new
        |> Enum.filter(fn {k, v} -> blocked?(k) and Map.get(old, k) != v end)
        |> Enum.map(&elem(&1, 0))

      _ ->
        []
    end
  end
end
