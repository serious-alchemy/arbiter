defmodule Arbiter.Repo.Migrations.DropConductorSystemMaxConcurrent do
  @moduledoc """
  DC1 (`docs/design/provider-dynamic-concurrency.md` §5.1, §10.6, bd-74mtmp):
  the install-wide `conductor_system_max_concurrent` is deleted. The install's
  concurrency is the sum of its machines' caps, and the primary's own cap
  defaults to its hardware suggestion, enforced.

  Before the column goes, its stored value `K` is dealt with:

    * **unset** (the operator reports it is unset everywhere): nothing else
      happens;
    * **set, with no enrolled node and `nodes_local_max_workers` unset:** `K` is
      copied into `nodes_local_max_workers`. It is the same machine and the same
      number, now enforced at the node layer;
    * **set, in any case:** one advisory line is logged and kept in the new
      `local_cap_advisory` column, which `arb server doctor` shows until the
      operator sets the local cap (`arb node set local`).

  `down/0` restores the column empty. The value is not recoverable, and the
  copy into `nodes_local_max_workers` is left in place: it is an ordinary
  operator override from then on.
  """

  use Ecto.Migration

  def up do
    alter table(:installation_settings) do
      add :local_cap_advisory, :text
    end

    flush()

    case repo().query!("SELECT id, conductor_system_max_concurrent FROM installation_settings").rows do
      [[id, k] | _] when is_integer(k) -> carry(id, k)
      _ -> :ok
    end

    alter table(:installation_settings) do
      remove :conductor_system_max_concurrent
    end
  end

  def down do
    alter table(:installation_settings) do
      add :conductor_system_max_concurrent, :integer
      remove :local_cap_advisory
    end
  end

  defp carry(id, k) do
    [[nodes]] = repo().query!("SELECT COUNT(*) FROM nodes").rows

    [[override]] =
      repo().query!(
        "SELECT nodes_local_max_workers FROM installation_settings WHERE id = ?1",
        [id]
      ).rows

    if nodes == 0 and is_nil(override) do
      repo().query!(
        "UPDATE installation_settings SET nodes_local_max_workers = ?1 WHERE id = ?2",
        [k, id]
      )
    end

    advisory =
      "conductor_system_max_concurrent (#{k}) was removed: the install's concurrency is the " <>
        "sum of its machines' caps. To keep #{k} on this machine: " <>
        "`arb node set local --max-workers #{k}`."

    repo().query!("UPDATE installation_settings SET local_cap_advisory = ?1 WHERE id = ?2", [
      advisory,
      id
    ])

    IO.puts("[drop_conductor_system_max_concurrent] " <> advisory)
  end
end
