defmodule Arbiter.RepoBootTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp config(path), do: [database: path, pool_size: 5, journal_mode: :wal]

  test "a DATABASE_PATH that does not exist is created non-empty before the pool starts",
       %{tmp_dir: dir} do
    path = Path.join(dir, "fresh.sqlite3")
    refute File.exists?(path)

    assert {:ok, _} = Arbiter.Repo.init(:supervisor, config(path))
    assert File.stat!(path).size > 0

    # A restart of the repo (second init) must not trip the empty-file guard.
    assert {:ok, _} = Arbiter.Repo.init(:supervisor, config(path))
  end

  test "a real multi-connection pool boots cleanly against a fresh path", %{tmp_dir: dir} do
    path = Path.join(dir, "pool.sqlite3")
    refute File.exists?(path)

    pid =
      start_supervised!(
        {Arbiter.Repo,
         name: :repo_boot_test_pool, database: path, pool_size: 5, journal_mode: :wal}
      )

    assert Process.alive?(pid)
    assert File.stat!(path).size > 0

    results =
      1..10
      |> Task.async_stream(
        fn _ -> Ecto.Adapters.SQL.query(pid, "SELECT 1", []) end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, %{rows: [[1]]}}, &1))
  end

  test "a 0-byte file that existed before boot is still refused", %{tmp_dir: dir} do
    path = Path.join(dir, "empty.sqlite3")
    File.write!(path, "")

    assert_raise RuntimeError, ~r/refusing to boot — DB file exists but is empty/, fn ->
      Arbiter.Repo.init(:supervisor, config(path))
    end

    assert File.stat!(path).size == 0
  end
end
