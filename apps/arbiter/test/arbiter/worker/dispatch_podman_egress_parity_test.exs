defmodule Arbiter.Worker.DispatchPodmanEgressParityTest do
  @moduledoc """
  bd-dh1gg1: a podman run reaches the forge through the egress proxy, the
  git-over-SSH `ProxyCommand` and the `/run/arbiter` bridge. A run opened by a
  briefing resume, a session resume or the Reconciler's auto-resume must be
  given exactly the container a fresh dispatch gets.

  Drives the real entry points (`Dispatch.dispatch/2`, `Dispatch.resume_task/2`,
  `Reconciler.default_resume/2`) all the way to the `podman run` argv. The egress
  run and the `podman` binary are stand-ins (`:egress` / `:podman` spawn options):
  the stub logs the argv it was given and exits.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Reconciler
  alias Arbiter.Workers.Run

  @repo ResumeSlotFixture.repo()
  @session "ead93203-0505-4188-8e74-125d64ac68dc"

  setup do
    sandbox = ResumeSlotFixture.setup_repo!()

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_deps_cache: false
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

    dir = Path.join(sandbox.worktree_root, "egress-stand-in")
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

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "egress-parity-#{System.unique_integer([:positive])}",
        prefix: "ep#{System.unique_integer([:positive])}"
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

    %{ws: ws, opts: opts, log: log, proxy: proxy, bridge: bridge}
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  # Every `podman run` the stub was given so far, as arg lists.
  defp run_calls(log) do
    case File.read(log) do
      {:ok, raw} ->
        raw
        |> String.split(<<0>>)
        |> Enum.chunk_while(
          nil,
          fn
            "CALL", _ -> {:cont, []}
            "END", acc when is_list(acc) -> {:cont, Enum.reverse(acc), nil}
            arg, acc when is_list(acc) -> {:cont, [arg | acc]}
            _, nil -> {:cont, nil}
          end,
          fn _ -> {:cont, nil} end
        )
        |> Enum.filter(&match?(["run" | _], &1))

      {:error, _} ->
        []
    end
  end

  # The first container the path opened: spawned, logged, with the log reset for
  # the next path. Only its head (before the inner command) and tail are kept.
  defp opened(log, task_id) do
    wait_until(fn -> run_calls(log) != [] end)
    [argv | _] = run_calls(log)
    File.rm!(log)
    stop_worker(task_id)
    split_argv(argv)
  end

  defp split_argv(argv) do
    {head, ["--" | command]} = Enum.split_while(argv, &(&1 != "--"))
    %{head: head, command: command}
  end

  defp stop_worker(task_id) do
    case Worker.whereis(task_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Worker.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met within timeout")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # What the container is given to reach the outside, with the per-run values
  # (the container name and the run's temp dir) dropped.
  defp egress_part(%{head: head}, ctx) do
    name = for ["--name", n] <- Enum.chunk_every(head, 2, 1), do: n
    head = Enum.map(head, &Regex.replace(~r{worker-tmp-test/[^/:]+}, &1, "worker-tmp-test/RUN"))

    %{
      head: Enum.reject(head, &(&1 in name)),
      mounts:
        Enum.filter(
          for(["-v", spec] <- Enum.chunk_every(head, 2, 1), do: spec),
          &(&1 =~ ctx.proxy or &1 =~ ctx.bridge)
        ),
      git_ssh_env: Enum.filter(head, &(&1 =~ "GIT_SSH_COMMAND")),
      network: for(arg <- head, String.starts_with?(arg, "--network"), do: arg)
    }
  end

  defp seed_prior_session!(task, ws, config_dir) do
    File.mkdir_p!(Path.join([config_dir, "projects", "-old-slug"]))
    File.write!(Path.join([config_dir, "projects", "-old-slug", @session <> ".jsonl"]), "{}\n")

    {:ok, _} =
      Ash.create(Run, %{
        task_id: task.id,
        task_title: "t",
        repo: @repo,
        state: :finished,
        outcome: :failed,
        started_at: DateTime.utc_now(),
        session_id: @session,
        config_dir: config_dir,
        provider: "claude"
      })

    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: task.id,
        workspace_id: ws.id,
        repo: @repo,
        step: :work,
        provider: "claude",
        session_id: @session,
        occurred_at: DateTime.utc_now()
      })
  end

  test "dispatch, briefing resume, session resume and auto-resume open the same egress",
       %{ws: ws, opts: opts, log: log} = ctx do
    {:ok, task} =
      Ash.create(Issue, %{title: "podman parity", workspace_id: ws.id, acceptance: "- parity"})

    assert {:ok, _} = Dispatch.dispatch(task.id, opts)
    fresh = opened(log, task.id)
    expected = egress_part(fresh, ctx)

    assert expected.git_ssh_env != []
    assert "--network=none" in expected.head
    assert expected.mounts != []

    seed_prior_session!(task, ws, Path.join(ctx.proxy |> Path.dirname(), "prior-config"))

    assert {:ok, _} = Dispatch.resume_task(task.id, [resume_mode: :briefing] ++ opts)
    briefing = opened(log, task.id)

    assert {:ok, _} = Dispatch.resume_task(task.id, [resume_mode: :session] ++ opts)
    session = opened(log, task.id)

    assert {:ok, _} = Reconciler.default_resume(Ash.get!(Issue, task.id), opts)
    auto = opened(log, task.id)

    # The session resume really continued the session; the others did not.
    assert @session in session.command
    refute @session in briefing.command
    refute @session in fresh.command

    for {path, run} <- [briefing: briefing, session: session, auto_resume: auto] do
      got = egress_part(run, ctx)

      assert got == expected,
             "#{path} diverged from a fresh dispatch's egress setup"
    end

    # A host-pushed run is told so on the briefing path too (dispatch.ex sets
    # `host_pushes?` for every podman spawn).
    assert Enum.join(briefing.command, " ") =~ "NO PUSH ACCESS"
  end

  test "a resumed podman run on a ticket with a PR is told Arbiter pushes, not to push",
       %{ws: ws, opts: opts, log: log} do
    {:ok, task} =
      Ash.create(Issue, %{title: "podman pr resume", workspace_id: ws.id, acceptance: "- pr"})

    assert {:ok, _} = Dispatch.dispatch(task.id, opts)
    _ = opened(log, task.id)
    {:ok, %Issue{state: :merging}} = Issue.pr_opened(task.id, "https://example.test/pull/7")

    assert {:ok, _} = Dispatch.resume_task(task.id, [resume_mode: :briefing] ++ opts)
    %{command: command} = opened(log, task.id)
    prompt = Enum.join(command, " ")

    assert prompt =~ "Arbiter pushes it; do NOT push"
    refute prompt =~ "push commits to the existing branch"
  end
end
