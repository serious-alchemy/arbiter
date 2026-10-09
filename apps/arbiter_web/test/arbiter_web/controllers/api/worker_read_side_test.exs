defmodule ArbiterWeb.Api.WorkerReadSideTest do
  @moduledoc """
  Worker read-side parity (audit P-11): `log` / `prompt` only serve a run that
  belongs to the path task, `log` takes `tail`, `show` takes `lines`, and every
  read is confined to a workspace-bound token's workspace.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Worker.PromptLog
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "p11-read-#{System.unique_integer([:positive])}")
    prev_log = Application.get_env(:arbiter, :output_log_root)
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev_log,
        do: Application.put_env(:arbiter, :output_log_root, prev_log),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "p11-ws-#{System.unique_integer([:positive])}", prefix: "pe"})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

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

  defp transcript!(run, lines) do
    {:ok, handle} = OutputLog.open(run.id)
    Enum.each(lines, &OutputLog.append(handle, &1))
    OutputLog.close(handle)
  end

  defp tid, do: "bd-p11-#{System.unique_integer([:positive])}"

  describe "log / prompt: run_id must belong to the path task (D-W-12)" do
    test "a run of another task is a 404 on both routes", %{conn: conn, ws: ws} do
      mine = tid()
      other_run = run!(ws, tid())
      transcript!(other_run, ["secret"])
      :ok = PromptLog.write(other_run.id, "other prompt")

      assert conn
             |> get(~p"/api/workers/#{mine}/log?run_id=#{other_run.id}")
             |> json_response(404)

      assert conn
             |> get(~p"/api/workers/#{mine}/prompt?run_id=#{other_run.id}")
             |> json_response(404)
    end

    test "the task's own run, and its ReviewGate synthetic child's run, are served",
         %{conn: conn, ws: ws} do
      base = tid()
      own = run!(ws, base)
      review = run!(ws, base <> "#review", %{kind: :review})
      transcript!(review, ["verdict"])
      :ok = PromptLog.write(review.id, "review prompt")

      assert get(conn, ~p"/api/workers/#{base}/log?run_id=#{own.id}") |> json_response(200)

      data = conn |> get(~p"/api/workers/#{base}/log?run_id=#{review.id}") |> json_response(200)
      assert data["data"]["lines"] == ["verdict"]

      data =
        conn |> get(~p"/api/workers/#{base}/prompt?run_id=#{review.id}") |> json_response(200)

      assert data["data"]["prompt"] == "review prompt"
    end

    test "a synthetic path id selects exactly that child's runs", %{conn: conn, ws: ws} do
      base = tid()
      review = run!(ws, base <> "#review", %{kind: :review})

      assert get(conn, ~p"/api/workers/#{base <> "#r1"}/log?run_id=#{review.id}")
             |> json_response(404)
    end
  end

  describe "log tail (D-W-16)" do
    test "tail returns the last N lines, the true total and truncated: true",
         %{conn: conn, ws: ws} do
      task = tid()
      run = run!(ws, task)
      transcript!(run, ~w(one two three four))

      data =
        conn
        |> get(~p"/api/workers/#{task}/log?tail=2")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["lines"] == ~w(three four)
      assert data["line_count"] == 4
      assert data["truncated"] == true
    end

    test "a tail larger than the transcript is not truncated; no tail = whole log",
         %{conn: conn, ws: ws} do
      task = tid()
      run = run!(ws, task)
      transcript!(run, ~w(one two))

      data =
        conn
        |> get(~p"/api/workers/#{task}/log?tail=50")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["lines"] == ~w(one two)
      assert data["truncated"] == false

      data = conn |> get(~p"/api/workers/#{task}/log") |> json_response(200) |> Map.fetch!("data")
      assert data["lines"] == ~w(one two)
      assert data["truncated"] == false
    end

    test "a junk tail is a 400", %{conn: conn, ws: ws} do
      task = tid()
      run!(ws, task)
      assert conn |> get(~p"/api/workers/#{task}/log?tail=abc") |> json_response(400)
      assert conn |> get(~p"/api/workers/#{task}/log?tail=0") |> json_response(400)
    end
  end

  describe "show lines (D-W-13)" do
    test "lines bounds the output tail; the payload carries the MCP-side fields too",
         %{conn: conn, ws: ws} do
      task = tid()
      run!(ws, task, %{output_lines: ~w(a b c d)})

      body = conn |> get(~p"/api/workers/#{task}?lines=2") |> json_response(200)
      assert body["output_lines"] == ~w(c d)

      for key <- ~w(resumable blocked_reason provider provider_fallback provider_account_id
                    model_family routing_decision) do
        assert Map.has_key?(body, key), "show is missing #{key}"
      end

      assert [%{"model" => _, "failure_summary" => _}] = body["runs"]
    end

    test "a junk lines is a 400", %{conn: conn, ws: ws} do
      task = tid()
      run!(ws, task)
      assert conn |> get(~p"/api/workers/#{task}?lines=0") |> json_response(400)
    end
  end

  describe "list envelope (D-W-14)" do
    test "carries count and workspace_id next to data", %{conn: conn, ws: ws} do
      body = conn |> get(~p"/api/workers?workspace=#{ws.id}") |> json_response(200)
      assert body["count"] == length(body["data"])
      assert body["workspace_id"] == ws.id
    end
  end

  describe "caps (D-W-15)" do
    test "history and run_log_list clamp to the one shared cap", %{conn: conn, ws: ws} do
      task = tid()
      run!(ws, task)

      assert conn
             |> get(~p"/api/workers/history?limit=#{Arbiter.Workers.Runs.history_cap() + 1}")
             |> json_response(200)

      assert conn |> get(~p"/api/workers/#{task}/run_log_list?limit=0") |> json_response(400)
    end
  end

  describe "workspace isolation (D-W-25)" do
    setup %{ws: ws} do
      {:ok, other} =
        Ash.create(Workspace, %{
          name: "p11-other-#{System.unique_integer([:positive])}",
          prefix: "po"
        })

      task = tid()
      run = run!(other, task)
      transcript!(run, ["theirs"])

      bound =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer " <> Scope.mint_coordinator(ws.id))

      {:ok, bound: bound, task: task, run: run, other: other}
    end

    test "a workspace-bound coordinator cannot read another workspace's worker",
         %{bound: bound, task: task, run: run} do
      assert bound |> get(~p"/api/workers/#{task}") |> json_response(404)
      assert bound |> get(~p"/api/workers/#{task}/log") |> json_response(404)
      assert bound |> get(~p"/api/workers/#{task}/log?run_id=#{run.id}") |> json_response(404)
      assert bound |> get(~p"/api/workers/#{task}/prompt") |> json_response(404)
      assert bound |> get(~p"/api/workers/#{task}/run_log_list") |> json_response(404)
      assert bound |> get(~p"/api/workers/history/#{run.id}") |> json_response(404)
      assert bound |> post(~p"/api/workers/#{task}/stop") |> json_response(404)
    end

    test "the unbound coordinator still reads it", %{conn: conn, task: task, run: run} do
      assert conn |> get(~p"/api/workers/#{task}") |> json_response(200)
      assert conn |> get(~p"/api/workers/#{task}/log") |> json_response(200)
      assert conn |> get(~p"/api/workers/history/#{run.id}") |> json_response(200)
    end
  end
end
