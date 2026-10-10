defmodule Arbiter.Settings.DeleteConductorMaxConcurrentMigrationTest do
  @moduledoc """
  DC1 (`docs/design/provider-dynamic-concurrency.md` §10.6, bd-74mtmp): the two
  migrations that delete `conductor.max_concurrent`.

    * the install setting's column is dropped, its value carried to
      `nodes_local_max_workers` only when that is the same machine and the same
      number (no enrolled node, no override), and an advisory line is logged and
      kept for `arb server doctor`;
    * the workspace key is removed from every stored config, with each removed
      value logged.

  Run against a throwaway database, like the P8 migration test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbiter.RekeyMigrationRepo, as: Repo

  @install_id 20_261_010_120_000
  @install_file "priv/repo/migrations/20261010120000_drop_conductor_system_max_concurrent.exs"
  @workspace_id 20_261_010_120_100
  @workspace_file "priv/repo/migrations/20261010120100_remove_conductor_from_workspace_configs.exs"

  setup_all do
    [{install, _}] = Code.require_file(@install_file, File.cwd!())
    [{workspace, _}] = Code.require_file(@workspace_file, File.cwd!())
    {:ok, install: install, workspace: workspace}
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_dc1_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    create_schema()
    :ok
  end

  describe "the install setting" do
    test "unset: the column goes and nothing else happens", %{install: m} do
      insert_settings(nil, nil)

      out = capture_io(fn -> migrate_install!(m) end)

      refute out =~ "conductor_system_max_concurrent"
      refute "conductor_system_max_concurrent" in columns("installation_settings")
      assert [[nil, nil]] = query("SELECT nodes_local_max_workers, local_cap_advisory FROM installation_settings")
    end

    test "set, no node and no override: copied to the local cap, with the advisory", %{install: m} do
      insert_settings(6, nil)

      out = capture_io(fn -> migrate_install!(m) end)

      assert [[6, advisory]] =
               query("SELECT nodes_local_max_workers, local_cap_advisory FROM installation_settings")

      assert advisory =~ "conductor_system_max_concurrent (6) was removed"
      assert advisory =~ "`arb node set local --max-workers 6`"
      assert out =~ advisory
      refute "conductor_system_max_concurrent" in columns("installation_settings")
    end

    test "set, an enrolled node: not copied (the sum of the machines applies), advisory kept",
         %{install: m} do
      insert_settings(6, nil)
      Repo.query!("INSERT INTO nodes (id, name) VALUES ('n1', 'box')")

      capture_io(fn -> migrate_install!(m) end)

      assert [[nil, advisory]] =
               query("SELECT nodes_local_max_workers, local_cap_advisory FROM installation_settings")

      assert advisory =~ "(6) was removed"
    end

    test "set, a local override already in place: the override wins, advisory kept", %{install: m} do
      insert_settings(6, 2)

      capture_io(fn -> migrate_install!(m) end)

      assert [[2, advisory]] =
               query("SELECT nodes_local_max_workers, local_cap_advisory FROM installation_settings")

      assert advisory =~ "(6) was removed"
    end

    test "no settings row at all still migrates", %{install: m} do
      capture_io(fn -> migrate_install!(m) end)
      refute "conductor_system_max_concurrent" in columns("installation_settings")
    end
  end

  describe "the workspace key" do
    test "removes the conductor key, logs each value, and leaves the rest of the config",
         %{workspace: m} do
      insert_workspace("w1", "alpha", %{"conductor" => %{"max_concurrent" => 4}, "quota" => %{"a" => 1}})
      insert_workspace("w2", "beta", %{"conductor" => %{"max_concurrent" => "3"}})

      out = capture_io(fn -> migrate_workspace!(m) end)

      assert out =~ "workspace `alpha`: removed conductor.max_concurrent = 4"
      assert out =~ ~s(workspace `beta`: removed conductor.max_concurrent = "3")
      assert config("w1") == %{"quota" => %{"a" => 1}}
      assert config("w2") == %{}
    end

    test "removes an empty conductor object without a log line", %{workspace: m} do
      insert_workspace("w1", "live-default", %{"conductor" => %{}, "routing" => %{"x" => 1}})

      out = capture_io(fn -> migrate_workspace!(m) end)

      refute out =~ "removed conductor.max_concurrent"
      assert config("w1") == %{"routing" => %{"x" => 1}}
    end

    test "leaves configs without the key byte-for-byte alone", %{workspace: m} do
      Repo.query!("INSERT INTO workspaces (id, name, config) VALUES ('w1', 'plain', '{\"a\": 1}')")
      Repo.query!("INSERT INTO workspaces (id, name, config) VALUES ('w2', 'nil', NULL)")

      capture_io(fn -> migrate_workspace!(m) end)

      assert query("SELECT config FROM workspaces ORDER BY id") == [["{\"a\": 1}"], [nil]]
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp migrate_install!(m), do: Ecto.Migrator.up(Repo, @install_id, m, log: false)
  defp migrate_workspace!(m), do: Ecto.Migrator.up(Repo, @workspace_id, m, log: false)

  defp query(sql), do: Repo.query!(sql).rows

  defp columns(table), do: for([_, name | _] <- query("PRAGMA table_info(#{table})"), do: name)

  defp config(id), do: id |> workspace_config() |> Jason.decode!()

  defp workspace_config(id),
    do: Repo.query!("SELECT config FROM workspaces WHERE id = ?1", [id]).rows |> hd() |> hd()

  defp insert_settings(conductor, local) do
    Repo.query!(
      """
      INSERT INTO installation_settings (id, conductor_system_max_concurrent, nodes_local_max_workers)
      VALUES ('s1', ?1, ?2)
      """,
      [conductor, local]
    )
  end

  defp insert_workspace(id, name, config) do
    Repo.query!("INSERT INTO workspaces (id, name, config) VALUES (?1, ?2, ?3)", [
      id,
      name,
      Jason.encode!(config)
    ])
  end

  defp create_schema do
    [
      "CREATE TABLE workspaces (id TEXT NOT NULL PRIMARY KEY, name TEXT, config TEXT)",
      "CREATE TABLE nodes (id TEXT NOT NULL PRIMARY KEY, name TEXT)",
      """
      CREATE TABLE installation_settings (
        id TEXT NOT NULL PRIMARY KEY, conductor_system_max_concurrent INTEGER,
        nodes_local_max_workers INTEGER)
      """
    ]
    |> Enum.each(&Repo.query!/1)
  end
end
