defmodule Arbiter.Workers.RunTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Workers.Run

  @ws "ws-run-test"

  describe "create/validation" do
    test "creates a running run with the required fields" do
      now = DateTime.utc_now()

      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-aaa",
          task_title: "do a thing",
          repo: "arbiter",
          workspace_id: @ws,
          status: :running,
          started_at: now
        })

      assert run.task_id == "bd-aaa"
      assert run.status == :running
      assert run.output_lines == []
      # worker_type defaults to :main when not supplied.
      assert run.worker_type == :main
      assert %DateTime{} = run.inserted_at
    end

    test "accepts a worker_type and model, rejects an unknown worker_type" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-typed",
          repo: "arbiter",
          worker_type: :review,
          model: "claude-opus-4-8",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert run.worker_type == :review
      assert run.model == "claude-opus-4-8"

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 task_id: "bd-badtype",
                 repo: "arbiter",
                 worker_type: :bogus,
                 status: :running,
                 started_at: DateTime.utc_now()
               })
    end

    test "persists session_id and config_dir at create (bd-au3xrq)" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-sess",
          repo: "arbiter",
          status: :running,
          started_at: DateTime.utc_now(),
          session_id: "11111111-2222-3333-4444-555555555555",
          config_dir: "/home/ryan/.cache/arbiter/worker-claude"
        })

      assert run.session_id == "11111111-2222-3333-4444-555555555555"
      assert run.config_dir == "/home/ryan/.cache/arbiter/worker-claude"
    end

    test "rejects an unknown status" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 task_id: "bd-x",
                 repo: "arbiter",
                 status: :bogus,
                 started_at: DateTime.utc_now()
               })
    end

    test "rejects a missing task_id" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 repo: "arbiter",
                 status: :running,
                 started_at: DateTime.utc_now()
               })
    end
  end

  describe "update" do
    test "stamps completed_at, exit_code, output_lines, failure_reason" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-bbb",
          repo: "arbiter",
          workspace_id: @ws,
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, updated} =
        Ash.update(run, %{
          status: :completed,
          completed_at: DateTime.utc_now(),
          exit_code: 0,
          output_lines: ["hello", "world"]
        })

      assert updated.status == :completed
      assert updated.exit_code == 0
      assert updated.output_lines == ["hello", "world"]
    end

    test "backfills session_id and config_dir on update (bd-au3xrq)" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-sess-upd",
          repo: "arbiter",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert run.session_id == nil
      assert run.config_dir == nil

      {:ok, updated} =
        Ash.update(run, %{
          session_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          config_dir: "/tmp/cfg"
        })

      assert updated.session_id == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      assert updated.config_dir == "/tmp/cfg"
    end
  end

  describe "statuses/0" do
    test "exposes the canonical status list" do
      assert :running in Run.statuses()
      assert :completed in Run.statuses()
      assert :failed in Run.statuses()
    end
  end

  describe "worker_types/0" do
    test "exposes the canonical worker_type list" do
      # bd-8lq2g7 added the two merge-queue subordinate passes, which run under
      # the task's own id alongside its parked primary worker.
      assert Run.worker_types() == [:main, :review, :impl, :fix_pass, :conflict]
    end
  end

  # bd-2l0hzm: the Watchdog's per-episode auto-resolve counter resets on every
  # new head and dies with the Watchdog, so PR #2003 got four fix passes that
  # all logged "attempt 1". The per-task cap reads this durable count instead.
  describe "fix_pass_count/2" do
    defp run!(attrs) do
      {:ok, run} =
        Ash.create(
          Run,
          Map.merge(%{repo: "arbiter", status: :completed, workspace_id: @ws}, attrs)
        )

      run
    end

    defp at(minutes), do: DateTime.add(~U[2026-09-23 16:00:00.000000Z], minutes * 60)

    test "counts the task's fix passes since its PR's first run, across heads and primaries" do
      run!(%{task_id: "bd-fpc", worker_type: :main, mr_ref: "#1", started_at: at(0)})
      run!(%{task_id: "bd-fpc", worker_type: :fix_pass, started_at: at(10)})
      # A second primary (a new Watchdog) on the same PR, then two more passes.
      run!(%{task_id: "bd-fpc", worker_type: :main, mr_ref: "#1", started_at: at(20)})
      run!(%{task_id: "bd-fpc", worker_type: :fix_pass, started_at: at(30)})
      run!(%{task_id: "bd-fpc", worker_type: :fix_pass, started_at: at(40)})

      # Noise: other worker types, and another task's fix pass.
      run!(%{
        task_id: "bd-fpc#review",
        base_task_id: "bd-fpc",
        worker_type: :review,
        started_at: at(15)
      })

      run!(%{task_id: "bd-other", worker_type: :fix_pass, started_at: at(35)})

      assert Run.fix_pass_count("bd-fpc", "#1") == 3
    end

    test "does not count fix passes from before the PR existed" do
      run!(%{task_id: "bd-fpc2", worker_type: :main, mr_ref: "#1", started_at: at(0)})
      run!(%{task_id: "bd-fpc2", worker_type: :fix_pass, started_at: at(5)})
      run!(%{task_id: "bd-fpc2", worker_type: :main, mr_ref: "#2", started_at: at(20)})
      run!(%{task_id: "bd-fpc2", worker_type: :fix_pass, started_at: at(30)})

      assert Run.fix_pass_count("bd-fpc2", "#2") == 1
    end

    test "counts every fix pass on the task when no run carries the PR ref" do
      run!(%{task_id: "bd-fpc3", worker_type: :fix_pass, started_at: at(5)})
      run!(%{task_id: "bd-fpc3", worker_type: :fix_pass, started_at: at(6)})

      assert Run.fix_pass_count("bd-fpc3", "#9") == 2
      assert Run.fix_pass_count("bd-fpc3", nil) == 2
      assert Run.fix_pass_count("bd-none", "#9") == 0
    end
  end
end
