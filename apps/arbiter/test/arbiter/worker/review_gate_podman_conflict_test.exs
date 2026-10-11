defmodule Arbiter.Worker.ReviewGatePodmanConflictTest do
  @moduledoc """
  bd-6sosvl / #772 — a PR that conflicts with its target while in ReviewGate,
  under the podman backend (a private clone, git layout B), is resolved by a
  round that HAS the target ref, and then reviewed.

  On v0.2.49 the conflict round ran in a container whose clone had no usable
  `origin/main` (it cannot fetch), so the author could not merge, finished
  without a commit, and the gate rejected the same head four times.

  Driven against real git: a bare forge, a podman-style private clone with the
  feature branch's approved commit, a `main` that moves into the same file, a
  real ReviewGate over the clone, and the author's side of the conflict round
  played by hand (the container's `git merge origin/main`, resolve, commit).
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.ReviewGate.Round
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.GitFixture
  alias Arbiter.Test.StubFixRoundDispatcher
  alias Arbiter.Worker
  alias Arbiter.Worker.ConflictAbortFindings
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.ReviewGate

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)
  @shared Enum.map_join(1..12, "", &"shared line #{&1}\n")
  @mr "owner/repo#772"
  @branch "feature/podman-conflict"

  setup do
    StubFixRoundDispatcher.reset()
    fixture = GitFixture.forge_and_checkout(%{"shared.ex" => @shared})
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => fixture.checkout})

    {:ok, clone} = PrivateClone.create(fixture.checkout, @branch, "main")

    feature = String.replace(@shared, "shared line 4", "shared line 4 (feature)")
    approved = GitFixture.commit!(clone, %{"shared.ex" => feature}, "feature work")

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-podman-#{System.unique_integer([:positive])}",
        prefix: "pm",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "podman conflict", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    {:ok, _} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: @mr,
        head_sha: approved,
        base_ref: "main",
        net_diff_id: "fp-#{approved}",
        kind: :reviewed,
        source: :review_gate,
        round: 1
      })

    # The target moves into the same lines, on the forge, behind the clone's back.
    GitFixture.git!(fixture.seed, ["pull", "-q", "origin", "main"])

    forge_tip =
      GitFixture.commit!(
        fixture.seed,
        %{"shared.ex" => String.replace(@shared, "shared line 4", "shared line 4 (main)")},
        "main moves"
      )

    GitFixture.git!(fixture.seed, ["push", "-q", "origin", "main"])

    Map.merge(fixture, %{
      clone: clone,
      ws: ws,
      task: task,
      approved: approved,
      forge_tip: forge_tip
    })
  end

  test "the conflict round gets origin/<target>, merges it, and the resolved head is reviewed",
       ctx do
    # 1. The gate finds the conflict before any reviewer runs and rejects.
    author = start_author(ctx)
    gate = start_gate(ctx, author, command: [@reviewer, "REQUEST_CHANGES"])
    assert_stops(gate)

    assert [%Round{verdict: :request_changes, findings: findings}] = rounds(ctx.task.id)
    assert ConflictAbortFindings.escalation?(findings)

    assert ConflictAbortFindings.head_of(findings) ==
             GitFixture.git!(ctx.clone, ["rev-parse", "HEAD"])

    # 2. The author's fix round is dispatched, with the target ref already in
    #    its clone: the host fetched it (the container could not).
    wait_until(fn -> StubFixRoundDispatcher.dispatch_count() == 1 end)
    assert [%{conflict: true, target_branch: "main"}] = StubFixRoundDispatcher.dispatches()
    assert StubFixRoundDispatcher.escalations() == []
    assert GitFixture.git!(ctx.clone, ["rev-parse", "origin/main"]) == ctx.forge_tip

    # 3. What the container then does, offline: merge it, resolve, commit.
    assert {_, 1} =
             System.cmd("git", ["-C", ctx.clone, "merge", "--no-edit", "origin/main"],
               stderr_to_stdout: true
             )

    File.write!(
      Path.join(ctx.clone, "shared.ex"),
      String.replace(@shared, "shared line 4", "shared line 4 (main + feature)")
    )

    GitFixture.git!(ctx.clone, ["add", "shared.ex"])
    GitFixture.git!(ctx.clone, ["commit", "-q", "--no-edit"])
    resolved = GitFixture.git!(ctx.clone, ["rev-parse", "HEAD"])

    # 4. The re-run gate reaches a verdict on the resolved head: a scoped
    #    conflict review, and its APPROVE.
    stop_author(author)
    author2 = start_author(ctx)
    gate2 = start_gate(ctx, author2, command: [@reviewer, "APPROVE"])

    wait_until(fn -> Enum.any?(rounds(ctx.task.id), &(&1.role == :conflict_review)) end)

    assert %Round{verdict: :approve} =
             Enum.find(rounds(ctx.task.id), &(&1.role == :conflict_review))

    wait_until(fn -> Enum.any?(Coverage.for_mr(@mr), &(&1.head_sha == resolved)) end)
    assert_stops(gate2)

    # No second conflict rejection, no escalation: one round, resolved.
    assert StubFixRoundDispatcher.dispatch_count() == 1
    assert StubFixRoundDispatcher.escalations() == []
  end

  defp start_author(ctx) do
    {:ok, author} =
      Worker.start(
        task_id: ctx.task.id,
        repo: "trib/repo",
        workspace_id: ctx.ws.id,
        meta: %{
          branch: @branch,
          repo_path: ctx.checkout,
          worktree_path: ctx.clone,
          target_branch: "main",
          merge_title: "Merge #{ctx.task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    author
  end

  defp stop_author(author), do: if(Process.alive?(author), do: GenServer.stop(author, :normal))

  defp start_gate(ctx, author, opts) do
    {:ok, gate} =
      ReviewGate.start(
        [
          author: author,
          task_id: ctx.task.id,
          workspace_id: ctx.ws.id,
          repo: "trib/repo",
          worktree_path: ctx.clone,
          branch: @branch,
          target_branch: "main",
          pr_ref: @mr
        ] ++ opts
      )

    gate
  end

  defp assert_stops(gate) do
    ref = Process.monitor(gate)
    assert_receive {:DOWN, ^ref, :process, ^gate, _}, 20_000
  end

  defp rounds(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  defp wait_until(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end
end
