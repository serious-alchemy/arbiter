defmodule Arbiter.WorkerOpenMrTest do
  @moduledoc """
  `Worker.open_mr/5` (bd-741sid): opening the MR is the end of the run. The PR
  is recorded on the ticket (`:merging`), the ticket's Watchdog takes it, and
  the worker exits with its run finished and successful. Before bd-741sid the
  worker parked at `:awaiting_review` and stayed resident as the PR's only
  home; `Arbiter.Worker.PrOpenEndsRunTest` pins the full PR state on the row.
  """

  # async: false — shares the singleton Worker registry/supervisor + the
  # named StubMerger Agent.
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog

  setup do
    StubMerger.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{name: "open-mr-#{System.unique_integer([:positive])}", prefix: "om"})

    %{ws: ws}
  end

  defp running_worker(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "open mr", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(pid) end)
    on_exit(fn -> stop_quietly(Watchdog.whereis(task.id)) end)
    {pid, task}
  end

  defp stop_quietly(nil), do: :ok

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Park well into the future so the Watchdog doesn't poll while we assert on
  # the hand-off itself.
  @parked [interval_ms: 1_000_000, initial_delay_ms: 1_000_000]

  defp open_opts(ws, extra),
    do: Map.merge(%{adapter: StubMerger, workspace: ws}, Map.new(extra))

  defp wait_until(fun, timeout \\ 2_000) do
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
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  describe "open_mr/5" do
    test "records the PR on the ticket, hands it to the ticket's Watchdog and ends the run",
         %{ws: ws} do
      {pid, task} = running_worker(ws)
      ref = Process.monitor(pid)
      StubMerger.next_open_ref("!42")

      assert {:ok, "!42"} =
               Worker.open_mr(pid, "feature/x", "Add x", "desc", open_opts(ws, @parked))

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      ticket = Ash.get!(Issue, task.id)
      assert ticket.state == :merging
      assert ticket.pr_ref == "!42"
      assert ticket.merger_url == "https://stub.example/mr/!42"
      assert is_pid(Watchdog.whereis(task.id))
    end

    test "forwards branch/title/description and opts to the adapter", %{ws: ws} do
      {pid, _task} = running_worker(ws)

      assert {:ok, _} =
               Worker.open_mr(
                 pid,
                 "feature/y",
                 "Title Y",
                 "Body Y",
                 open_opts(ws, Keyword.merge(@parked, target_branch: "develop", labels: ["wip"]))
               )

      open = StubMerger.last_open()
      assert open.branch == "feature/y"
      assert open.title == "Title Y"
      assert open.description == "Body Y"
      assert open.opts.target_branch == "develop"
      assert open.opts.labels == ["wip"]
    end

    test "is rejected from :starting", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "idle", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
      on_exit(fn -> stop_quietly(pid) end)

      assert {:error, {:invalid_transition, :starting, :open_mr}} =
               Worker.open_mr(pid, "feature/z", "Z", "", open_opts(ws, @parked))

      assert Worker.state(pid).state == :starting
    end

    test "an adapter open error leaves the worker :working", %{ws: ws} do
      {pid, task} = running_worker(ws)

      assert {:error, _} = Worker.open_mr(pid, "feature/q", "Q", "", %{adapter: nil})

      assert Worker.state(pid).state == :working
      assert Ash.get!(Issue, task.id).state == :active
    end

    test "end-to-end: a merged MR closes the ticket via its Watchdog", %{ws: ws} do
      {pid, task} = running_worker(ws)
      StubMerger.next_open_ref("!7")
      StubMerger.queue_get("!7", [%{status: :merged}])

      assert {:ok, "!7"} =
               Worker.open_mr(
                 pid,
                 "feature/done",
                 "Done",
                 "",
                 open_opts(ws, interval_ms: 20, initial_delay_ms: 0)
               )

      wait_until(fn -> Ash.get!(Issue, task.id).state == :closed end)
    end
  end

  # bd-73zv62: a workspace merging via GitHub holds a remote-less repo with a
  # `merge.repos.mesaana.strategy = "direct"` override. A run in that repo
  # resolves the Direct merger (no `:adapter` override here — the real
  # resolution path) and merges locally, with nothing to push.
  describe "per-repo merge strategy override (bd-73zv62)" do
    @tag :tmp_dir
    test "a run in a direct-override repo merges locally via Mergers.Direct", %{tmp_dir: dir} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "open-mr-repo-#{System.unique_integer([:positive])}",
          prefix: "omr",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget", "credentials_ref" => "x"},
              "repos" => %{"mesaana" => %{"strategy" => "direct"}}
            },
            "repo_paths" => %{"mesaana" => dir}
          }
        })

      build_local_repo(dir)
      test_pid = self()

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        send(test_pid, {:github_call, conn.method, conn.request_path})
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      {:ok, task} =
        Ash.create(Issue, %{title: "infra fix", workspace_id: ws.id, issue_type: :feature})

      {:ok, task} = Ash.update(task, %{status: :in_progress})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "mesaana", workspace_id: ws.id)
      :ok = Worker.advance(pid, :implement)
      on_exit(fn -> stop_quietly(pid) end)
      on_exit(fn -> stop_quietly(Watchdog.whereis(task.id)) end)

      assert {:ok, ref} =
               Worker.open_mr(
                 pid,
                 "feature/x",
                 "Merge feature/x",
                 "",
                 Map.merge(%{repo_path: dir, target_branch: "main"}, Map.new(@parked))
               )

      assert ref == "direct:feature/x|#{dir}|main"
      assert File.exists?(Path.join(dir, "feature.txt"))
      assert {"main\n", 0} = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
      refute_received {:github_call, _, _}
    end
  end

  defp git(dir, args), do: System.cmd("git", args, stderr_to_stdout: true, cd: dir)

  # A local-only checkout: `main` plus a `feature/x` branch adding
  # feature.txt, and no remote at all.
  defp build_local_repo(dir) do
    {_, 0} = git(dir, ["init", "-q"])
    {_, 0} = git(dir, ["config", "user.email", "worker@example.test"])
    {_, 0} = git(dir, ["config", "user.name", "Worker"])
    {_, 0} = git(dir, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(dir, "base.txt"), "base\n")
    {_, 0} = git(dir, ["add", "base.txt"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "init"])
    {_, 0} = git(dir, ["branch", "-M", "main"])
    {_, 0} = git(dir, ["checkout", "-q", "-b", "feature/x"])
    File.write!(Path.join(dir, "feature.txt"), "feature\n")
    {_, 0} = git(dir, ["add", "feature.txt"])
    {_, 0} = git(dir, ["commit", "-q", "-m", "add feature"])
    {_, 0} = git(dir, ["checkout", "-q", "main"])
  end

  describe "via_review_gate: a ReviewGate-approved MR merges without forge approval (bd-66ey1o)" do
    # Before bd-66ey1o the Watchdog waited on `approved: true` from the adapter's
    # get/1 even when it had just been told the gate had approved. For
    # hosted-forge adapters that approval is never posted (the ReviewGate is in-
    # process), so the PR hung forever. With the `via_review_gate: true` flag
    # the Watchdog treats any non-terminal poll as `:approved` and skips
    # forge-side approval polling. bd-741sid: the flag is on the ticket's lane,
    # so a restarted Watchdog keeps it.
    #
    # bd-ddtbhb: `via_review_gate` alone no longer implies auto_merge. The
    # caller must pass `force_merge: true` to merge regardless of workspace lane.
    test "open_mr with via_review_gate + force_merge merges without forge approval", %{ws: ws} do
      {pid, task} = running_worker(ws)
      StubMerger.next_open_ref("!99")
      # No queue_get → StubMerger.get/1 returns %{status: :open, approved: false}
      # forever (the exact "hosted-forge with no approval" case).

      assert {:ok, "!99"} =
               Worker.open_mr(
                 pid,
                 "feature/trib",
                 "ReviewGate-approved merge",
                 "",
                 open_opts(ws,
                   via_review_gate: true,
                   force_merge: true,
                   interval_ms: 20,
                   initial_delay_ms: 0
                 )
               )

      wait_until(fn -> Ash.get!(Issue, task.id).state == :closed end)
      # The Watchdog must have called the adapter's merge — that's the whole
      # point of force_merge: don't just wait for a human, actually merge.
      assert StubMerger.merge_count("!99") >= 1
    end

    test "via_review_gate alone (without force_merge) respects workspace auto_merge setting",
         %{ws: ws} do
      # bd-ddtbhb: via_review_gate alone means (a) skip forge-approval polling,
      # NOT (b) merge regardless of lane. A workspace with auto_merge off must
      # not auto-merge even when via_review_gate is set.
      {pid, task} = running_worker(ws)
      StubMerger.next_open_ref("!101")

      assert {:ok, "!101"} =
               Worker.open_mr(
                 pid,
                 "feature/via-only",
                 "via_review_gate only",
                 "",
                 open_opts(ws,
                   via_review_gate: true,
                   auto_merge: false,
                   interval_ms: 20,
                   initial_delay_ms: 0,
                   max_polls: 1_000
                 )
               )

      # Let the Watchdog poll a few times — it must NOT auto-merge.
      wait_until(fn -> StubMerger.get_count("!101") >= 3 end)
      assert Ash.get!(Issue, task.id).state == :merging
      assert StubMerger.merge_count("!101") == 0
    end

    test "without via_review_gate, the same scenario reproduces the silent hang", %{ws: ws} do
      # Regression characterization: with the flag absent and no GitHub-side
      # approval forthcoming, the PR stays open. The watchdog ceiling will
      # eventually escalate — see watchdog_test — but in the window before that
      # fires we can prove it does NOT auto-merge, which is exactly the bug the
      # via_review_gate flag closes.
      {pid, task} = running_worker(ws)
      StubMerger.next_open_ref("!100")

      assert {:ok, "!100"} =
               Worker.open_mr(
                 pid,
                 "feature/no-trib",
                 "Unapproved",
                 "",
                 open_opts(ws,
                   via_review_gate: false,
                   auto_merge: true,
                   interval_ms: 20,
                   initial_delay_ms: 0,
                   max_polls: 1_000
                 )
               )

      # Let the Watchdog poll a few times.
      wait_until(fn -> StubMerger.get_count("!100") >= 3 end)
      assert Ash.get!(Issue, task.id).state == :merging
      assert StubMerger.merge_count("!100") == 0
    end
  end

  describe "arb-done guard while waiting on the review gate" do
    test "a late 'arb done' does NOT complete a worker waiting on its ReviewGate", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "gated", workspace_id: ws.id})

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ws.id,
          meta: %{branch: "feature/g", review_required: true, review_spawn: false}
        )

      on_exit(fn -> stop_quietly(pid) end)
      :ok = Worker.advance(pid, :implement)
      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> Worker.state(pid).waiting_on == :review_gate end)

      # A second completion marker arriving while the review runs. The review
      # gate, not stdout, owns completion now.
      send(pid, {:__claude_session_done__, "arb done"})

      assert %{state: :waiting, waiting_on: :review_gate, outcome: nil} = Worker.state(pid)
    end
  end
end
