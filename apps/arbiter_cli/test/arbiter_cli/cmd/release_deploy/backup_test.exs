defmodule ArbiterCli.Cmd.ReleaseDeploy.BackupTest do
  # async: false — mutates ARB_DATA_HOME / DATABASE_PATH / ARB_DEPLOY_BACKUP_RETAIN.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.ReleaseDeploy.Backup

  @magic "SQLite format 3\0"

  setup do
    home = Path.join(System.tmp_dir!(), "arb-bk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    System.put_env("ARB_DATA_HOME", home)
    System.delete_env("DATABASE_PATH")
    System.delete_env("ARB_DEPLOY_BACKUP_RETAIN")

    on_exit(fn ->
      System.delete_env("ARB_DATA_HOME")
      System.delete_env("DATABASE_PATH")
      System.delete_env("ARB_DEPLOY_BACKUP_RETAIN")
      File.rm_rf(home)
    end)

    release_dir = Path.join(home, "releases/v2")
    File.mkdir_p!(Path.join(release_dir, "bin"))
    File.write!(Path.join(release_dir, "bin/arbiter"), "#!/bin/sh\n")

    {:ok, home: home, release_dir: release_dir, db: Path.join(home, "arbiter.sqlite3")}
  end

  # A runner standing in for `bin/arbiter eval Arbiter.Release.Backup.…`: it
  # honours the same contract (reads ARB_BACKUP_DEST, writes it, exit 0).
  defp backup_runner(opts \\ []) do
    test_pid = self()
    content = Keyword.get(opts, :content, @magic <> "snapshot")
    exit_code = Keyword.get(opts, :exit_code, 0)
    write? = Keyword.get(opts, :write, true)

    Process.put(:bd2_cmd_runner, fn cmd, args, run_opts ->
      send(test_pid, {:cmd, cmd, args, run_opts})
      env = Map.new(Keyword.get(run_opts, :env, []))

      if write? and exit_code == 0 do
        File.mkdir_p!(Path.dirname(env["ARB_BACKUP_DEST"]))
        File.write!(env["ARB_BACKUP_DEST"], content)
      end

      {Jason.encode!(%{ok: exit_code == 0}), exit_code}
    end)
  end

  describe "db_path/0" do
    test "DATABASE_PATH wins", %{home: home} do
      System.put_env("DATABASE_PATH", "/srv/arb/a.sqlite3")
      File.write!(Path.join(home, "arbiter.env"), "DATABASE_PATH=/other.sqlite3\n")
      assert Backup.db_path() == "/srv/arb/a.sqlite3"
    end

    test "then the service's arbiter.env", %{home: home} do
      File.write!(
        Path.join(home, "arbiter.env"),
        "# c\nexport DATABASE_PATH=\"/srv/env/b.sqlite3\"\nPATH=/bin\n"
      )

      assert Backup.db_path() == "/srv/env/b.sqlite3"
    end

    test "then <data-home>/arbiter.sqlite3", %{home: home} do
      assert Backup.db_path() == Path.join(home, "arbiter.sqlite3")
    end
  end

  describe "take/2" do
    test "is skipped when there is no database yet (fresh host)", %{release_dir: rd} do
      assert Backup.take(rd, "v2") == :skipped
    end

    test "backs up through the release's own binary into <data-home>/snapshots",
         %{home: home, release_dir: rd, db: db} do
      File.write!(db, @magic <> "live")
      backup_runner()

      assert {:ok, %{path: path, bytes: bytes, db: ^db}} = Backup.take(rd, "v2")

      assert Path.dirname(path) == Path.join(home, "snapshots")
      assert Path.basename(path) =~ ~r/\Aarbiter-pre-v2-\d{8}T\d{6}Z\.sqlite3\z/
      assert File.read!(path) == @magic <> "snapshot"
      assert bytes == byte_size(@magic <> "snapshot")

      bin = Path.join(rd, "bin/arbiter")
      assert_received {:cmd, ^bin, ["eval", "Arbiter.Release.Backup.eval_from_env()"], opts}
      env = Map.new(opts[:env])
      assert env["ARB_BACKUP_SRC"] == db
      assert env["ARB_BACKUP_DEST"] == path
    end

    test "gives the eval the service's environment file (runtime.exs needs it)",
         %{home: home, release_dir: rd, db: db} do
      File.write!(db, @magic)
      File.write!(Path.join(home, "arbiter.env"), "SECRET_KEY_BASE=abc123\nFOO='bar baz'\n")
      backup_runner()

      assert {:ok, _} = Backup.take(rd, "v2")

      assert_received {:cmd, _, _, opts}
      env = Map.new(opts[:env])
      assert env["SECRET_KEY_BASE"] == "abc123"
      assert env["FOO"] == "bar baz"
    end

    test "a failing eval aborts with an error and leaves no snapshot",
         %{home: home, release_dir: rd, db: db} do
      File.write!(db, @magic)
      backup_runner(exit_code: 1)

      assert {:error, msg} = Backup.take(rd, "v2")
      assert msg =~ "backup"
      assert Path.wildcard(Path.join(home, "snapshots/*.sqlite3")) == []
    end

    test "an eval that exits 0 without producing the file is an error",
         %{release_dir: rd, db: db} do
      File.write!(db, @magic)
      backup_runner(write: false)

      assert {:error, msg} = Backup.take(rd, "v2")
      assert msg =~ "no snapshot"
    end

    test "a snapshot that is not an SQLite file is rejected and removed",
         %{home: home, release_dir: rd, db: db} do
      File.write!(db, @magic)
      backup_runner(content: "garbage")

      assert {:error, msg} = Backup.take(rd, "v2")
      assert msg =~ "SQLite"
      assert Path.wildcard(Path.join(home, "snapshots/*.sqlite3")) == []
    end
  end

  describe "restore!/3" do
    test "replaces the database, keeping the failed one (and its WAL) aside",
         %{home: home, db: db} do
      snapshots = Path.join(home, "snapshots")
      File.mkdir_p!(snapshots)
      backup = Path.join(snapshots, "arbiter-pre-v2-20260101T000000Z.sqlite3")
      File.write!(backup, @magic <> "good")

      File.write!(db, @magic <> "migrated-by-bad-release")
      File.write!(db <> "-wal", "wal-frames")
      File.write!(db <> "-shm", "shm")

      assert {:ok, %{failed_db: failed}} = Backup.restore!(backup, db, "v2")

      assert File.read!(db) == @magic <> "good"
      refute File.exists?(db <> "-wal")
      refute File.exists?(db <> "-shm")

      # Nothing is deleted: the post-failure database is preserved.
      assert File.read!(failed) == @magic <> "migrated-by-bad-release"
      assert File.read!(failed <> "-wal") == "wal-frames"
      assert Path.dirname(failed) == snapshots
      assert Path.basename(failed) =~ ~r/\Aarbiter-failed-v2-\d{8}T\d{6}Z\.sqlite3\z/

      # The snapshot itself survives, so the restore can be repeated.
      assert File.read!(backup) == @magic <> "good"
    end

    test "restores onto a missing database (the bad release removed or never wrote it)",
         %{home: home, db: db} do
      backup = Path.join(home, "b.sqlite3")
      File.write!(backup, @magic <> "good")

      assert {:ok, %{failed_db: nil}} = Backup.restore!(backup, db, "v2")
      assert File.read!(db) == @magic <> "good"
    end

    test "refuses a missing or non-SQLite snapshot and leaves the database untouched",
         %{home: home, db: db} do
      File.write!(db, @magic <> "live")

      assert_raise ArbiterCli.Output.Halt, fn ->
        capture_io(:stderr, fn -> Backup.restore!(Path.join(home, "nope"), db, "v2") end)
      end

      bad = Path.join(home, "bad.sqlite3")
      File.write!(bad, "not sqlite")

      assert_raise ArbiterCli.Output.Halt, fn ->
        capture_io(:stderr, fn -> Backup.restore!(bad, db, "v2") end)
      end

      assert File.read!(db) == @magic <> "live"
    end
  end

  describe "prune/2" do
    test "keeps the N newest pre-deploy snapshots (default 5) and the one just taken", %{
      home: home
    } do
      snapshots = Path.join(home, "snapshots")
      File.mkdir_p!(snapshots)

      names =
        for i <- 1..8 do
          name = "arbiter-pre-v#{i}-2026010#{i}T000000Z.sqlite3"
          File.write!(Path.join(snapshots, name), @magic)
          name
        end

      File.write!(Path.join(snapshots, "unrelated.txt"), "keep me")

      removed = Backup.prune(snapshots, Path.join(snapshots, List.last(names)))

      assert Enum.sort(removed) == Enum.sort(Enum.take(names, 3))
      remaining = snapshots |> File.ls!() |> Enum.sort()
      assert "unrelated.txt" in remaining

      assert Enum.filter(remaining, &String.starts_with?(&1, "arbiter-pre-")) ==
               Enum.drop(names, 3)
    end

    test "ARB_DEPLOY_BACKUP_RETAIN configures the count", %{home: home} do
      System.put_env("ARB_DEPLOY_BACKUP_RETAIN", "2")
      snapshots = Path.join(home, "snapshots")
      File.mkdir_p!(snapshots)

      for i <- 1..4,
          do:
            File.write!(
              Path.join(snapshots, "arbiter-pre-v#{i}-2026010#{i}T000000Z.sqlite3"),
              "x"
            )

      Backup.prune(snapshots, nil)
      assert length(File.ls!(snapshots)) == 2
    end

    test "a nonsense retain value falls back to the default", %{home: home} do
      System.put_env("ARB_DEPLOY_BACKUP_RETAIN", "zero")
      assert Backup.retain() == 5
      System.put_env("ARB_DEPLOY_BACKUP_RETAIN", "0")
      assert Backup.retain() == 5
      _ = home
    end
  end
end
