defmodule ArbiterCli.PermissionFlags do
  @moduledoc """
  The per-ticket permission flags (bd-54m4vv, G12), shared by `arb ticket
  create` and `arb ticket update`:

    * `--permission <p>` — declare a permission (`network:<host>[:<port>]`,
      `tracker_write`, `secrets:<name>`, `prod_read`, `prod_ssh`, `phi_data`, `research_read`;
      `network?:host` marks an action optional);
    * `--remove-permission <p>` — (update) drop one.

  Both repeat and take comma lists. On create `--permission` sends the ticket's
  `permissions`; on update the flags send `add_permissions` /
  `remove_permissions`, which the server folds into the stored list, so two
  coordinators editing at once don't clobber each other. The server
  canonicalises and vets every entry; a permission whose binding says
  `grant_by: operator` is only `requested` until the operator grants it.
  Coordinator/operator only — a worker token is refused with a 403.
  """

  @switches [
    permission: [:string, :keep],
    remove_permission: [:string, :keep]
  ]

  @doc "The `OptionParser` switches to append to a command's own."
  @spec switches() :: keyword()
  def switches, do: @switches

  @doc "`%{}` or `%{\"permissions\" => [..]}` for `arb ticket create`."
  @spec create_payload(keyword()) :: map()
  def create_payload(opts) do
    case values(opts, :permission) do
      [] -> %{}
      list -> %{"permissions" => list}
    end
  end

  @doc "`add_permissions` / `remove_permissions` entries for `arb ticket update`."
  @spec update_payload(keyword()) :: map()
  def update_payload(opts) do
    %{}
    |> put_list("add_permissions", values(opts, :permission))
    |> put_list("remove_permissions", values(opts, :remove_permission))
  end

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, list), do: Map.put(map, key, list)

  defp values(opts, key) do
    opts
    |> Keyword.get_values(key)
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
