defmodule Arbiter.Repo do
  use AshSqlite.Repo,
    otp_app: :arbiter

  # Don't open unnecessary transactions — will default to false in Ash 4.0
  def prefer_transaction?, do: false

  @impl true
  def init(_type, config) do
    db_path = Keyword.get(config, :database, "")

    # Guard: a 0-byte file at the DB path means the path was created as an
    # empty placeholder (e.g. ~/.arbiter/arbiter.sqlite3 before T7 cutover).
    # Booting against it would silently wipe all data. Fail loudly instead.
    if db_path != "" and File.exists?(db_path) and File.stat!(db_path).size == 0 do
      raise """
      Arbiter.Repo: refusing to boot — DB file exists but is empty (0 bytes).

        Path: #{db_path}

      This usually means DATABASE_PATH points at the pre-cutover placeholder.
      Set DATABASE_PATH to the live database path and restart, or run the T7
      DB-copy cutover before starting the server.
      """
    end

    # A path that does not exist yet: create and initialize it once, here,
    # on a single connection, before the pool starts. Otherwise several pool
    # connections race to create the file ("database is locked") and the
    # empty-file guard above trips on the half-created file at the restart.
    if is_binary(db_path) and db_path != "" and db_path != ":memory:" and
         not File.exists?(db_path) do
      create_database!(db_path)
    end

    {:ok, config}
  end

  defp create_database!(db_path) do
    File.mkdir_p!(Path.dirname(db_path))
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    try do
      # WAL mode writes the header page, so the file is non-empty on disk.
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    after
      Exqlite.Sqlite3.close(conn)
    end
  end
end
