defmodule Arbiter.Worker.ReviewGateRemoteFixRoundTest do
  @moduledoc """
  bd-bg87oz — a ReviewGate fix round (the implementer pass that answers a
  REQUEST_CHANGES) is placed like any other podman Claude run that writes commits:
  on a node with headroom under `prefer_remote`, held under `remote_only` while none
  has room, seeded from the forge's current head of the branch and target tip, pushed
  back by the gate with a lease pinned to the head it was seeded from, and
  re-dispatched when its node is lost.

  Real git with a real bare origin, a real author `Worker`, the real gate and shell
  fixtures for the reviewer and the implementer. This host has no node, so the node is
  the `:nodes` row the gate's `placement_opts` hands `Placement.place/2`, and the
  fixture implementer runs in the author's private clone, which is exactly where a
  collected checkout leaves a remote pass's commits. The node half (the seed bundle
  over HTTP, the quarantine) is `ArbiterWeb.RemotePassTest`.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.CircuitBreaker
  alias Arbiter.Tasks.{Issue, ReviewPark, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{PrivateClone, ReviewGate}

  @two_rounds Path.expand("../../fixtures/review_two_rounds.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)
  @revise_rewrite Path.expand("../../fixtures/revise_rewrite.sh", __DIR__)
  @revise_hang Path.expand("../../fixtures/revise_hang.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-rfr-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> rm_rf_settled!(tmp) end)

    %{repo: repo, tmp: tmp, ws: workspace!("prefer_remote")}
  end

  # A fix-round child (git, a fixture script) can still be flushing into the tree
  # when teardown runs, so `File.rm_rf!/1` races it and raises `:eexist` /
  # `:enotempty` (bd-axlnpu). Retry until the writers have gone.
  defp rm_rf_settled!(dir, attempts \\ 50) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, _file} when attempts > 1 and reason in [:eexist, :enotempty] ->
        receive do
        after
          100 -> rm_rf_settled!(dir, attempts - 1)
        end

      {:error, reason, file} ->
        raise File.Error,
          reason: reason,
          action: "remove files and directories recursively from",
          path: file
    end
  end

  defp workspace!(mode) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-rfr-#{System.unique_integer([:positive])}",
        prefix: "rf",
        config: %{
          "review" => %{"required" => true, "require_ci_green" => false},
          "worker" => %{"placement" => mode},
          "agent" => %{
            "security" => %{
              "repos" => %{"trib/repo" => %{"sandbox" => %{"backend" => "podman"}}}
            }
          }
        }
      })

    ws
  end

  defp node_row(name, attrs \\ []) do
    Map.merge(
      %{
        id: "node-" <> name,
        name: name,
        state: :online,
        health: :ready,
        labels: [],
        workspace_ids: [],
        live: 0,
        max: 2
      },
      Map.new(attrs)
    )
  end

  defp placement(rows), do: [nodes: rows, remote_available?: true]

  describe "placement" do
    test "the fix round is placed on a node, seeded at the forge's head and target tip", ctx do
      rig = rig(ctx, "feature/rf-1")
      main_tip = third_party_main!(ctx)

      stale_main = sha(rig.wt, "refs/remotes/origin/main")
      refute stale_main == main_tip

      gate = start_gate(rig, ctx, revise_command: [@revise_hang], rounds: 2)

      wait_until(fn -> :sys.get_state(gate).fix_node != nil end)
      state = :sys.get_state(gate)

      assert %{id: "node-a"} = state.fix_node
      # The lease the gate's push is pinned to is the head the node was seeded from.
      assert state.pushed_remote_head == forge_head(ctx, rig.branch)
      # The node's seed source was refreshed from the forge: origin/<target> at its tip.
      assert sha(rig.wt, "refs/remotes/origin/main") == main_tip

      # The pass's run is counted on the node, not against the primary's cap.
      assert %{meta: %{placed_node_id: "node-a"}} = Worker.state(impl_pid(state))
      stop_gate(gate)
    end

    test "no node with room: the fix round runs on the primary", ctx do
      rig = rig(ctx, "feature/rf-2")

      gate =
        start_gate(rig, ctx,
          revise_command: [@revise_hang],
          rounds: 2,
          placement_opts: placement([node_row("a", live: 2, max: 2)])
        )

      wait_until(fn -> Worker.whereis(impl_id(gate)) != nil end)
      assert :sys.get_state(gate).fix_node == nil
      stop_gate(gate)
    end

    test "a local_only workspace never reads a node", ctx do
      rig = rig(ctx, "feature/rf-3")
      ws = workspace!("local_only")

      gate =
        start_gate(rig, %{ctx | ws: ws},
          revise_command: [@revise_hang],
          rounds: 2,
          placement_opts: [nodes: fn -> flunk("nodes read for a local_only fix round") end]
        )

      wait_until(fn -> Worker.whereis(impl_id(gate)) != nil end)
      assert :sys.get_state(gate).fix_node == nil
      stop_gate(gate)
    end
  end

  describe "remote_only" do
    test "holds the fix round while no node has room: nothing spawned, no round consumed",
         ctx do
      ctx = %{ctx | ws: workspace!("remote_only")}
      rig = rig(ctx, "feature/rf-5")

      # The reviewer finds a node; by the time its findings come back none has room.
      free? = start_supervised!({Agent, fn -> true end})

      nodes = fn ->
        if Agent.get(free?, & &1), do: [node_row("a")], else: [node_row("a", live: 2, max: 2)]
      end

      gate =
        start_gate(rig, ctx,
          revise_command: [@revise_commit],
          rounds: 2,
          placement_opts: [nodes: nodes, remote_available?: true],
          local_capacity_retry_ms: 25
        )

      wait_until(fn -> :sys.get_state(gate).review_node != nil end)
      Agent.update(free?, fn _ -> false end)

      wait_until(fn -> :sys.get_state(gate).local_hold != nil end)
      held = :sys.get_state(gate)
      assert held.local_hold.info.mode == :remote_only
      assert held.fix_node == nil
      assert Worker.whereis(impl_id(gate)) == nil
      refute Ash.get!(Issue, rig.task.id).last_reviewed_sha

      # A node frees a slot: the round starts there and the gate goes on to round 2.
      Agent.update(free?, fn _ -> true end)
      wait_until(fn -> Ash.get!(Issue, rig.task.id).last_reviewed_sha != nil end, 30_000)
    end
  end

  describe "a held fix round across a server restart (bd-3fbj83)" do
    test "the boot sweep re-arms a held fix round, held again until room frees, then it runs",
         ctx do
      ctx = %{ctx | ws: workspace!("remote_only")}
      rig = rig(ctx, "feature/rf-held")

      free? = start_supervised!({Agent, fn -> true end})

      nodes = fn ->
        if Agent.get(free?, & &1), do: [node_row("a")], else: [node_row("a", live: 2, max: 2)]
      end

      placement_opts = [nodes: nodes, remote_available?: true]

      gate =
        start_gate(rig, ctx,
          revise_command: [@revise_commit],
          rounds: 2,
          placement_opts: placement_opts,
          local_capacity_retry_ms: 25
        )

      wait_until(fn -> :sys.get_state(gate).review_node != nil end)
      Agent.update(free?, fn _ -> false end)
      wait_until(fn -> :sys.get_state(gate).local_hold != nil end)

      # The restart: the gate dies with no terminate/2, so the hold, which lived
      # only in its process, is gone. What is left is the ticket.
      ref = Process.monitor(gate)
      Process.exit(gate, :kill)
      assert_receive {:DOWN, ^ref, :process, ^gate, :killed}

      aref = Process.monitor(rig.author)
      Process.exit(rig.author, :kill)
      assert_receive {:DOWN, ^aref, :process, _, _}

      issue = Ash.get!(Issue, rig.task.id)
      assert %{"phase" => "revising", "held" => true} = Arbiter.Worker.ReviewPass.stored(issue)

      rearm = fn %Issue{id: id} ->
        ReviewGate.rearm_pass(id,
          revise_command: [@revise_commit],
          command: [@two_rounds, marker(ctx, rig), rig.branch],
          command_provider: "claude",
          rounds: 2,
          placement_opts: placement_opts,
          local_capacity_retry_ms: 25
        )
      end

      # Still no room after the restart: the sweep re-arms it, held again.
      assert {:ok, %{restarted: [%{task_id: task_id, phase: :revising}]}} =
               Arbiter.Workers.Reconciler.reconcile_review_passes(rearm_fun: rearm)

      assert task_id == rig.task.id
      assert %{"held" => true} = Arbiter.Worker.ReviewPass.stored(Ash.get!(Issue, task_id))

      # Room frees: the round runs and the gate goes on to round 2.
      Agent.update(free?, fn _ -> true end)
      wait_until(fn -> Ash.get!(Issue, task_id).last_reviewed_sha != nil end, 30_000)
    end
  end

  describe "the host push of what the fix round brought back" do
    test "a rebased branch is delivered with the lease and round 2 reviews the new head", ctx do
      rig = rig(ctx, "feature/rf-6")
      round1_head = sha(rig.wt, "HEAD")

      start_gate(rig, ctx,
        command: [@two_rounds, marker(ctx, rig), rig.branch],
        revise_command: [@revise_rewrite],
        rounds: 2
      )

      wait_until(fn -> Ash.get!(Issue, rig.task.id).last_reviewed_sha != nil end, 60_000)

      rewritten = sha(rig.wt, "HEAD")
      refute rewritten == round1_head
      git!(["fetch", "-q", "origin"], ctx.repo)
      assert sha(ctx.repo, "origin/" <> rig.branch) == rewritten
    end

    test "a third party's push after seeding is not overwritten; the task parks", ctx do
      rig = rig(ctx, "feature/rf-7")
      other = clone_other!(ctx, rig.branch)
      File.write!(Path.join(other, "theirs.txt"), "theirs\n")
      git!(["add", "theirs.txt"], other)
      git!(["commit", "-q", "-m", "theirs"], other)
      theirs = sha(other, "HEAD")

      script = Path.join(ctx.tmp, "rewrite_then_third_party_push.sh")

      File.write!(script, """
      #!/bin/sh
      #{@revise_rewrite}
      git -C #{other} push -q origin #{rig.branch}
      """)

      File.chmod!(script, 0o755)

      start_gate(rig, ctx,
        command: [@two_rounds, marker(ctx, rig), rig.branch],
        revise_command: [script],
        rounds: 2
      )

      wait_until(fn -> ReviewPark.parked?(Ash.get!(Issue, rig.task.id)) end, 60_000)
      assert Ash.get!(Issue, rig.task.id).attention_cause == :head_not_pushed

      git!(["fetch", "-q", "origin"], ctx.repo)
      assert sha(ctx.repo, "origin/" <> rig.branch) == theirs
    end
  end

  describe "the node under a fix round is lost" do
    test "the round is dispatched again, placed afresh, and no round is consumed", ctx do
      rig = rig(ctx, "feature/rf-8")

      gate = start_gate(rig, ctx, revise_command: [@revise_hang], rounds: 2)

      wait_until(fn -> :sys.get_state(gate).fix_node != nil end)
      %{current_id: lost_id} = :sys.get_state(gate)

      # The node is gone: nothing is left to place on, and the re-dispatched round
      # answers at once.
      :sys.replace_state(gate, fn s ->
        %{s | revise_command: [@revise_commit], placement_opts: placement([])}
      end)

      Phoenix.PubSub.broadcast(Arbiter.PubSub, "worker:" <> lost_id, {:worker_node_lost, lost_id})

      wait_until(fn -> Ash.get!(Issue, rig.task.id).last_reviewed_sha != nil end, 60_000)
    end
  end

  describe "the node's final checkout of a fix round did not come back" do
    test "the stale clone is not pushed: the round runs again on the primary", ctx do
      rig = rig(ctx, "feature/rf-9")
      before_push = forge_head(ctx, rig.branch)

      gate = start_gate(rig, ctx, revise_command: [@revise_hang], rounds: 2)

      wait_until(fn -> :sys.get_state(gate).fix_node != nil end)
      %{current_id: failed_id} = :sys.get_state(gate)

      # A node with room is still there; the re-run must not go back to it. The
      # re-run answers at once, with a commit.
      :sys.replace_state(gate, fn s -> %{s | revise_command: [@revise_commit]} end)

      # What `ClaudeSession` broadcasts for a node that reported `"checkout": "failed…"`.
      topic = "worker:" <> failed_id
      Phoenix.PubSub.broadcast(Arbiter.PubSub, topic, {:worker_checkout_failed, failed_id})
      Phoenix.PubSub.broadcast(Arbiter.PubSub, topic, {:worker_exited, failed_id, 0})

      wait_until(fn -> :sys.get_state(gate).current_id != failed_id end)
      state = :sys.get_state(gate)
      assert state.fix_node == nil
      assert state.fix_round_local? == true
      assert state.round == 1

      # The failed pass was not finished: nothing was pushed for it, and the re-run's
      # work is what gets reviewed.
      assert forge_head(ctx, rig.branch) == before_push
      wait_until(fn -> Ash.get!(Issue, rig.task.id).last_reviewed_sha != nil end, 60_000)
    end
  end

  # ---- helpers -----------------------------------------------------------------

  defp stop_gate(gate) do
    ref = Process.monitor(gate)

    try do
      GenServer.stop(gate, :normal)
    catch
      :exit, _ -> :ok
    end

    assert_receive {:DOWN, ^ref, :process, ^gate, _}, 5_000
  end

  # The reviewer fixture's round marker, outside every checkout.
  defp marker(ctx, rig), do: Path.join(ctx.tmp, "round-marker-#{rig.task.id}")

  defp forge_head(ctx, branch) do
    {out, 0} = git(["rev-parse", "refs/heads/" <> branch], Path.join(ctx.tmp, "origin.git"))
    String.trim(out)
  end

  defp impl_pid(state), do: Worker.whereis(state.current_id)

  defp impl_id(gate), do: :sys.get_state(gate).current_id || "none"

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp clone_other!(ctx, branch) do
    other = Path.join(ctx.tmp, "other-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", Path.join(ctx.tmp, "origin.git"), other])
    git!(["config", "user.email", "o@example.com"], other)
    git!(["config", "user.name", "O"], other)
    git!(["config", "commit.gpgsign", "false"], other)
    git!(["checkout", "-q", branch], other)
    other
  end

  defp third_party_main!(ctx) do
    other = clone_other!(ctx, "main")
    File.write!(Path.join(other, "NEWER.md"), "newer\n")
    git!(["add", "NEWER.md"], other)
    git!(["commit", "-q", "-m", "main moved"], other)
    git!(["push", "-q", "origin", "main"], other)
    sha(other, "HEAD")
  end

  # A feature branch with one commit, pushed, in the author's private clone (the
  # layout a container gets, and the only one a node is seeded from).
  defp rig(ctx, branch) do
    {:ok, task} =
      Ash.create(Issue, %{title: "fix round task", workspace_id: ctx.ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    git!(["checkout", "-q", "-b", branch], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "feature work"], ctx.repo)
    git!(["push", "-q", "origin", branch], ctx.repo)
    git!(["checkout", "-q", "main"], ctx.repo)

    {:ok, wt} = PrivateClone.attach(ctx.repo, branch, "main")
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["fetch", "-q", "origin", branch], wt)
    git!(["branch", "-q", "--set-upstream-to=origin/" <> branch, branch], wt)

    %{task: task, branch: branch, wt: wt, author: start_author(task, ctx, branch, wt)}
  end

  defp start_author(task, ctx, branch, wt) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ctx.ws.id,
        meta: %{
          branch: branch,
          repo_path: ctx.repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
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

  defp start_gate(rig, ctx, opts) do
    {:ok, gate} =
      ReviewGate.start(
        Keyword.merge(
          [
            author: rig.author,
            task_id: rig.task.id,
            workspace_id: ctx.ws.id,
            repo: "trib/repo",
            worktree_path: rig.wt,
            branch: rig.branch,
            target_branch: "main",
            timeout_ms: 15_000,
            command: [@two_rounds, marker(ctx, rig), rig.branch],
            command_provider: "claude",
            placement_opts: placement([node_row("a")])
          ],
          opts
        )
      )

    gate
  end

  defp wait_until(fun, timeout \\ 5_000) do
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
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end
end
