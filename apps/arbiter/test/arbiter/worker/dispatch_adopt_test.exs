defmodule Arbiter.Worker.DispatchAdoptTest do
  @moduledoc """
  bd-4p1vui (`docs/design/remote-workers.md` §10.4.3, §10.4.6 F5/F7): `Dispatch.adopt/2`
  builds the Worker that adopts a run a node kept across a primary restart: a resume
  whose spawn is told the run to adopt instead of a container to start.

  Driven against a real git repo and a podman-sandboxed workspace (so the home clone is a
  private clone, as for any remote run). The node is stood in for at the `:claude_start`
  seam, which hands the Worker the adopted session exactly as `ClaudeSession.start/1`
  does once the node has answered.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{ClaudeSession, Dispatch}
  alias Arbiter.Workers.Run

  require Ash.Query

  @repo "adopt/repo"

  setup do
    claude_credential_env!()
    tmp = Path.join(System.tmp_dir!(), "adopt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    put_app_env(:arbiter, :repo_paths, %{@repo => seed_repo!(tmp)})

    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "adopt-ws-#{n}",
        prefix: "ad#{n}",
        config: %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}}
      })

    {:ok, task} = Ash.create(Issue, %{title: "work on a node", workspace_id: ws.id})

    # Dispatched once (so its home clone exists and it is In progress), then its Worker
    # went down with the old primary, leaving its run to the node: the row stays live.
    {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: @repo, start_driver: false)
    run_id = Worker.state(first.worker_pid).run_id
    :sys.replace_state(first.worker_pid, &%{&1 | run_id: nil})
    :ok = Worker.stop(first.worker_pid, :normal)

    {:ok, %{token: token}} = Nodes.mint_join_token([name: "adopt-node-#{n}"], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)

    row =
      Run
      |> Ash.get!(run_id)
      |> Ash.update!(
        %{
          state: :working,
          node_id: node.id,
          role: "base",
          provider: "claude",
          session_id: "sess-before-restart",
          config_dir: "/old/primary/claude-config"
        },
        action: :update
      )

    on_exit(fn -> if pid = Worker.whereis(task.id), do: safe_stop(pid) end)
    %{task: task, row: row, node: node}
  end

  defp safe_stop(pid) do
    Worker.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp seed_repo!(tmp) do
    repo = Path.join(tmp, "repo")
    remote = Path.join(tmp, "repo-remote.git")
    File.mkdir_p!(repo)
    git = fn args -> {_, 0} = System.cmd("git", args, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main", repo])
    git.(["-C", repo, "config", "user.email", "t@e.com"])
    git.(["-C", repo, "config", "user.name", "T"])
    git.(["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    git.(["-C", repo, "add", "README.md"])
    git.(["-C", repo, "commit", "-q", "-m", "i"])
    git.(["init", "-q", "--bare", "-b", "main", remote])
    git.(["-C", repo, "remote", "add", "origin", remote])
    git.(["-C", repo, "push", "-q", "origin", "main"])
    repo
  end

  # Stands in for the node answering the adoption: the Worker gets the run's handle as
  # `ClaudeSession.start/1` gives it after `Executor.Node.adopt/3`.
  defp node_hands_over(test) do
    fn session_opts ->
      send(test, {:session_opts, session_opts})
      owner = Keyword.fetch!(session_opts, :owner)
      %{run_id: run_id, node_id: node_id} = Keyword.fetch!(session_opts, :adopt)
      handle = {:remote, {node_id, run_id, make_ref()}}

      args = %{
        exec: "claude",
        argv: ["claude"],
        cd: Keyword.fetch!(session_opts, :worktree_path),
        env: [],
        remote: %{node: node_id, request: %{}, run_id: run_id, prepared: handle, stdout_start: 0}
      }

      config =
        ClaudeSession.build_session_config(Worker.state(owner).task_id, nil,
          provider: "claude",
          redact_values: [],
          argv: ["claude"]
        )

      GenServer.call(owner, {:__claude_session_open__, args, config})
    end
  end

  defp rows_for(task_id),
    do: Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!() |> Enum.map(& &1.id)

  test "the Worker takes the run over: its row, no new one, and the spawn told what to adopt where",
       %{task: task, row: row, node: node} do
    assert {:ok, %{worker_pid: pid, run_id: run_id}} =
             Dispatch.adopt(row, claude_start: node_hands_over(self()), start_driver: false)

    assert run_id == row.id
    assert Worker.whereis(task.id) == pid
    snap = Worker.state(pid)
    assert snap.run_id == row.id
    assert snap.state == :working
    assert %{run_id: adopted, node_id: node_id} = snap.meta.adopted
    assert adopted == row.id
    assert node_id == node.id
    assert rows_for(task.id) == [row.id]

    assert_received {:session_opts, opts}

    assert %{run_id: ^adopted, node_id: ^node_id, session_id: "sess-before-restart"} =
             opts[:adopt]

    assert %{id: ^node_id} = opts[:node]
    # the spawn is the podman one a placement would build (that is what re-opens use)
    assert opts[:security].sandbox.backend == :podman

    assert %{state: :working, outcome: nil, config_dir: "/old/primary/claude-config"} =
             Ash.get!(Run, row.id)
  end

  test "a failure before the node handed the run over (F5) leaves no Worker and the row untouched",
       %{task: task, row: row} do
    assert {:error, {:adoption_failed, _}} =
             Dispatch.adopt(row,
               claude_start: fn _opts -> {:error, :node_refused} end,
               start_driver: false
             )

    assert Worker.whereis(task.id) == nil
    assert rows_for(task.id) == [row.id]
    assert %{state: :working, outcome: nil, completed_at: nil} = Ash.get!(Run, row.id)
  end

  test "a failure after the session was adopted (F7) is undone the same way", %{
    task: task,
    row: row
  } do
    assert {:error, {:adoption_failed, {:machine_start_failed, _}}} =
             Dispatch.adopt(row,
               claude_start: node_hands_over(self()),
               start_driver: false,
               workflow_module: Arbiter.NoSuchWorkflow
             )

    assert Worker.whereis(task.id) == nil
    assert %{state: :working, outcome: nil, completed_at: nil} = Ash.get!(Run, row.id)
  end

  test "a row that is not adoptable, or a ticket with a Worker already, is refused before anything starts",
       %{task: task, row: row} do
    test = self()
    never = fn _ -> send(test, :spawned) && {:error, :not_expected} end

    {:ok, review} = Ash.update(row, %{role: "review"}, action: :update)
    assert {:error, {:ineligible, :role}} = Dispatch.adopt(review, claude_start: never)

    {:ok, pid} = Worker.start(task_id: task.id, repo: @repo)
    assert {:error, :worker_present} = Dispatch.adopt(row, claude_start: never)
    :ok = Worker.stop(pid, :normal)

    refute_received :spawned
  end
end
