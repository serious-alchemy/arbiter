defmodule Arbiter.Worker.ResearchTranscriptsDispatchTest do
  @moduledoc """
  bd-1fkwj9: `Dispatch.dispatch/2` of a `research_read` research ticket hands the
  grant's transcript snapshot to the spawn. `research_agent_opts/2` fed only the
  adapter's argv, never the session opts, so `ClaudeSession` never saw
  `:research_transcripts` and a local podman run mounted no snapshot at all (and the
  remote refusal that was meant for a node run was dead code).

  Drives the real dispatch to the `podman run` argv (the `podman` binary and egress
  run are stand-ins). A run without the permission gets no mount.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.{Dispatch, OutputLog}
  alias Arbiter.Workers.Run

  @repo ResumeSlotFixture.repo()
  @marker "LOCAL-TRANSCRIPT-MARKER-5530"

  setup do
    sandbox = ResumeSlotFixture.setup_repo!()
    Application.put_env(:arbiter, :conductor_system_max_concurrent, 10)

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_deps_cache: false,
          output_log_root: Path.join(sandbox.worktree_root, "logs")
        ] do
      previous = Application.fetch_env(:arbiter, key)
      Application.put_env(:arbiter, key, value)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, key, v)
          :error -> Application.delete_env(:arbiter, key)
        end
      end)
    end

    dir = Path.join(sandbox.worktree_root, "research-stand-in")
    File.mkdir_p!(dir)
    proxy = Path.join(dir, "proxy.sock")
    bridge = Path.join(dir, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    log = Path.join(dir, "podman.log")
    podman = Path.join(dir, "podman")

    File.write!(podman, """
    #!/bin/sh
    { printf 'CALL\\0'; for a in "$@"; do printf '%s\\0' "$a"; done; printf 'END\\0'; } >> #{log}
    exit 0
    """)

    File.chmod!(podman, 0o755)
    ports = [free_port(), free_port()]

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: hd(ports), bridges: [{List.last(ports), bridge}]],
       "rtest"}
    end

    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rtd-#{n}",
        prefix: "rt#{n}",
        config: %{"guardrails" => %{"bindings" => %{"research_read" => %{}}}}
      })

    opts = [
      repo: @repo,
      start_driver: false,
      preflight: false,
      start_claude: true,
      force: true,
      security: %{"sandbox" => %{"backend" => "podman"}},
      image: "localhost/arb-test/claude:1",
      podman: podman,
      egress: egress
    ]

    %{ws: ws, opts: opts, log: log}
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp research!(ws, permissions) do
    Ash.create!(
      Issue,
      %{
        title: "study arbiter",
        workspace_id: ws.id,
        issue_type: :research,
        acceptance: "- findings",
        permissions: permissions
      },
      context: %{guardrail_authority: :coordinator, permission_actor: "t"}
    )
  end

  defp past_run!(ws) do
    earlier = Ash.create!(Issue, %{title: "earlier", workspace_id: ws.id, issue_type: :task})

    run =
      Ash.create!(Run, %{
        task_id: earlier.id,
        workspace_id: ws.id,
        repo: @repo,
        started_at: DateTime.utc_now()
      })

    File.mkdir_p!(OutputLog.root())
    File.write!(OutputLog.path_for(run.id), "#{@marker}\n")
    run
  end

  # The argv of the `podman run` the dispatch made, NUL-split.
  defp run_argv(log) do
    log
    |> File.read!()
    |> String.split("CALL\0", trim: true)
    |> Enum.map(&String.split(&1, <<0>>, trim: true))
    |> Enum.find(&("run" in &1))
  end

  defp dispatch_and_stop(task, opts) do
    assert {:ok, %{claude_port: port}} = Dispatch.dispatch(task.id, opts)
    ref = Port.monitor(port)
    assert_receive {:DOWN, ^ref, :port, ^port, _}, 5_000

    case Worker.whereis(task.id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Worker.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  test "a granted research run's podman spawn mounts the workspace's snapshot read-only",
       %{ws: ws, opts: opts, log: log} do
    past_run!(ws)
    task = research!(ws, ["research_read"])

    dispatch_and_stop(task, opts)

    argv = run_argv(log)

    # Bound read-only (`-v dir:dir:ro`), inside the run's tmp dir, and announced.
    mount = Enum.find(argv, &(&1 =~ "research-transcripts"))
    assert mount, "no research-transcripts mount in the podman run argv"
    assert String.ends_with?(mount, ":ro")
    assert "ARBITER_TRANSCRIPTS_DIR" in argv
  end

  test "a research run without the permission gets no snapshot", %{ws: ws, opts: opts, log: log} do
    past_run!(ws)
    task = research!(ws, [])

    dispatch_and_stop(task, opts)

    refute Enum.any?(run_argv(log), &(&1 =~ "research-transcripts"))
  end
end
