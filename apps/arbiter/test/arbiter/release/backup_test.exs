defmodule Arbiter.Release.BackupTest do
  use ExUnit.Case, async: true

  alias Arbiter.Release.Backup
  alias Exqlite.Sqlite3

  setup do
    dir =
      Path.join(System.tmp_dir!(), "arb-backup-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # A live WAL-mode database with one table and `n` rows, and a connection left
  # open on it (the "server") so the backup is genuinely taken online.
  defp live_db(dir, n) do
    path = Path.join(dir, "live.sqlite3")
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    for i <- 1..n, do: :ok = Sqlite3.execute(conn, "INSERT INTO t (v) VALUES ('row-#{i}')")
    on_exit(fn -> Sqlite3.close(conn) end)
    {path, conn}
  end

  defp count_rows(path) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT count(*) FROM t")
    {:row, [n]} = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    Sqlite3.close(conn)
    n
  end

  test "takes an online backup of a live WAL database, including uncheckpointed rows", %{dir: dir} do
    {src, _conn} = live_db(dir, 25)
    dest = Path.join([dir, "snapshots", "arbiter-pre-v1.sqlite3"])

    assert {:ok, %{path: ^dest, bytes: bytes}} = Backup.take(src, dest)
    assert bytes > 0
    assert count_rows(dest) == 25
  end

  test "the source is not modified or locked by the backup", %{dir: dir} do
    {src, conn} = live_db(dir, 3)
    dest = Path.join(dir, "b.sqlite3")

    assert {:ok, _} = Backup.take(src, dest)

    # The live connection can still write after the backup.
    assert :ok = Sqlite3.execute(conn, "INSERT INTO t (v) VALUES ('after')")
    assert count_rows(src) == 4
    assert count_rows(dest) == 3
  end

  test "refuses to overwrite an existing destination", %{dir: dir} do
    {src, _conn} = live_db(dir, 1)
    dest = Path.join(dir, "exists.sqlite3")
    File.write!(dest, "precious")

    assert {:error, {:dest_exists, ^dest}} = Backup.take(src, dest)
    assert File.read!(dest) == "precious"
  end

  test "a missing source is an error and leaves no destination", %{dir: dir} do
    dest = Path.join(dir, "b.sqlite3")
    assert {:error, {:source_missing, _}} = Backup.take(Path.join(dir, "nope.sqlite3"), dest)
    refute File.exists?(dest)
  end

  test "a source that is not a database fails the integrity check and leaves no destination",
       %{dir: dir} do
    src = Path.join(dir, "garbage.sqlite3")
    File.write!(src, String.duplicate("not a database ", 1000))
    dest = Path.join(dir, "b.sqlite3")

    assert {:error, _reason} = Backup.take(src, dest)
    refute File.exists?(dest)
  end

  test "integrity_check/1 rejects a corrupted file", %{dir: dir} do
    {src, conn} = live_db(dir, 200)
    dest = Path.join(dir, "b.sqlite3")
    {:ok, _} = Backup.take(src, dest)
    Sqlite3.close(conn)

    # Smash a data page in the middle of the copy.
    bytes = File.read!(dest)
    mid = div(byte_size(bytes), 2)
    <<head::binary-size(mid), _::binary-size(64), tail::binary>> = bytes
    File.write!(dest, head <> :binary.copy(<<0xFF>>, 64) <> tail)

    assert {:error, _} = Backup.integrity_check(dest)
  end

  test "integrity_check/1 passes on a good backup", %{dir: dir} do
    {src, _conn} = live_db(dir, 10)
    dest = Path.join(dir, "b.sqlite3")
    {:ok, _} = Backup.take(src, dest)
    assert :ok = Backup.integrity_check(dest)
  end
end
