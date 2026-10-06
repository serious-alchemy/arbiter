defmodule Arbiter.Worker.PrivateCloneCompletionTest do
  @moduledoc """
  bd-6t7u81 (#390): `arb done` from a worker that renamed its private clone's
  `.git` and put its own (with a `core.fsmonitor`) in its place must not reach
  any host-side git: not the commit gate, and not the ReviewGate's
  `git status` / `git diff` that the gate's pass-through used to lead to. The
  run fails `:tampered_clone`, the original `.git` is back, and nothing the
  worker planted ran.
  """
  # async: false — GitFixture points the worktree root (Application env) at a
  # private directory.
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.PrivateClone

  @branch "feature/bd-6t7u81-completion"

  setup do
    fixture = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, path} = PrivateClone.create(fixture.checkout, @branch, "main")

    marker_dir = Path.join(System.tmp_dir!(), "arb-done-#{System.unique_integer([:positive])}")
    File.mkdir_p!(marker_dir)
    on_exit(fn -> File.rm_rf!(marker_dir) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "tampered-clone-ws-#{System.unique_integer([:positive])}",
        prefix: "tc",
        config: %{}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "code directive", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    Map.merge(fixture, %{path: path, marker_dir: marker_dir, ws: ws, task: task})
  end

  defp fired(ctx), do: ctx.marker_dir |> File.ls!() |> Enum.sort()

  # What the worker does: rename `.git`, recreate one with the same HEAD,
  # refs, objects, `commondir` and a config that still carries every marker
  # plus a fsmonitor that touches a file when any git command reads it.
  defp swap_git!(ctx) do
    dot_git = Path.join(ctx.path, ".git")
    File.rename!(dot_git, dot_git <> "2")
    File.mkdir_p!(Path.join(dot_git, "objects/info"))
    File.mkdir_p!(Path.join(dot_git, "hooks"))

    for file <- ~w(HEAD index commondir objects/info/alternates) do
      File.cp!(Path.join(dot_git <> "2", file), Path.join(dot_git, file))
    end

    File.cp_r!(Path.join(dot_git <> "2", "refs"), Path.join(dot_git, "refs"))

    File.write!(
      Path.join(dot_git, "config"),
      File.read!(Path.join(dot_git <> "2", "config")) <>
        "[core]\n\tfsmonitor = touch #{Path.join(ctx.marker_dir, "fsmonitor")}; echo\n"
    )
  end

  defp start_worker!(ctx) do
    {:ok, pid} =
      Worker.start(
        task_id: ctx.task.id,
        repo: "arbiter",
        workspace_id: ctx.ws.id,
        meta: %{
          issue_type: :feature,
          branch: @branch,
          target_branch: "main",
          worktree_path: ctx.path,
          commit_nudge_cap: 0
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp wait_finished(pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(pid, deadline)
  end

  defp do_wait(pid, deadline) do
    snap = Worker.state(pid)

    cond do
      match?(%{state: :finished}, snap) ->
        snap

      System.monotonic_time(:millisecond) > deadline ->
        flunk("worker did not finish: #{inspect(snap && snap.state)}")

      true ->
        # Poll the worker's own state; there is no event to subscribe to here.
        _ = :sys.get_state(pid)
        Process.sleep(15)
        do_wait(pid, deadline)
    end
  end

  test "arb done from a swapped .git fails :tampered_clone before any git runs", ctx do
    original = File.lstat!(Path.join(ctx.path, ".git")).inode
    swap_git!(ctx)
    pid = start_worker!(ctx)

    ExUnit.CaptureLog.capture_log(fn ->
      send(pid, {:__claude_session_done__, "arb done"})
      send(self(), {:snap, wait_finished(pid)})
    end)

    assert_received {:snap, snap}
    assert snap.outcome == :failed
    refute snap.waiting_on == :review_gate
    assert snap.mr_ref == nil
    assert snap.meta.stop_reason.category == :tampered_clone

    assert fired(ctx) == []
    assert File.lstat!(Path.join(ctx.path, ".git")).inode == original

    assert Message.coordinator_ref()
           |> Message.inbox(workspace_id: ctx.ws.id)
           |> Enum.any?(&(&1.kind == :escalation and &1.directive_ref == ctx.task.id))
  end

  test "arb done from an untouched clone is not refused as tampered", ctx do
    pid = start_worker!(ctx)

    send(pid, {:__claude_session_done__, "arb done"})
    snap = wait_finished(pid)

    refute match?(%{stop_reason: %{category: :tampered_clone}}, snap.meta)
    assert fired(ctx) == []
  end
end
