defmodule ArbiterCli.Cmd.ReleaseDeploy.Backup do
  @moduledoc """
  The database safety net around `arb server deploy`'s symlink swap.

  A release that adds migrations migrates the database on its own boot, so once
  it has booted the prior release can no longer be put back on that schema. The
  deploy therefore takes an online, integrity-checked snapshot of the SQLite
  database **before** the swap (`take/2`), and a failed deploy of such a release
  restores it (`restore!/3`).

  ## Taking the snapshot

  The arb escript carries no SQLite NIF, so the copy is made by the release
  being deployed, through its own binary (`Arbiter.Release.Backup`): an
  `eval` that runs `VACUUM INTO` on a normal connection (consistent against the
  live WAL-mode database) and `PRAGMA integrity_check` on the *copy*, exiting
  non-zero if either fails. The eval needs the service's environment
  (`runtime.exs` raises without `SECRET_KEY_BASE`), so `<data-home>/arbiter.env`
  is passed through. Snapshots land in `<data-home>/snapshots/` as
  `arbiter-pre-<tag>-<utc>.sqlite3`; the newest `retain/0` are kept.

  ## Restoring it

  Only ever with the service stopped (SQLite has one writer). Nothing is
  deleted: the database the failed release left behind, and its `-wal`, are
  moved aside as `arbiter-failed-<tag>-<utc>.sqlite3[-wal]` before the snapshot
  is copied into place (temp file + rename, so the live path is never
  half-written). The snapshot itself is kept so a restore can be repeated.

  What a restore costs: writes the *old* release made between the snapshot and
  the stop. The snapshot is taken immediately before the swap, so that window is
  the swap-to-restart gap, seconds.
  """

  alias ArbiterCli.Cmd.{ReleaseDeploy.ReleaseFiles, Start}
  alias ArbiterCli.Output

  @sqlite_magic "SQLite format 3\0"
  @default_retain 5
  @eval "Arbiter.Release.Backup.eval_from_env()"

  # ---- locations --------------------------------------------------------------

  @doc "The SQLite database file the service runs on."
  @spec db_path() :: String.t()
  def db_path do
    case System.get_env("DATABASE_PATH") do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case Map.get(env_file(), "DATABASE_PATH") do
          path when is_binary(path) and path != "" -> path
          _ -> Path.join(ReleaseFiles.data_home(), "arbiter.sqlite3")
        end
    end
  end

  @spec snapshots_dir() :: String.t()
  def snapshots_dir, do: Path.join(ReleaseFiles.data_home(), "snapshots")

  @doc "How many snapshots to keep (`ARB_DEPLOY_BACKUP_RETAIN`, default #{@default_retain})."
  @spec retain() :: pos_integer()
  def retain do
    case Integer.parse(System.get_env("ARB_DEPLOY_BACKUP_RETAIN", "")) do
      {n, ""} when n >= 1 -> n
      _ -> @default_retain
    end
  end

  # ---- take -----------------------------------------------------------------

  @type taken :: %{path: String.t(), bytes: non_neg_integer(), db: String.t()}

  @doc """
  Snapshot the live database using `release_dir`'s binary. `:skipped` when there
  is no database file yet (a fresh host); `{:error, message}` when the snapshot
  or its integrity check failed — the caller must abort the deploy.
  """
  @spec take(String.t(), String.t()) :: :skipped | {:ok, taken()} | {:error, String.t()}
  def take(release_dir, tag) do
    db = db_path()

    if File.regular?(db) do
      do_take(release_dir, tag, db)
    else
      :skipped
    end
  end

  defp do_take(release_dir, tag, db) do
    dest = Path.join(snapshots_dir(), "arbiter-pre-#{tag}-#{utc_stamp()}.sqlite3")
    File.mkdir_p!(snapshots_dir())

    env =
      Enum.to_list(env_file()) ++ [{"ARB_BACKUP_SRC", db}, {"ARB_BACKUP_DEST", dest}]

    bin = Path.join(release_dir, "bin/arbiter")

    {out, code} =
      try do
        Start.run_cmd(bin, ["eval", @eval], env: env, stderr_to_stdout: true)
      rescue
        e in ErlangError -> {"could not run #{bin}: #{inspect(e.original)}", 127}
      end

    cond do
      code != 0 ->
        _ = File.rm(dest)
        {:error, "database backup failed (exit #{code}): #{scrub(out, env)}"}

      not File.regular?(dest) ->
        {:error, "database backup reported success but wrote no snapshot at #{dest}"}

      not sqlite_file?(dest) ->
        _ = File.rm(dest)
        {:error, "database backup at #{dest} is not an SQLite file; discarded it"}

      true ->
        {:ok, %{path: dest, bytes: File.stat!(dest).size, db: db}}
    end
  end

  # ---- restore ---------------------------------------------------------------

  @doc """
  Put `backup` back as `db`. The service **must already be stopped**. Returns
  `{:ok, %{failed_db: path | nil}}` — where the replaced database was kept.
  """
  @spec restore!(String.t(), String.t(), String.t()) :: {:ok, %{failed_db: String.t() | nil}}
  def restore!(backup, db, tag) do
    unless File.regular?(backup) and sqlite_file?(backup) do
      Output.die(
        "refusing to restore #{backup}: not a readable SQLite snapshot",
        "The database at #{db} was left untouched."
      )
    end

    failed_db = move_aside(db, tag)

    tmp = db <> ".restoring"
    File.mkdir_p!(Path.dirname(db))
    File.cp!(backup, tmp)
    File.rename!(tmp, db)

    {:ok, %{failed_db: failed_db}}
  end

  defp move_aside(db, tag) do
    present = Enum.filter([db, db <> "-wal", db <> "-shm"], &File.exists?/1)

    if db in present do
      dir =
        if File.dir?(snapshots_dir()) or File.mkdir_p(snapshots_dir()) == :ok,
          do: snapshots_dir(),
          else: Path.dirname(db)

      failed = Path.join(dir, "arbiter-failed-#{tag}-#{utc_stamp()}.sqlite3")

      for src <- present do
        suffix = String.replace_prefix(src, db, "")
        move!(src, failed <> suffix)
      end

      failed
    else
      # No main file: a stray -wal/-shm would be replayed onto the restored
      # database, so they go regardless.
      Enum.each(present, &File.rm!/1)
      nil
    end
  end

  # rename(2) across filesystems fails with :exdev; fall back to copy + delete.
  defp move!(src, dest) do
    case File.rename(src, dest) do
      :ok ->
        :ok

      {:error, :exdev} ->
        File.cp!(src, dest)
        File.rm!(src)

      {:error, reason} ->
        Output.die("could not move #{src} aside to #{dest}: #{inspect(reason)}")
    end
  end

  # ---- retention -------------------------------------------------------------

  @doc """
  Delete all but the newest `retain/0` of each snapshot kind in `dir`, never the
  `keep` path. Returns the removed file names.
  """
  @spec prune(String.t(), String.t() | nil) :: [String.t()]
  def prune(dir, keep) do
    ["arbiter-pre-", "arbiter-failed-"]
    |> Enum.flat_map(fn prefix -> prune_kind(dir, prefix, keep) end)
  end

  defp prune_kind(dir, prefix, keep) do
    names =
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".sqlite3")))
          |> Enum.sort_by(&stamp_of/1)

        {:error, _} ->
          []
      end

    names
    |> Enum.drop(-retain())
    |> Enum.reject(&(Path.join(dir, &1) == keep))
    |> Enum.filter(fn name ->
      path = Path.join(dir, name)
      _ = File.rm(path <> "-wal")
      _ = File.rm(path <> "-shm")
      File.rm(path) == :ok
    end)
  end

  # `arbiter-pre-<tag>-<stamp>.sqlite3` → `<stamp>` (UTC, sorts chronologically).
  defp stamp_of(name) do
    case Regex.run(~r/-(\d{8}T\d{6}Z)\.sqlite3\z/, name) do
      [_, stamp] -> stamp
      _ -> name
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp utc_stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

  defp sqlite_file?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        header = IO.binread(io, byte_size(@sqlite_magic))
        File.close(io)
        header == @sqlite_magic

      {:error, _} ->
        false
    end
  end

  # The service's `EnvironmentFile=` (KEY=VALUE lines): what the eval needs to
  # get through `runtime.exs`. systemd's quoting is a superset of this; the file
  # `arb install service` writes only ever holds plain or single/double-quoted
  # values.
  defp env_file do
    path = Path.join(ReleaseFiles.data_home(), "arbiter.env")

    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_env_line/1)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  defp parse_env_line(line) do
    line = line |> String.trim() |> String.replace_prefix("export ", "")

    with false <- String.starts_with?(line, "#"),
         [key, value] <- String.split(line, "=", parts: 2),
         true <- Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key) do
      [{key, unquote_env(String.trim(value))}]
    else
      _ -> []
    end
  end

  defp unquote_env("\"" <> rest = v),
    do: if(String.ends_with?(rest, "\""), do: String.slice(rest, 0..-2//1), else: v)

  defp unquote_env("'" <> rest = v),
    do: if(String.ends_with?(rest, "'"), do: String.slice(rest, 0..-2//1), else: v)

  defp unquote_env(v), do: v

  # Command output is shown to the operator; never echo an env value (secret key
  # base, GITHUB_TOKEN) the eval might have printed.
  defp scrub(out, env) do
    env
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 8))
    |> Enum.reduce(String.trim(out), fn secret, acc ->
      String.replace(acc, secret, "[redacted]")
    end)
    |> String.slice(0, 600)
  end
end
