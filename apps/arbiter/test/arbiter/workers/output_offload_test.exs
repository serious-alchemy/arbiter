defmodule Arbiter.Workers.OutputOffloadTest do
  # bd-6jcebm. The policy is "offload, never delete": a column is cleared only
  # when its on-disk counterpart is verified present, and the recent window and
  # the git-step outputs the Loop corpus reads are left alone.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker.{OutputLog, SessionArchive}
  alias Arbiter.Workers.{OutputOffload, Run, RunStep}

  @now ~U[2026-10-01 12:00:00.000000Z]

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "off-#{System.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"
      )

    Application.put_env(:arbiter, :output_log_root, root)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    :ok
  end

  defp run!(attrs) do
    {:ok, run} =
      Ash.create(
        Run,
        Map.merge(
          %{
            task_id: "bd-off-#{System.unique_integer([:positive])}",
            repo: "arbiter",
            state: :finished,
            outcome: :succeeded,
            started_at: ~U[2026-09-01 10:00:00.000000Z],
            completed_at: ~U[2026-09-01 11:00:00.000000Z],
            output_lines: ["a", "b"]
          },
          attrs
        )
      )

    run
  end

  defp step!(run, attrs \\ %{}) do
    {:ok, step} =
      Ash.create(
        RunStep,
        Map.merge(
          %{
            run_id: run.id,
            task_id: run.task_id,
            tool_use_id: "toolu_#{System.unique_integer([:positive])}",
            name: "Bash",
            is_error: false,
            input_summary: "mix test",
            output_summary: "1 test, 0 failures",
            occurred_at: ~U[2026-09-01 10:30:00.000000Z]
          },
          attrs
        )
      )

    step
  end

  defp log!(run), do: File.write!(OutputLog.path_for(run.id), "a\nb\nc\n")
  defp archive!(run), do: File.write!(SessionArchive.path_for(run.id), "gz")
  defp reload(%Run{id: id}), do: Ash.get!(Run, id)
  defp reload(%RunStep{id: id}), do: Ash.get!(RunStep, id)

  describe "output_lines" do
    test "is cleared when the durable transcript exists, kept when it does not" do
      with_log = run!(%{})
      without_log = run!(%{})
      log!(with_log)

      report = OutputOffload.sweep(now: @now)

      assert reload(with_log).output_lines == []
      assert reload(without_log).output_lines == ["a", "b"]
      assert report.lines_offloaded == 1
      assert report.lines_no_file == 1
    end

    test "an empty transcript file is not a verified copy" do
      run = run!(%{})
      File.write!(OutputLog.path_for(run.id), "")

      OutputOffload.sweep(now: @now)

      assert reload(run).output_lines == ["a", "b"]
    end

    test "leaves runs inside the retention window and runs still working" do
      recent = run!(%{completed_at: ~U[2026-09-30 11:00:00.000000Z]})
      working = run!(%{state: :working, completed_at: nil})
      log!(recent)
      log!(working)

      OutputOffload.sweep(now: @now)

      assert reload(recent).output_lines == ["a", "b"]
      assert reload(working).output_lines == ["a", "b"]
    end

    test "dry run reports without writing, and a re-run converges" do
      run = run!(%{})
      log!(run)

      assert %{apply?: false, lines_offloaded: 1} = OutputOffload.sweep(now: @now, apply?: false)
      assert reload(run).output_lines == ["a", "b"]

      assert %{lines_offloaded: 1} = OutputOffload.sweep(now: @now)
      assert %{lines_offloaded: 0, lines_scanned: 0} = OutputOffload.sweep(now: @now)
    end

    test "output_lines/1 falls back to the transcript tail for a finished run" do
      run = run!(%{})
      log!(run)
      OutputOffload.sweep(now: @now)

      assert OutputOffload.output_lines(reload(run)) == ["a", "b", "c"]
      assert OutputOffload.output_lines(%{reload(run) | state: :working}) == []
      assert OutputOffload.output_lines(run!(%{output_lines: ["x"]})) == ["x"]
    end
  end

  describe "output_summary" do
    test "is cleared when the session archive exists, kept when it does not" do
      archived = run!(%{})
      bare = run!(%{})
      archive!(archived)
      a = step!(archived)
      b = step!(bare)

      report = OutputOffload.sweep(now: @now)

      assert reload(a).output_summary == nil
      assert reload(b).output_summary == "1 test, 0 failures"
      assert report.steps_offloaded == 1
      assert report.steps_runs_no_file == 1
    end

    test "keeps the git-step output the Loop corpus reads, and the step row itself" do
      run = run!(%{})
      archive!(run)
      git = step!(run, %{input_summary: "git push origin HEAD", output_summary: "abc..def HEAD"})
      other = step!(run)

      OutputOffload.sweep(now: @now)

      assert reload(git).output_summary == "abc..def HEAD"
      assert reload(other).output_summary == nil
      assert reload(other).name == "Bash"
    end

    test "keeps the last 8 steps of a fix_pass run, which the Loop corpus reads" do
      fix = run!(%{kind: :fix_pass})
      archive!(fix)

      steps =
        for i <- 1..10 do
          step!(fix, %{occurred_at: DateTime.add(~U[2026-09-01 10:00:00.000000Z], i, :second)})
        end

      impl = run!(%{})
      archive!(impl)
      impl_steps = for _ <- 1..10, do: step!(impl)

      OutputOffload.sweep(now: @now)

      {old, kept} = Enum.split(steps, 2)
      assert Enum.all?(old, &(reload(&1).output_summary == nil))
      assert Enum.all?(kept, &(reload(&1).output_summary == "1 test, 0 failures"))
      assert Enum.all?(impl_steps, &(reload(&1).output_summary == nil))
    end

    test "leaves steps inside the retention window" do
      run = run!(%{})
      archive!(run)
      fresh = step!(run, %{occurred_at: ~U[2026-09-30 10:30:00.000000Z]})

      OutputOffload.sweep(now: @now)

      assert reload(fresh).output_summary == "1 test, 0 failures"
    end
  end

  describe "supervised sweeper" do
    setup do
      on_exit(fn -> Arbiter.Settings.set_output_offload_enabled(nil) end)
    end

    defp tick(opts) do
      pid =
        start_supervised!(
          {OutputOffload, opts ++ [name: nil, enabled: nil, initial_delay_ms: 3_600_000]},
          id: make_ref()
        )

      send(pid, :sweep)
      _ = :sys.get_state(pid)
      pid
    end

    test "runs the sweep itself on the primary instance, and not on a secondary" do
      run = run!(%{completed_at: ~U[2026-01-01 00:00:00.000000Z]})
      log!(run)

      tick(enabled: true, primary?: fn -> false end)
      assert reload(run).output_lines == ["a", "b"]

      tick(enabled: true, primary?: fn -> true end)
      assert reload(run).output_lines == []
    end

    test "never sweeps on a fresh install with no setting" do
      assert Arbiter.Settings.output_offload_enabled() == nil
      run = run!(%{completed_at: ~U[2026-01-01 00:00:00.000000Z]})
      log!(run)

      tick(primary?: fn -> true end)
      assert reload(run).output_lines == ["a", "b"]
    end

    test "the installation setting turns it on, and unsetting turns it off, with no restart" do
      run = run!(%{completed_at: ~U[2026-01-01 00:00:00.000000Z]})
      log!(run)

      pid =
        start_supervised!(
          {OutputOffload,
           name: nil, enabled: nil, initial_delay_ms: 3_600_000, primary?: fn -> true end}
        )

      {:ok, true} = Arbiter.Settings.set_output_offload_enabled(true)
      {:ok, false} = Arbiter.Settings.set_output_offload_enabled(false)
      send(pid, :sweep)
      _ = :sys.get_state(pid)
      assert reload(run).output_lines == ["a", "b"]

      {:ok, true} = Arbiter.Settings.set_output_offload_enabled(true)
      send(pid, :sweep)
      _ = :sys.get_state(pid)
      assert reload(run).output_lines == []

      other = run!(%{completed_at: ~U[2026-01-01 00:00:00.000000Z]})
      log!(other)
      {:ok, nil} = Arbiter.Settings.set_output_offload_enabled(nil)
      send(pid, :sweep)
      _ = :sys.get_state(pid)
      assert reload(other).output_lines == ["a", "b"]
    end
  end

  describe "Arbiter.Release.offload_report/1" do
    test "dry run reports per-table counts, bytes and kept-for-no-file, and writes nothing" do
      with_log = run!(%{completed_at: ~U[2026-01-01 00:00:00.000000Z]})
      no_log = run!(%{completed_at: ~U[2026-01-01 00:00:00.000000Z]})
      log!(with_log)
      step = step!(with_log, %{occurred_at: ~U[2026-01-01 00:00:00.000000Z]})
      archive!(with_log)

      report = Arbiter.Release.offload_report(start: false)

      assert report.apply? == false
      assert report.lines_offloaded == 1
      assert report.lines_bytes == byte_size(~s(["a","b"]))
      assert report.lines_no_file == 1
      assert report.steps_offloaded == 1
      assert report.steps_bytes == byte_size("1 test, 0 failures")
      assert reload(with_log).output_lines == ["a", "b"]
      assert reload(no_log).output_lines == ["a", "b"]
      assert reload(step).output_summary == "1 test, 0 failures"
    end

    test "apply: true clears them" do
      run = run!(%{completed_at: ~U[2026-01-01 00:00:00.000000Z]})
      log!(run)

      report = Arbiter.Release.offload_report(apply: true, start: false)

      assert report.apply? == true
      assert report.lines_offloaded == 1
      assert reload(run).output_lines == []
    end
  end
end
