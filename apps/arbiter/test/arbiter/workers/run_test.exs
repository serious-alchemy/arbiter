defmodule Arbiter.Workers.RunTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Workers.Run

  @ws "ws-run-test"

  describe "create/validation" do
    test "creates a working run with the required fields" do
      now = DateTime.utc_now()

      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-aaa",
          task_title: "do a thing",
          repo: "arbiter",
          workspace_id: @ws,
          state: :working,
          started_at: now
        })

      assert run.task_id == "bd-aaa"
      assert run.state == :working
      assert run.output_lines == []
      # kind defaults to :implement when not supplied, and an unfinished run
      # has no outcome.
      assert run.kind == :implement
      assert run.outcome == nil
      assert %DateTime{} = run.inserted_at
    end

    test "a new run defaults to :starting" do
      {:ok, run} =
        Ash.create(Run, %{task_id: "bd-start", repo: "arbiter", started_at: DateTime.utc_now()})

      assert run.state == :starting
      assert run.outcome == nil
    end

    test "accepts a kind and model, rejects an unknown kind" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-typed",
          repo: "arbiter",
          kind: :review,
          model: "claude-opus-4-8",
          state: :working,
          started_at: DateTime.utc_now()
        })

      assert run.kind == :review
      assert run.model == "claude-opus-4-8"

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 task_id: "bd-badtype",
                 repo: "arbiter",
                 kind: :bogus,
                 state: :working,
                 started_at: DateTime.utc_now()
               })
    end

    test "persists session_id and config_dir at create (bd-au3xrq)" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-sess",
          repo: "arbiter",
          state: :working,
          started_at: DateTime.utc_now(),
          session_id: "11111111-2222-3333-4444-555555555555",
          config_dir: "/home/ryan/.cache/arbiter/worker-claude"
        })

      assert run.session_id == "11111111-2222-3333-4444-555555555555"
      assert run.config_dir == "/home/ryan/.cache/arbiter/worker-claude"
    end

    test "rejects an unknown state or outcome" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 task_id: "bd-x",
                 repo: "arbiter",
                 state: :bogus,
                 started_at: DateTime.utc_now()
               })

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 task_id: "bd-x",
                 repo: "arbiter",
                 state: :finished,
                 outcome: :bogus,
                 started_at: DateTime.utc_now()
               })
    end

    test "rejects a missing task_id" do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Run, %{
                 repo: "arbiter",
                 state: :working,
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
          state: :working,
          started_at: DateTime.utc_now()
        })

      {:ok, updated} =
        Ash.update(run, %{
          state: :finished,
          outcome: :succeeded,
          completed_at: DateTime.utc_now(),
          exit_code: 0,
          output_lines: ["hello", "world"]
        })

      assert updated.outcome == :succeeded
      assert updated.exit_code == 0
      assert updated.output_lines == ["hello", "world"]
    end

    test "backfills session_id and config_dir on update (bd-au3xrq)" do
      {:ok, run} =
        Ash.create(Run, %{
          task_id: "bd-sess-upd",
          repo: "arbiter",
          state: :working,
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

  describe "kinds/0" do
    test "exposes the canonical run kind list" do
      # bd-1uu19b: the review-gate implementer round is an :implement run (told
      # apart by its role), and the two merge-queue passes (bd-8lq2g7) are
      # their own kinds.
      assert Run.kinds() == [:implement, :review, :fix_pass, :conflict]
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
          Map.merge(
            %{repo: "arbiter", state: :finished, outcome: :succeeded, workspace_id: @ws},
            attrs
          )
        )

      run
    end

    defp at(minutes), do: DateTime.add(~U[2026-09-23 16:00:00.000000Z], minutes * 60)

    test "counts the task's fix passes since its PR's first run, across heads and primaries" do
      run!(%{task_id: "bd-fpc", kind: :implement, mr_ref: "#1", started_at: at(0)})
      run!(%{task_id: "bd-fpc", kind: :fix_pass, started_at: at(10)})
      # A second primary (a new Watchdog) on the same PR, then two more passes.
      run!(%{task_id: "bd-fpc", kind: :implement, mr_ref: "#1", started_at: at(20)})
      run!(%{task_id: "bd-fpc", kind: :fix_pass, started_at: at(30)})
      run!(%{task_id: "bd-fpc", kind: :fix_pass, started_at: at(40)})

      # Noise: other run kinds, and another task's fix pass.
      run!(%{
        task_id: "bd-fpc#review",
        base_task_id: "bd-fpc",
        kind: :review,
        started_at: at(15)
      })

      run!(%{task_id: "bd-other", kind: :fix_pass, started_at: at(35)})

      assert Run.fix_pass_count("bd-fpc", "#1") == 3
    end

    test "does not count fix passes from before the PR existed" do
      run!(%{task_id: "bd-fpc2", kind: :implement, mr_ref: "#1", started_at: at(0)})
      run!(%{task_id: "bd-fpc2", kind: :fix_pass, started_at: at(5)})
      run!(%{task_id: "bd-fpc2", kind: :implement, mr_ref: "#2", started_at: at(20)})
      run!(%{task_id: "bd-fpc2", kind: :fix_pass, started_at: at(30)})

      assert Run.fix_pass_count("bd-fpc2", "#2") == 1
    end

    test "counts every fix pass on the task when no run carries the PR ref" do
      run!(%{task_id: "bd-fpc3", kind: :fix_pass, started_at: at(5)})
      run!(%{task_id: "bd-fpc3", kind: :fix_pass, started_at: at(6)})

      assert Run.fix_pass_count("bd-fpc3", "#9") == 2
      assert Run.fix_pass_count("bd-fpc3", nil) == 2
      assert Run.fix_pass_count("bd-none", "#9") == 0
    end
  end
end
