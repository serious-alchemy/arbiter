defmodule Arbiter.Worker.RunTmpLifecycleTest do
  use ExUnit.Case, async: false

  alias Arbiter.Worker.{ClaudeSession, RunTmp}

  setup do
    root = Path.join(System.tmp_dir!(), "run-tmp-life-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "cwd")
    File.mkdir_p!(cwd)
    previous = Application.get_env(:arbiter, :worker_tmp_root)
    Application.put_env(:arbiter, :worker_tmp_root, Path.join(root, "tmp"))

    on_exit(fn ->
      Application.put_env(:arbiter, :worker_tmp_root, previous)
      RunTmp.force_rm_rf(root)
    end)

    {:ok, root: root, cwd: cwd}
  end

  # A stand-in for the Worker: owns the port the way the real one does.
  defmodule Owner do
    use GenServer
    def init(_), do: {:ok, nil}

    def handle_call(:snapshot, _from, state), do: {:reply, %{task_id: "bd-life"}, state}

    def handle_call({:__claude_session_open__, args, _cfg}, _from, state) do
      {:reply, {:ok, ClaudeSession.open_port(args)}, state}
    end
  end

  defp spawn_agent(cwd, script) do
    {:ok, owner} = GenServer.start(Owner, nil)

    {:ok, port} =
      ClaudeSession.start(owner: owner, worktree_path: cwd, command: ["sh", "-c", script])

    {owner, port}
  end

  defp wait_for_file(path) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_for_file(path)
        )
  end

  # Cleanup runs asynchronously after the owner exits; poll with a bounded deadline.
  defp assert_removed(path, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      not File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{path} still exists after 5s")

      true ->
        Process.sleep(10)
        assert_removed(path, deadline)
    end
  end

  test "the child's TMPDIR is a per-run dir under the worker tmp root, and it is removed on exit",
       %{root: root, cwd: cwd} do
    out = Path.join(root, "seen")

    {owner, _port} =
      spawn_agent(cwd, "echo $TMPDIR:$TMP:$TEMP > #{out}; touch $TMPDIR/x; sleep 30")

    wait_for_file(out)
    [tmpdir, tmp, temp] = out |> File.read!() |> String.trim() |> String.split(":")
    assert tmpdir == tmp and tmp == temp
    assert String.starts_with?(tmpdir, Path.join(root, "tmp") <> "/")
    assert File.dir?(tmpdir)

    # read-only content must not block removal
    File.mkdir_p!(Path.join(tmpdir, "ro"))
    File.write!(Path.join(tmpdir, "ro/f"), "x")
    File.chmod!(Path.join(tmpdir, "ro"), 0o500)

    ref = Process.monitor(owner)
    GenServer.stop(owner, :normal)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    _ = :sys.get_state(RunTmp.Reaper)
    assert_removed(tmpdir)
  end

  test "a killed owner (no terminate/2) still has its dir removed", %{root: root, cwd: cwd} do
    out = Path.join(root, "seen")
    {owner, _port} = spawn_agent(cwd, "echo $TMPDIR > #{out}; sleep 30")
    wait_for_file(out)
    tmpdir = out |> File.read!() |> String.trim()
    assert File.dir?(tmpdir)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    _ = :sys.get_state(RunTmp.Reaper)
    assert_removed(tmpdir)
  end

  test "the agent prompt tells the agent to use $TMPDIR" do
    issue = %Arbiter.Tasks.Issue{id: "x", title: "t", issue_type: :feature}
    prompt = Arbiter.Worker.PromptBuilder.prompt_for_task(issue, worktree_path: "/w/x")
    assert prompt =~ "$TMPDIR"
  end
end
