defmodule Arbiter.Release.Backup do
  @moduledoc """
  Online, integrity-checked backup of the SQLite database, for
  `arb server deploy`'s pre-swap snapshot.

  The copy is made with `VACUUM INTO`, which reads the database through a
  normal SQLite connection and so yields a consistent snapshot of a live,
  WAL-mode database (uncheckpointed WAL frames included) while the server keeps
  serving — never a file copy of the `.sqlite3`/`-wal`/`-shm` trio, which can be
  torn. The snapshot is written to `<dest>.partial`, `PRAGMA integrity_check`
  runs on *that file*, and only a clean result is renamed to `dest`: a backup
  that exists under its final name has passed its check.

  Invoked from the CLI through the release's own binary, because the arb
  escript carries no SQLite NIF:

      ARB_BACKUP_SRC=… ARB_BACKUP_DEST=… bin/arbiter eval Arbiter.Release.Backup.eval_from_env

  which prints one JSON line and exits non-zero on failure.
  """

  alias Exqlite.Sqlite3

  @type result :: {:ok, %{path: String.t(), bytes: non_neg_integer()}} | {:error, term()}

  @doc "Back `src` up to `dest`. Fails closed: no `dest` is left behind on any error."
  @spec take(String.t(), String.t()) :: result()
  def take(src, dest) do
    partial = dest <> ".partial"

    with :ok <- check_source(src),
         :ok <- check_dest(dest),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         _ <- File.rm(partial),
         :ok <- vacuum_into(src, partial),
         :ok <- integrity_check(partial),
         :ok <- File.rename(partial, dest) do
      {:ok, %{path: dest, bytes: File.stat!(dest).size}}
    else
      {:error, _} = error ->
        _ = File.rm(partial)
        error
    end
  end

  @doc "Run `PRAGMA integrity_check` on the database file at `path`; `:ok` only on a lone `ok`."
  @spec integrity_check(String.t()) :: :ok | {:error, term()}
  def integrity_check(path) do
    with {:ok, conn} <- open(path, :readonly) do
      try do
        case query_rows(conn, "PRAGMA integrity_check") do
          {:ok, [["ok"]]} -> :ok
          {:ok, rows} -> {:error, {:integrity_check, rows |> List.flatten() |> Enum.take(5)}}
          {:error, _} = error -> error
        end
      after
        Sqlite3.close(conn)
      end
    end
  end

  @doc """
  The `bin/arbiter eval` entrypoint: reads `ARB_BACKUP_SRC` / `ARB_BACKUP_DEST`,
  prints one JSON line, and halts non-zero on failure.
  """
  @spec eval_from_env() :: no_return()
  def eval_from_env do
    src = System.get_env("ARB_BACKUP_SRC")
    dest = System.get_env("ARB_BACKUP_DEST")

    result =
      if is_binary(src) and src != "" and is_binary(dest) and dest != "",
        do: take(src, dest),
        else: {:error, :missing_env}

    case result do
      {:ok, %{path: path, bytes: bytes}} ->
        IO.puts(Jason.encode!(%{ok: true, path: path, bytes: bytes}))
        System.halt(0)

      {:error, reason} ->
        IO.puts(Jason.encode!(%{ok: false, error: inspect(reason)}))
        System.halt(1)
    end
  end

  # ---- internals -------------------------------------------------------------

  defp check_source(src) do
    if File.regular?(src), do: :ok, else: {:error, {:source_missing, src}}
  end

  defp check_dest(dest) do
    if File.exists?(dest), do: {:error, {:dest_exists, dest}}, else: :ok
  end

  defp vacuum_into(src, partial) do
    with {:ok, conn} <- open(src, :readwrite) do
      try do
        Sqlite3.execute(conn, "VACUUM INTO '#{String.replace(partial, "'", "''")}'")
      after
        Sqlite3.close(conn)
      end
    end
  end

  # `:readwrite` rather than `:readonly` for the source: a WAL database opened
  # read-only cannot create its `-shm` if the server is down, and VACUUM INTO
  # needs a normal connection. The connection only ever reads.
  defp open(path, mode) do
    case Sqlite3.open(path, mode: mode) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:open, reason}}
    end
  end

  defp query_rows(conn, sql) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        Sqlite3.fetch_all(conn, stmt)
      after
        Sqlite3.release(conn, stmt)
      end
    end
  end
end
