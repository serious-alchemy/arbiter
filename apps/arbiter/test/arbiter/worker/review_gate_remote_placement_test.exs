defmodule Arbiter.Worker.ReviewGateRemotePlacementTest do
  @moduledoc """
  bd-cgdhlu — a ReviewGate reviewer is placed like any other podman Claude run:
  on a node with headroom under `prefer_remote`, held under `remote_only` while
  none has room, and re-dispatched (never parked `reviewer_failed`) when the node
  under it is lost or the primary restarts.

  Real git, a real author `Worker`, the real gate and a shell reviewer fixture.
  This host has no node and no podman, so the node itself is the `:nodes` row the
  gate's `placement_opts` hands `Placement.place/2`; the fixture `command:` stands
  in for the reviewer, which is what keeps it local either way. What is pinned
  here is the gate's side: where it decided the pass runs, and that its round
  bookkeeping is the same row a local reviewer leaves. The node side (the seeded
  read-only clone, the transcript mirror) is `ArbiterWeb.RemoteReviewTest`.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.CircuitBreaker
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workers.Reconciler

  @probe Path.expand("../../fixtures/review_checkout_probe.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-rp-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{repo: repo, tmp: tmp, log: Path.join(tmp, "probe.log")}
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

  # A workspace whose reviewer runs in a container on a private clone (the only
  # layout a node is handed), at the given `worker.placement`.
  defp workspace!(mode) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-rp-#{System.unique_integer([:positive])}",
        prefix: "rp",
        config: %{
          "review" => %{"required" => true, "require_ci_green" => false},
          "review_gate" => %{"max_fix_rounds" => 0},
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

  describe "prefer_remote" do
    test "places the reviewer on a node with headroom and keeps it there for the round", ctx do
      row = node_row("a")
      ctx = Map.put(ctx, :ws, workspace!("prefer_remote"))
      rig = rig(ctx, "feature/rp-1")

      gate = start_gate(rig, ctx, command: [@probe, ctx.log], placement_opts: placement([row]))

      assert_gate_reports(gate, rig)
      assert [%{verdict: :approve, round: 1}] = review_rounds(rig)
      assert passes(ctx) == 1
      # The reviewer read exactly the head under review.
      assert [line] = probe_lines(ctx)
      assert line =~ "head=" <> rig.head
    end

    test "state records the node the first pass was placed on", ctx do
      row = node_row("a")
      ctx = Map.put(ctx, :ws, workspace!("prefer_remote"))
      rig = rig(ctx, "feature/rp-2")

      gate =
        start_gate(rig, ctx, command: [@probe, ctx.log, "HANG"], placement_opts: placement([row]))

      wait_until(fn -> passes(ctx) == 1 end)

      assert %{review_node: %{id: "node-a"}} = :sys.get_state(gate)
      stop_gate(gate)
    end

    test "runs the reviewer locally when no node has headroom", ctx do
      full = node_row("a", live: 2, max: 2)
      ctx = Map.put(ctx, :ws, workspace!("prefer_remote"))
      rig = rig(ctx, "feature/rp-3")

      gate =
        start_gate(rig, ctx,
          command: [@probe, ctx.log, "HANG"],
          placement_opts: placement([full])
        )

      wait_until(fn -> passes(ctx) == 1 end)

      assert %{review_node: :local, local_hold: nil} = :sys.get_state(gate)
      stop_gate(gate)
    end
  end

  describe "remote_only" do
    test "holds the reviewer while no node has room — nothing spawned, no verdict, no round",
         ctx do
      full = node_row("a", live: 2, max: 2)
      ctx = Map.put(ctx, :ws, workspace!("remote_only"))
      rig = rig(ctx, "feature/rp-4")

      gate =
        start_gate(rig, ctx,
          command: [@probe, ctx.log],
          placement_opts: placement([full]),
          local_capacity_retry_ms: 25
        )

      wait_until(fn -> :sys.get_state(gate).local_hold != nil end)
      held = :sys.get_state(gate)
      assert held.local_hold.info.mode == :remote_only
      assert passes(ctx) == 0
      assert held.review_node == nil
      assert Process.alive?(gate)
      assert Ash.get!(Issue, rig.task.id).review_gate_state["verdict"] == nil
      assert review_rounds(rig) == []

      # A node frees a slot: the held pass starts there, on the same round.
      :sys.replace_state(gate, &%{&1 | placement_opts: placement([node_row("b")])})

      assert_gate_reports(gate, rig)
      assert [%{verdict: :approve, round: 1}] = review_rounds(rig)
      assert passes(ctx) == 1
      # The reviewer read exactly the head under review.
      assert [line] = probe_lines(ctx)
      assert line =~ "head=" <> rig.head
    end
  end

  describe "a workspace that is local_only" do
    test "never reads a node: the reviewer runs on the primary exactly as before", ctx do
      ctx = Map.put(ctx, :ws, workspace!("local_only"))
      rig = rig(ctx, "feature/rp-5")

      gate =
        start_gate(rig, ctx,
          command: [@probe, ctx.log],
          placement_opts: placement([node_row("a")])
        )

      assert_gate_reports(gate, rig)
      assert [%{verdict: :approve, round: 1}] = review_rounds(rig)
    end
  end

  describe "the node under a reviewer is lost" do
    test "the same pass is dispatched again — no reviewer_failed, no round consumed", ctx do
      ctx = Map.put(ctx, :ws, workspace!("prefer_remote"))
      rig = rig(ctx, "feature/rp-6")

      gate =
        start_gate(rig, ctx,
          command: [@probe, ctx.log, "HANG"],
          placement_opts: placement([node_row("a")]),
          rounds: 1
        )

      wait_until(fn -> passes(ctx) == 1 end)
      %{current_id: lost_id, round: round, review_node: %{id: "node-a"}} = :sys.get_state(gate)

      # The re-dispatched pass answers; the node is gone, so it is placed afresh
      # (here: no node is left, so locally).
      :sys.replace_state(gate, &%{&1 | command: [@probe, ctx.log]})
      :sys.replace_state(gate, &%{&1 | placement_opts: placement([])})

      Phoenix.PubSub.broadcast(Arbiter.PubSub, "worker:" <> lost_id, {:worker_node_lost, lost_id})

      assert_gate_reports(gate, rig)
      assert passes(ctx) == 2
      assert [%{verdict: :approve, round: ^round}] = review_rounds(rig)

      assert Round
             |> Ash.Query.filter(task_id == ^rig.task.id and verdict in [:timed_out, :error])
             |> Ash.read!() == []

      assert Ash.get!(Issue, rig.task.id).review_gate_state["verdict"] != "reviewer_failed"
    end

    test "a node lost under a reviewer with no free node holds under remote_only, then resumes",
         ctx do
      ctx = Map.put(ctx, :ws, workspace!("remote_only"))
      rig = rig(ctx, "feature/rp-7")

      gate =
        start_gate(rig, ctx,
          command: [@probe, ctx.log, "HANG"],
          placement_opts: placement([node_row("a")]),
          local_capacity_retry_ms: 25
        )

      wait_until(fn -> passes(ctx) == 1 end)
      %{current_id: lost_id} = :sys.get_state(gate)

      :sys.replace_state(gate, fn s ->
        %{s | command: [@probe, ctx.log], placement_opts: placement([])}
      end)

      Phoenix.PubSub.broadcast(Arbiter.PubSub, "worker:" <> lost_id, {:worker_node_lost, lost_id})

      wait_until(fn -> :sys.get_state(gate).local_hold != nil end)
      assert passes(ctx) == 1
      assert review_rounds(rig) == []

      :sys.replace_state(gate, &%{&1 | placement_opts: placement([node_row("b")])})
      assert_gate_reports(gate, rig)
      assert [%{verdict: :approve}] = review_rounds(rig)
    end

    test "a lost-node message for a pass the gate has moved past is ignored", ctx do
      ctx = Map.put(ctx, :ws, workspace!("prefer_remote"))
      rig = rig(ctx, "feature/rp-8")

      gate =
        start_gate(rig, ctx,
          command: [@probe, ctx.log, "HANG"],
          placement_opts: placement([node_row("a")])
        )

      wait_until(fn -> passes(ctx) == 1 end)
      send(gate, {:worker_node_lost, "some-other-pass"})
      _ = :sys.get_state(gate)

      assert passes(ctx) == 1
      stop_gate(gate)
    end
  end

  describe "the primary restarts under a reviewer on a node" do
    test "the boot sweep re-dispatches the pass, placed afresh, and never parks it", ctx do
      ctx = Map.put(ctx, :ws, workspace!("prefer_remote"))
      rig = rig(ctx, "feature/rp-9")

      gate =
        start_gate(rig, ctx,
          command: [@probe, ctx.log, "HANG"],
          placement_opts: placement([node_row("a")]),
          rounds: 3
        )

      wait_until(fn -> passes(ctx) == 1 and pass_marker(rig) != nil end)
      node_stops(rig, gate)

      me = self()

      rearm = fn issue ->
        result =
          ReviewGate.rearm_pass(issue.id,
            timeout_ms: 15_000,
            rounds: 3,
            command: [@probe, ctx.log],
            placement_opts: placement([node_row("b")])
          )

        send(me, {:rearmed, result})
        result
      end

      assert {:ok, %{rearmed: 1, failed: 0}} =
               Reconciler.reconcile_review_passes(rearm_fun: rearm)

      assert_received {:rearmed, {:ok, regate}}

      ref = Process.monitor(regate)
      assert_receive {:DOWN, ^ref, :process, ^regate, reason}, 30_000
      assert reason in [:normal, :noproc]

      assert passes(ctx) == 2
      assert [%{verdict: :approve, round: 1}] = review_rounds(rig)
      assert Ash.get!(Issue, rig.task.id).review_gate_state["verdict"] != "reviewer_failed"
    end
  end

  # ---- helpers -----------------------------------------------------------------

  defp assert_gate_reports(gate, _rig) do
    ref = Process.monitor(gate)
    assert_receive {:DOWN, ^ref, :process, ^gate, reason}, 30_000
    assert reason in [:normal, :noproc]
  end

  defp stop_gate(gate) do
    ref = Process.monitor(gate)
    GenServer.stop(gate, :normal)
    assert_receive {:DOWN, ^ref, :process, ^gate, _}, 5_000
  end

  # The node stops: the author and the pass workers go with `:shutdown`, the gate
  # is killed with no `terminate/2`, so only what the ticket recorded survives.
  defp node_stops(rig, gate) do
    :ok = GenServer.stop(rig.author, :shutdown)

    gate_ref = Process.monitor(gate)
    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^gate_ref, :process, ^gate, _}, 5_000

    for suffix <- ["#review", "#review#r2"], pid = Worker.whereis(rig.task.id <> suffix) do
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    wait_until(fn -> Worker.whereis(rig.task.id) == nil end)
  end

  defp pass_marker(rig), do: Ash.get!(Issue, rig.task.id).review_gate_state["pass"]

  defp review_rounds(rig) do
    Round
    |> Ash.Query.filter(task_id == ^rig.task.id and role == :review)
    |> Ash.read!()
    |> Enum.sort_by(& &1.round)
  end

  # One line per reviewer pass: `cwd=<checkout> head=<sha> dirty=<yes|no>`.
  defp probe_lines(ctx) do
    case File.read(ctx.log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  defp passes(ctx), do: length(probe_lines(ctx))

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

  # A feature branch with one commit, in its own worktree, already pushed.
  defp rig(ctx, branch) do
    {:ok, task} =
      Ash.create(Issue, %{title: "placement task", workspace_id: ctx.ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    git!(["checkout", "-q", "-b", branch], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "feature work"], ctx.repo)
    git!(["checkout", "-q", "main"], ctx.repo)

    wt = Path.join(ctx.tmp, "wt-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: ctx.repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["push", "-q", "-u", "origin", branch], wt)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", ctx.repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    %{
      task: task,
      branch: branch,
      wt: wt,
      head: sha(wt, "HEAD"),
      author: start_author(task, ctx, branch, wt)
    }
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
            rounds: 1
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
