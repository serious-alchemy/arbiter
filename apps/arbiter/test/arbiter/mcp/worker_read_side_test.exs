defmodule Arbiter.MCP.WorkerReadSideTest do
  @moduledoc """
  Worker read-side parity (audit P-11): `worker_runs` takes `run_id` and the
  fleet-wide filters, `worker_log` takes `tail`, `worker_show` / `worker_list`
  take `fields`, every cap is the one in `Arbiter.Workers.Runs`, and the payload
  shapes come from the one `Arbiter.Workers.Serializer`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Workers.Run
  alias Arbiter.Workers.Runs
  alias Arbiter.Workers.Serializer

  setup do
    root = Path.join(System.tmp_dir!(), "p11-mcp-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arbiter, :output_log_root)
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    ws = workspace!("p11a")
    other = workspace!("p11b")
    %{ws: ws, other: other, coordinator: %Scope{tier: :coordinator, can_dispatch: true}}
  end

  defp workspace!(prefix) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "#{prefix}-#{n}", prefix: "#{prefix}#{n}"})
  end

  defp issue!(ws),
    do:
      Ash.create!(Issue, %{title: "t-#{System.unique_integer([:positive])}", workspace_id: ws.id}).id

  defp tid, do: "bd-p11m-#{System.unique_integer([:positive])}"

  defp run!(ws, task_id, attrs \\ %{}) do
    Ash.create!(
      Run,
      Map.merge(
        %{
          task_id: task_id,
          repo: "arbiter",
          workspace_id: ws.id,
          state: :finished,
          outcome: :succeeded,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  describe "worker_runs" do
    test "run_id reads one run, with its output lines; task_id is optional then",
         %{coordinator: c, ws: ws} do
      run = run!(ws, tid(), %{output_lines: ~w(a b)})

      assert {:ok, %{runs: [one]}} = Tools.worker_runs(c, %{"run_id" => run.id})
      assert one.id == run.id
      assert one.output_lines == ~w(a b)
    end

    test "run_id of another task is not found when task_id names a different task",
         %{coordinator: c, ws: ws} do
      run = run!(ws, tid())

      assert {:error, {:not_found, _}} =
               Tools.worker_runs(c, %{"run_id" => run.id, "task_id" => tid()})

      assert {:error, {:not_found, _}} = Tools.worker_runs(c, %{"run_id" => "no-such-run"})
    end

    test "with no task_id it is a fleet-wide query filtered by kind/state/outcome",
         %{coordinator: c, ws: ws} do
      failed = run!(ws, tid(), %{kind: :review, outcome: :failed})
      _ok = run!(ws, tid(), %{kind: :review, outcome: :succeeded})
      _impl = run!(ws, tid(), %{kind: :implement, outcome: :failed})

      assert {:ok, %{runs: runs}} =
               Tools.worker_runs(c, %{
                 "workspace" => ws.id,
                 "kind" => "review",
                 "state" => "finished",
                 "outcome" => "failed"
               })

      assert Enum.map(runs, & &1.id) == [failed.id]
    end

    test "before is an exclusive started_at cursor", %{coordinator: c, ws: ws} do
      old = run!(ws, tid(), %{started_at: ~U[2026-01-01 00:00:00Z]})
      _new = run!(ws, tid(), %{started_at: ~U[2026-03-01 00:00:00Z]})

      assert {:ok, %{runs: [only]}} =
               Tools.worker_runs(c, %{"workspace" => ws.id, "before" => "2026-02-01T00:00:00Z"})

      assert only.id == old.id

      assert {:error, {:invalid, _}} = Tools.worker_runs(c, %{"before" => "yesterday"})
    end

    test "the workspace filter confines a fleet-wide query", %{
      coordinator: c,
      ws: ws,
      other: other
    } do
      mine = run!(ws, tid())
      theirs = run!(other, tid())

      assert {:ok, %{runs: runs}} = Tools.worker_runs(c, %{"workspace" => ws.id})
      ids = Enum.map(runs, & &1.id)
      assert mine.id in ids
      refute theirs.id in ids
    end

    test "unknown enum values and junk limits are refused", %{coordinator: c} do
      assert {:error, {:invalid, _}} = Tools.worker_runs(c, %{"kind" => "nonsense"})
      assert {:error, {:invalid, _}} = Tools.worker_runs(c, %{"state" => "nonsense"})
      assert {:error, {:invalid, _}} = Tools.worker_runs(c, %{"limit" => 0})
    end

    test "limit is clamped to the shared history cap", %{coordinator: c, ws: ws} do
      for _ <- 1..3, do: run!(ws, tid())
      cap = Runs.history_cap()

      assert {:ok, %{runs: runs, count: n}} =
               Tools.worker_runs(c, %{"workspace" => ws.id, "limit" => cap + 100})

      assert n == length(runs)
      assert n <= cap
    end
  end

  describe "worker_log tail / run_id ownership" do
    test "tail returns the last N lines with truncated and the true total",
         %{coordinator: c, ws: ws} do
      task = issue!(ws)
      run = run!(ws, task)
      {:ok, h} = OutputLog.open(run.id)
      Enum.each(~w(one two three), &OutputLog.append(h, &1))
      OutputLog.close(h)

      assert {:ok, log} = Tools.worker_log(c, %{"task_id" => task, "tail" => 2})
      assert log.lines == ~w(two three)
      assert log.line_count == 3
      assert log.truncated == true

      assert {:ok, full} = Tools.worker_log(c, %{"task_id" => task})
      assert full.truncated == false
      assert {:error, {:invalid, _}} = Tools.worker_log(c, %{"task_id" => task, "tail" => 0})
    end

    test "a run_id that belongs to another task is not found when task_id is also given",
         %{coordinator: c, ws: ws} do
      run = run!(ws, tid())

      assert {:error, {:not_found, _}} =
               Tools.worker_log(c, %{"task_id" => tid(), "run_id" => run.id})

      assert {:error, {:not_found, _}} =
               Tools.worker_prompt(c, %{"task_id" => tid(), "run_id" => run.id})

      assert {:ok, %{run_id: id}} =
               Tools.worker_log(c, %{"task_id" => run.task_id, "run_id" => run.id})

      assert id == run.id
    end
  end

  describe "fields" do
    test "worker_show projects to the requested fields", %{coordinator: c, ws: ws} do
      task = issue!(ws)
      run!(ws, task, %{output_lines: ~w(a b c)})

      assert {:ok, full} = Tools.worker_show(c, %{"task_id" => task})
      assert Map.has_key?(full, :output_lines)

      assert {:ok, slim} =
               Tools.worker_show(c, %{"task_id" => task, "fields" => ["task_id", "state", "runs"]})

      assert Enum.sort(Map.keys(slim)) == [:runs, :state, :task_id]
      assert slim.task_id == task

      assert {:error, {:invalid, msg}} =
               Tools.worker_show(c, %{"task_id" => task, "fields" => ["nope"]})

      assert msg =~ "nope"
    end
  end

  describe "list envelope" do
    test "workers + count + workspace_id", %{coordinator: c, ws: ws} do
      assert {:ok, %{workers: workers, count: n, workspace_id: id}} =
               Tools.worker_list(c, %{"workspace" => ws.id})

      assert n == length(workers)
      assert id == ws.id
    end
  end

  describe "one serializer, one cap (grep guards)" do
    @root Path.expand("../../../../..", __DIR__)

    defp source(rel), do: File.read!(Path.join(@root, rel))

    test "REST and MCP both render workers through Arbiter.Workers.Serializer" do
      for rel <- [
            "apps/arbiter/lib/arbiter/mcp/tools/worker.ex",
            "apps/arbiter_web/lib/arbiter_web/controllers/api/worker_json.ex",
            "apps/arbiter_web/lib/arbiter_web/controllers/api/run_json.ex",
            "apps/arbiter_web/lib/arbiter_web/controllers/api/worker_controller.ex"
          ] do
        assert source(rel) =~ "Arbiter.Workers.Serializer", "#{rel} must call the serializer"
      end

      # …and neither surface keeps a private copy of a payload builder.
      refute source("apps/arbiter/lib/arbiter/mcp/tools/worker.ex") =~
               ~r/defp (serialize_worker_snapshot|serialize_worker_summary|serialize_recent_run|serialize_worker_log|serialize_worker_prompt|serialize_run_log_entry|serialize_worker_run_summary)/

      refute source("apps/arbiter_web/lib/arbiter_web/controllers/api/worker_controller.ex") =~
               ~r/defp (render_log|render_prompt|render_run_log_entry)/

      refute source("apps/arbiter_web/lib/arbiter_web/controllers/api/worker_json.ex") =~
               ~r/defp (run|recent_run)\(/

      refute source("apps/arbiter_web/lib/arbiter_web/controllers/api/run_json.ex") =~
               ~r/defp (summary|detail)\(/

      assert function_exported?(Serializer, :show, 3)
    end

    test "no surface carries its own copy of a run-list cap" do
      for rel <- [
            "apps/arbiter/lib/arbiter/mcp/tools/worker.ex",
            "apps/arbiter_web/lib/arbiter_web/controllers/api/worker_controller.ex",
            "apps/arbiter_web/lib/arbiter_web/controllers/api/run_controller.ex"
          ] do
        refute source(rel) =~ ~r/(parse_bounded_limit|Params\.limit)\([^)]*\b\d+, \d+\)/,
               "#{rel} hardcodes a limit; use Arbiter.Workers.Runs"

        refute source(rel) =~ "@max_limit", "#{rel} defines its own cap"
      end
    end

    test "the caps are the same numbers on every entry point" do
      assert Runs.history_limit(nil) == {:ok, 20}
      assert Runs.history_limit("5000") == {:ok, Runs.history_cap()}
      assert Runs.history_cap() == 200
      assert Runs.corpus_limit(nil) == {:ok, 200}
      assert Runs.corpus_limit(10_000) == {:ok, Runs.corpus_cap()}
      assert Runs.corpus_cap() == 1000
    end

    test "catalog descriptions quote the shared caps" do
      tools = Map.new(Arbiter.MCP.Catalog.all(), &{&1.name, &1})

      assert tools["worker_runs"].description =~ "default 20, max #{Runs.history_cap()}"
      assert tools["run_log_list"].description =~ "default 200, max #{Runs.corpus_cap()}"
    end
  end
end
