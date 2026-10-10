defmodule Arbiter.Repo.Migrations.RemoveConductorFromWorkspaceConfigs do
  @moduledoc """
  DC1 (`docs/design/provider-dynamic-concurrency.md` §10.6, bd-74mtmp): the
  workspace `conductor.max_concurrent` key is deleted. This data migration
  removes the `conductor` key from every stored workspace config, including an
  empty `{}`, and logs each value it removed. It runs before the validator
  starts refusing `conductor`, so a stored config never fails an unrelated edit.

  Configs without the key are not touched.

  `down/0` is a no-op: the removed values are only in the log.
  """

  use Ecto.Migration

  def up do
    rows = repo().query!("SELECT id, name, config FROM workspaces").rows

    for [id, name, config] <- rows, is_binary(config), {:ok, %{"conductor" => conductor} = decoded} <- [Jason.decode(config)] do
      log(name, conductor)

      repo().query!("UPDATE workspaces SET config = ?1 WHERE id = ?2", [
        Jason.encode!(Map.delete(decoded, "conductor")),
        id
      ])
    end

    :ok
  end

  def down, do: :ok

  defp log(name, %{"max_concurrent" => value}) do
    IO.puts(
      "[remove_conductor_from_workspace_configs] workspace `#{name}`: " <>
        "removed conductor.max_concurrent = #{Jason.encode!(value)}"
    )
  end

  defp log(_name, _conductor), do: :ok
end
