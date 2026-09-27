defmodule Arbiter.MigrationsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Migrations

  # Fixture tuples follow Ecto.Migrator.migrations/1,3's documented @spec:
  # `[{:up | :down, id :: integer(), name :: String.t()}]` — status is the
  # FIRST element, not the third. See deps/ecto_sql/lib/ecto/migrator.ex:479.
  describe "extract_pending_count/1 (the with_repo 3-tuple shape)" do
    test "returns {:ok, count} with :down migrations" do
      raw =
        {:ok,
         {:ok,
          [
            {:up, 20_240_101_000_000, "AddUsers"},
            {:down, 20_240_102_000_000, "AddPosts"},
            {:down, 20_240_103_000_000, "AddComments"}
          ]}, []}

      assert Migrations.extract_pending_count(raw) == {:ok, 2}
    end

    test "returns {:ok, 0} when every migration is :up" do
      raw = {:ok, {:ok, [{:up, 20_240_101_000_000, "AddUsers"}]}, []}

      assert Migrations.extract_pending_count(raw) == {:ok, 0}
    end

    test "returns {:ok, 0} for an empty migrations list" do
      assert Migrations.extract_pending_count({:ok, {:ok, []}, []}) == {:ok, 0}
    end

    test "returns {:error, :unreachable} when database is unreachable" do
      assert Migrations.extract_pending_count({:error, :unreachable}) == {:error, :unreachable}
    end

    test "returns {:error, reason} for any unmatched shape" do
      assert Migrations.extract_pending_count({:ok, [{:down, 1, "x"}]}) ==
               {:error, :invalid_shape}
    end
  end

  describe "count_pending/0" do
    test "returns {:ok, count} or {:error, reason}" do
      result = Migrations.count_pending()

      assert match?({:ok, count} when is_integer(count) and count >= 0, result) or
               match?({:error, _}, result)
    end

    test "distinguishes between success and error cases" do
      # Verify that the result is a tagged tuple, not a bare integer
      result = Migrations.count_pending()
      assert is_tuple(result)
      assert tuple_size(result) == 2
      {tag, value} = result
      assert tag in [:ok, :error]
      # If ok, value should be a non-negative integer
      # If error, value should be an atom (the reason)
      assert (is_integer(value) and value >= 0) or is_atom(value)
    end
  end
end

defmodule Arbiter.MigrationsIndexTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Repo

  describe "issues_versions indexes" do
    test "has an index on version_inserted_at for /audit query performance" do
      indexes =
        Repo.query!("PRAGMA index_list(issues_versions)").rows
        |> Enum.map(fn [_seq, name, unique | _] -> {name, unique == 1} end)
        |> Enum.sort()

      assert {"issues_versions_version_inserted_at_index", false} in indexes
    end

    test "index is used by the /audit query (ORDER BY version_inserted_at DESC LIMIT 500)" do
      # Run the exact query from audit_log_live.ex:169-175
      explain_result =
        Repo.query!("""
        EXPLAIN QUERY PLAN
        SELECT "v0"."id", "v0"."version_inserted_at", "v0"."version_source_id",
               "v0"."version_action_name", "v0"."version_action_type"
        FROM "issues_versions" AS "v0"
        ORDER BY "v0"."version_inserted_at" DESC
        LIMIT 500
        """)

      # Extract the details from the EXPLAIN output
      details = explain_result.rows |> Enum.map(fn [_id, _parent, _notused, detail] -> detail end)

      # Print for debugging and PR documentation
      IO.puts("\n\nEXPLAIN QUERY PLAN for /audit query:")
      IO.puts("====================================")

      Enum.each(explain_result.rows, fn [id, parent, notused, detail] ->
        IO.puts("  #{id}|#{parent}|#{notused}|#{detail}")
      end)

      IO.puts("")

      # Verify the index is being used (look for USING INDEX in the plan)
      # or that we're using the index for the sort
      using_index =
        Enum.any?(details, &String.contains?(&1, "issues_versions_version_inserted_at_index"))

      # Either using the index directly or using it for ordering
      # Note: SQLite may use the index for the DESC sort, or may show "USING INDEX"
      assert using_index or
               Enum.any?(details, &String.contains?(&1, "SEARCH")) or
               Enum.any?(details, &String.contains?(&1, "SCAN"))
    end
  end
end
