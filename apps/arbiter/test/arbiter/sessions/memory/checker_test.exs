defmodule Arbiter.Sessions.Memory.CheckerTest do
  @moduledoc """
  The asynchronous half of the staleness checker (bd-19qve3, amendments 3
  and 4): `Checker.run/1` persists one verdict per memory and quarantines the
  stale ones by moving them out of the served directory; the GenServer runs it
  on a timer and when a mount nudges it, never on the mount path itself.
  """
  use ExUnit.Case, async: false

  import Arbiter.Test.MemoryFixture

  alias Arbiter.Sessions.Memory.Checker
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Verdicts

  @moduletag :tmp_dir

  @short "defmodule Short do\n  def hello, do: :world\nend\n"
  @t0 ~U[2026-10-02 12:00:00.000000Z]

  setup %{tmp_dir: tmp_dir} do
    checkout = checkout!(%{"lib/short.ex" => @short, "README.md" => "readme\n"})
    root = Path.join(tmp_dir, "memory")
    File.mkdir_p!(root)

    {:ok,
     root: root,
     checkout: checkout,
     opts: [memory_root: root, checkouts: [checkout], ticket_prefixes: [], now: @t0]}
  end

  defp quarantined(root, name), do: Path.join([root, "quarantined", name])

  describe "run/1" do
    test "persists a verdict per memory and quarantines only the stale ones", ctx do
      write_memory!(ctx.root, "good.md", "project", "See lib/short.ex:2.")
      write_memory!(ctx.root, "stale.md", "project", "See lib/short.ex:99.")
      write_memory!(ctx.root, "habit.md", "feedback", "Prefer small PRs.")

      summary = Checker.run(ctx.opts)

      assert Enum.sort(summary.verified) == ["good.md", "habit.md", "stale.md"]
      assert summary.quarantined == [{"stale.md", "stale.md"}]

      assert {:ok, %{status: :ok}} = Verdicts.read(ctx.root, "good.md")
      assert {:ok, %{status: :ok}} = Verdicts.read(ctx.root, "habit.md")
      assert Verdicts.read(ctx.root, "stale.md") == :none

      refute File.exists?(Path.join(ctx.root, "stale.md"))
      assert File.regular?(quarantined(ctx.root, "stale.md"))
    end

    # Round-4 finding 3: the quarantine fields are inserted, never rebuilt, so
    # `metadata.type` stays nested and the file can be restored as it was.
    test "a quarantined file keeps its nesting and records reason, sha and time", ctx do
      write_memory!(ctx.root, "stale.md", "project", "See lib/short.ex:99.", workspace_id: "ws-1")
      original = File.read!(Path.join(ctx.root, "stale.md"))

      Checker.run(ctx.opts)

      moved = File.read!(quarantined(ctx.root, "stale.md"))
      assert moved =~ "metadata:\n  type: project\n  workspace_id: ws-1\n"

      fields = Frontmatter.fields(moved)
      assert fields["quarantine_reason"] =~ "lib/short.ex:99"
      assert fields["quarantine_sha"] == head!(ctx.checkout)
      assert fields["quarantined_at"] == DateTime.to_iso8601(@t0)
      assert fields["quarantined_from"] == "stale.md"

      stripped =
        Frontmatter.drop(
          moved,
          ~w(quarantine_reason quarantine_sha quarantined_at quarantined_from)
        )

      assert stripped == original
    end

    test "a current verdict is not re-verified", ctx do
      write_memory!(ctx.root, "good.md", "project", "See lib/short.ex:2.")
      Checker.run(ctx.opts)

      later = DateTime.add(@t0, 60, :second)
      summary = Checker.run(Keyword.put(ctx.opts, :now, later))

      assert summary.verified == []
      assert summary.skipped == ["good.md"]
      assert {:ok, %{checked_at: @t0}} = Verdicts.read(ctx.root, "good.md")
    end

    test "a moved HEAD re-verifies, and catches code that went away", ctx do
      write_memory!(ctx.root, "good.md", "project", "See lib/short.ex:2.")
      Checker.run(ctx.opts)

      commit!(ctx.checkout, %{"lib/short.ex" => :delete})
      summary = Checker.run(ctx.opts)

      assert summary.verified == ["good.md"]
      assert summary.quarantined == [{"good.md", "good.md"}]
    end

    test "an edited memory is re-verified before it can serve again", ctx do
      path = write_memory!(ctx.root, "good.md", "project", "See lib/short.ex:2.")
      Checker.run(ctx.opts)

      File.write!(path, File.read!(path) <> "\nAlso lib/short.ex:3.\n")
      summary = Checker.run(ctx.opts)

      assert summary.verified == ["good.md"]
      assert {:ok, verdict} = Verdicts.read(ctx.root, "good.md")

      assert verdict.content_sha256 ==
               Arbiter.Sessions.Memory.Staleness.content_hash(File.read!(path))
    end

    test "decay tracks type: project and reference re-check past max age, feedback never does",
         ctx do
      write_memory!(ctx.root, "proj.md", "project", "See lib/short.ex:2.")
      write_memory!(ctx.root, "ref.md", "reference", "Ticket-free pointer: lib/short.ex:1.")
      write_memory!(ctx.root, "habit.md", "feedback", "Cites lib/short.ex:2 too.")
      opts = Keyword.put(ctx.opts, :max_age_ms, :timer.hours(24))
      Checker.run(opts)

      summary = Checker.run(Keyword.put(opts, :now, DateTime.add(@t0, 2, :day)))

      assert Enum.sort(summary.verified) == ["proj.md", "ref.md"]
      assert summary.skipped == ["habit.md"]
    end

    test "an unverified verdict is retried on every run", ctx do
      write_memory!(ctx.root, "proj.md", "project", "See lib/short.ex:2.")
      opts = Keyword.put(ctx.opts, :checkouts, [])

      Checker.run(opts)
      assert {:ok, %{status: :unverified}} = Verdicts.read(ctx.root, "proj.md")

      assert Checker.run(ctx.opts).verified == ["proj.md"]
      assert {:ok, %{status: :ok}} = Verdicts.read(ctx.root, "proj.md")
    end

    test "a second quarantine of the same name does not clobber the first", ctx do
      write_memory!(ctx.root, "stale.md", "project", "See lib/short.ex:99.")
      Checker.run(ctx.opts)
      write_memory!(ctx.root, "stale.md", "project", "See lib/short.ex:98.")

      %{quarantined: [{"stale.md", second}]} = Checker.run(ctx.opts)

      assert second != "stale.md"
      assert File.read!(quarantined(ctx.root, "stale.md")) =~ "lib/short.ex:99"
      assert File.read!(quarantined(ctx.root, second)) =~ "lib/short.ex:98"

      assert Frontmatter.fields(File.read!(quarantined(ctx.root, second)))["quarantined_from"] ==
               "stale.md"
    end

    test "an unreadable memory is reported, not fatal", ctx do
      path = write_memory!(ctx.root, "locked.md", "user", "x")
      write_memory!(ctx.root, "fine.md", "user", "y")
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o644) end)

      summary = Checker.run(ctx.opts)

      assert summary.failed == ["locked.md"]
      assert summary.verified == ["fine.md"]
    end

    test "a missing memory root is an empty run", ctx do
      summary = Checker.run(Keyword.put(ctx.opts, :memory_root, Path.join(ctx.root, "nope")))
      assert summary == %{verified: [], skipped: [], quarantined: [], failed: []}
    end
  end

  describe "the checker process" do
    test "runs a pass when nudged, off the caller's path", ctx do
      write_memory!(ctx.root, "good.md", "project", "See lib/short.ex:2.")

      pid =
        start_supervised!(
          {Checker,
           name: nil,
           enabled: true,
           initial_delay_ms: :timer.hours(1),
           debounce_ms: 0,
           run_opts: ctx.opts}
        )

      assert :ok = Checker.request_check(pid)
      _ = :sys.get_state(pid)

      assert {:ok, %{status: :ok}} = Verdicts.read(ctx.root, "good.md")
    end

    test "runs a pass on its own schedule", ctx do
      write_memory!(ctx.root, "stale.md", "project", "See lib/short.ex:99.")

      pid =
        start_supervised!(
          {Checker,
           name: nil, enabled: true, initial_delay_ms: :timer.hours(1), run_opts: ctx.opts}
        )

      send(pid, :run)
      _ = :sys.get_state(pid)

      assert File.regular?(quarantined(ctx.root, "stale.md"))
    end

    test "a disabled checker never runs, even when nudged", ctx do
      write_memory!(ctx.root, "good.md", "project", "See lib/short.ex:2.")

      pid =
        start_supervised!(
          {Checker, name: nil, enabled: false, debounce_ms: 0, run_opts: ctx.opts}
        )

      assert :ok = Checker.request_check(pid)
      _ = :sys.get_state(pid)

      assert Verdicts.read(ctx.root, "good.md") == :none
    end

    test "nudging a checker that is not running is a no-op" do
      assert :ok = Checker.request_check(:no_such_memory_checker)
    end
  end
end
