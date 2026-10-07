defmodule ArbiterWeb.Api.WorkerResumeParityTest do
  @moduledoc """
  bd-a9hqfb AC4: MCP `worker_resume` and `arb worker resume` (which POSTs to
  `POST /api/workers/:task_id/resume`) are the same operation — they continue
  the prior session, so the agent is spawned with `--resume <session_id>`. The
  assertion is on the argv the stubbed agent CLI actually received.

  Before the fix the MCP tool ran `Dispatch.resume/2` (a fresh agent with a git
  briefing, no `--resume`).
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker

  setup %{conn: conn} do
    # One line per spawn: the whole argv, then stay alive like a working agent.
    sandbox =
      ResumeSlotFixture.setup_repo!(
        stub:
          ~s|printf '%s\\n' "$@" > "$(dirname "$0")/spawn.$(date +%s%N)"\nprintf '%s' "$ARB_TOKEN" > "$(dirname "$0")/token"\nexec sleep 30\n|
      )

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-parity-#{System.unique_integer([:positive])}",
        prefix: "rpt#{System.unique_integer([:positive])}"
      })

    {:ok, task} = Ash.create(Arbiter.Tasks.Issue, %{title: "resume parity", workspace_id: ws.id})
    first = ResumeSlotFixture.park!(task, nil)
    session_id = "sess-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: task.id,
        workspace_id: ws.id,
        repo: ResumeSlotFixture.repo(),
        step: :work,
        provider: "claude",
        session_id: session_id,
        occurred_at: DateTime.utc_now()
      })

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      task: task,
      first: first,
      session_id: session_id,
      bin: sandbox.bin,
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    }
  end

  # Every spawn the stub has seen, oldest first, each as its argv (one element
  # per line — the multi-line prompt splits, but flags and their values stay
  # whole). Waits until `count` spawns have landed.
  defp spawns(dir, count, attempts \\ 100) do
    found =
      dir
      |> Path.join("spawn.*")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&(&1 |> File.read!() |> String.split("\n", trim: true)))

    cond do
      length(found) >= count ->
        found

      attempts == 0 ->
        flunk("expected #{count} agent spawn(s), saw #{length(found)}")

      true ->
        Process.sleep(50)
        spawns(dir, count, attempts - 1)
    end
  end

  defp resume_pair(argv) do
    argv |> Enum.chunk_every(2, 1, :discard) |> Enum.find(&match?(["--resume", _], &1))
  end

  # The flags of a spawn, minus per-run identifiers: what makes it "the same command".
  defp flags(argv), do: Enum.filter(argv, &String.starts_with?(&1, "--"))

  test "REST and MCP resume spawn the agent with the same `--resume <session>`", ctx do
    conn = post(ctx.conn, ~p"/api/workers/#{ctx.task.id}/resume", %{})
    assert json_response(conn, 201)
    [rest] = spawns(ctx.bin, 1)

    :ok = Worker.fail(Worker.whereis(ctx.task.id), :token_exhausted)

    assert {:ok, %{worker: %{task_id: task_id}}} =
             Tools.worker_resume(ctx.coordinator, %{"task_id" => ctx.task.id})

    assert task_id == ctx.task.id
    [^rest, mcp] = spawns(ctx.bin, 2)

    assert resume_pair(rest) == ["--resume", ctx.session_id]
    assert resume_pair(mcp) == ["--resume", ctx.session_id]
    assert flags(mcp) == flags(rest)
  end

  test "`mode: briefing` is the explicit opt-in for the fresh-agent resume", ctx do
    assert {:ok, _} =
             Tools.worker_resume(ctx.coordinator, %{
               "task_id" => ctx.task.id,
               "mode" => "briefing"
             })

    [argv] = spawns(ctx.bin, 1)
    assert resume_pair(argv) == nil
  end

  # D-W-7: REST dispatch mints the child worker's scope at depth + 1 (the
  # worker's own `arb` token, handed to the spawned agent as ARB_TOKEN).
  test "a REST dispatch from a depth-1 token spawns a depth-2 worker", ctx do
    {:ok, other} =
      Ash.create(Arbiter.Tasks.Issue, %{title: "depth", workspace_id: ctx.task.workspace_id})

    token = Scope.mint_coordinator(nil, depth: 1)

    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/workers/dispatch", %{
        "task_id" => other.id,
        "force" => true,
        "repo" => ResumeSlotFixture.repo(),
        "provider" => "claude"
      })

    assert json_response(conn, 201)
    _ = spawns(ctx.bin, 1)
    child = File.read!(Path.join(ctx.bin, "token"))
    assert {:ok, %Scope{tier: :worker, depth: 2}} = Scope.from_token(child)
  end

  test "an argument resume does not take is refused, nothing is spawned", ctx do
    assert {:error, {:invalid, msg}} =
             Tools.worker_resume(ctx.coordinator, %{
               "task_id" => ctx.task.id,
               "provider" => "claude"
             })

    assert msg =~ "provider"
    assert Path.wildcard(Path.join(ctx.bin, "spawn.*")) == []
  end
end
