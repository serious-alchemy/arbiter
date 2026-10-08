defmodule Arbiter.Server.StatusTest do
  use ExUnit.Case, async: true

  alias Arbiter.Server.Status

  describe "version/0" do
    test "carries the version stamp and the update block, and no host paths" do
      v = Status.version()

      assert Enum.sort(Map.keys(v)) ==
               Enum.sort([:version, :sha, :built_at, :booted_at, :release_repo, :update])

      assert {:ok, _, _} = DateTime.from_iso8601(v.booted_at)

      assert Enum.sort(Map.keys(v.update)) ==
               Enum.sort([
                 :enabled,
                 :latest,
                 :release_url,
                 :checked_at,
                 :update_available,
                 :migrations_pending,
                 :error
               ])
    end
  end

  describe "migrations/0" do
    test "maps the pending count to a status" do
      case Arbiter.Migrations.count_pending() do
        {:ok, 0} -> assert %{status: "ok", pending_count: 0} = Status.migrations()
        {:ok, n} -> assert %{status: "warning", pending_count: ^n} = Status.migrations()
        {:error, _} -> assert %{status: "unknown", pending_count: nil} = Status.migrations()
      end
    end
  end

  describe "snapshot/0" do
    test "is the version read plus the migration read under `migrations`" do
      s = Status.snapshot()
      assert s.migrations == Status.migrations()
      assert s.version == Status.version().version
      assert Map.has_key?(s, :update)
    end
  end
end
