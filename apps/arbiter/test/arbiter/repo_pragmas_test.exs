defmodule Arbiter.RepoPragmasTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Repo

  test "SQLite connection pragmas cache_size and temp_store are configured" do
    # When cache_size is set to -64000, PRAGMA cache_size returns either -64000
    # or the page count corresponding to 64000 KiB depending on SQLite version/connection.
    {:ok, %{rows: [[cache_size]]}} = Repo.query("PRAGMA cache_size")
    # PRAGMA temp_store returns 2 for MEMORY (0 = DEFAULT, 1 = FILE, 2 = MEMORY)
    {:ok, %{rows: [[temp_store]]}} = Repo.query("PRAGMA temp_store")

    assert temp_store == 2
    assert cache_size == -64000
  end
end
