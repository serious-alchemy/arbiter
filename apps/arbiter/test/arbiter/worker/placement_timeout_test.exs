defmodule Arbiter.Worker.PlacementTimeoutTest do
  @moduledoc """
  bd-cch1jh: a remote placement attempt always ends. The controller is a stub that
  accepts the `assign` and never answers; the primary's `Session` is real, with its own
  watchdogs left far out of reach, so what ends the attempt is
  `Arbiter.Nodes.PlacementWatch`'s deadline over the whole of
  `ClaudeSession.port_args/6` (the one path every placed run takes: a fresh implement
  run, a conflict pass, a fix pass, a session resume).

  The failure comes back as `{:remote_placement_failed, {:placement_timeout, stage, ms}}`,
  which `Dispatch` falls back to the primary on (`remote_only` holds it instead), the node
  is told to drop the run, and the start and the outcome are both in the log.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{PlacementWatch, Registry, Session}
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.CliSetFixture
  alias Arbiter.Worker.PrivateClone

  @timeout_ms 2_000
  @sid "6f1e0c52-3c7a-4a55-9d0e-6b1c1f6a2b10"

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    put_app_env(:arbiter, :node_placement,
      placement_timeout_ms: @timeout_ms,
      # the Session's own watchdogs are out of reach: only the primary's deadline can end it
      ack_timeout_ms: 3_600_000,
      pending_timeout_ms: 3_600_000
    )

    put_app_env(:arbiter, :worker_container_available, true)
    put_app_env(:arbiter, :worker_container_network_available, true)
    put_app_env(:arbiter, :worker_container_image, nil)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = PrivateClone.create(ctx.checkout, "feature/bd-cch1jh", "main")

    dir = Path.join(ctx.root, "scratch")
    File.mkdir_p!(dir)
    proxy = Path.join(dir, "proxy.sock")
    bridge = Path.join(dir, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")
    cli_opts = CliSetFixture.put(Path.join(dir, "cli"))
    tmp_dir = Path.join(dir, "run-tmp")
    File.mkdir_p!(tmp_dir)

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: 41_001, bridges: [{41_002, bridge}]], "rtest"}
    end

    {:ok, %{token: token}} = Nodes.mint_join_token([name: "mesaana"], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)

    hello = %{
      "agent_version" => "1.2.3",
      "proto" => 1,
      "kind" => "cluster",
      "caps" => %{"backend" => "k8s", "limits" => "pod"},
      "capacity" => %{"ceiling" => 6},
      "runs" => []
    }

    put_app_env(:arbiter, :node_primary_version, "1.2.3")
    {:ok, %{pid: session}} = Registry.attach(node, self(), hello, tick_ms: :infinity)
    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())

    opts =
      [
        security:
          SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}}),
        node: node,
        image: "localhost/arb-test/claude:1",
        podman: "/usr/bin/podman",
        egress: egress,
        arb_token: "arb-secret-token"
      ] ++ cli_opts

    %{
      clone: clone,
      opts: opts,
      session: session,
      node: node,
      ctx: [owner: self(), task_id: "bd-cch1jh-run", tmp_dir: tmp_dir],
      egress: egress
    }
  end

  defp argv(extra), do: ["claude", "--print"] ++ extra ++ ["the prompt"]

  defp place(ctx, argv, opts \\ [], run_ctx \\ []) do
    ClaudeSession.port_args(
      Keyword.merge(ctx.opts, opts),
      "/bin/sh",
      argv,
      ctx.clone,
      [],
      Keyword.merge(ctx.ctx, run_ctx)
    )
  end

  # Every run kind takes this path. A resume differs in its argv (and, when a transcript
  # is held, a seeded session); a conflict pass in its task and branch.
  for {kind, extra} <- [
        {"a fresh run", []},
        {"a conflict pass", ["--append-system-prompt", "resolve the conflicts"]},
        {"a session resume", ["--resume", @sid]}
      ] do
    test "#{kind}: a controller that never replies fails over at the placement timeout", ctx do
      log =
        capture_log(fn ->
          assert {:error, {:remote_placement_failed, {:placement_timeout, :assign, @timeout_ms}}} =
                   place(ctx, argv(unquote(extra)))
        end)

      # the controller was asked, and was then told to drop the run
      assert_receive {:node_session, {:push, "assign", %{"run" => run}}}, 10_000
      assert_receive {:node_session, {:push, "cancel", %{"run" => ^run, "reason" => reason}}}
      assert reason == "placement_timeout"

      # the session lets go of the run: a retry is not refused as already placed
      assert Session.run_stage(ctx.session, run) == nil

      # logged: the start and the outcome, with the task and the node
      assert log =~ "placement started task=bd-cch1jh-run node=mesaana"
      assert log =~ "placement timed out task=bd-cch1jh-run node=mesaana run=#{run}"
      assert log =~ "stage=assign"
      assert [] = Enum.filter(PlacementWatch.in_flight(), &(&1.task_id == "bd-cch1jh-run"))
    end
  end

  test "the node is ranked last for a while after a placement it never answered", ctx do
    place(ctx, argv([]))
    assert_receive {:node_session, {:push, "assign", %{"run" => _run}}}
    assert_receive {:node_session, {:push, "cancel", _}}

    assert %{placement_stalled?: true} = Session.snapshot(ctx.session)
  end

  test "a primary-side step that never returns is ended by the same deadline", ctx do
    hang = fn _opts -> Process.sleep(:infinity) end

    log =
      capture_log(fn ->
        assert {:error, {:remote_placement_failed, {:placement_timeout, :prepare, @timeout_ms}}} =
                 place(ctx, argv([]), egress: hang)
      end)

    # nothing was ever sent to the node
    refute_received {:node_session, {:push, "assign", _}}
    assert log =~ "placement timed out task=bd-cch1jh-run node=mesaana"
    assert log =~ "stage=prepare"
    assert [] = Enum.filter(PlacementWatch.in_flight(), &(&1.task_id == "bd-cch1jh-run"))
  end

  test "a stall between steps (the owner never answers first_open_args) also times out", ctx do
    # a silent owner: it is neither this process nor answering `first_spawn_args`
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(owner, :kill) end)

    started = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        assert {:error,
                {:remote_placement_failed, {:placement_timeout, :first_open, @timeout_ms}}} =
                 place(ctx, argv([]), [], owner: owner, run_id: Ecto.UUID.generate())
      end)

    # within the deadline plus a small grace, and nothing was sent to the node
    assert System.monotonic_time(:millisecond) - started < @timeout_ms + 1_500
    refute_received {:node_session, {:push, "assign", _}}
    assert log =~ "placement timed out task=bd-cch1jh-run node=mesaana"
    assert log =~ "stage=first_open"
    assert [] = Enum.filter(PlacementWatch.in_flight(), &(&1.task_id == "bd-cch1jh-run"))
  end

  test "a node that answers with a refusal is logged with its reason", ctx do
    test = self()
    put_app_env(:arbiter, :node_placement, placement_timeout_ms: 60_000)

    task =
      Task.async(fn ->
        log =
          capture_log(fn ->
            assert {:error, {:remote_placement_failed, {:refused, "unschedulable", "no room"}}} =
                     place(ctx, argv([]), [], owner: self())
          end)

        send(test, {:log, log})
      end)

    assert_receive {:node_session, {:push, "assign", %{"run" => run}}}, 10_000

    Session.node_event(ctx.session, "run.refused", %{
      "run" => run,
      "reason" => "unschedulable",
      "detail" => "no room"
    })

    Task.await(task)

    assert_receive {:log, log}, 5_000
    assert log =~ "placement started task=bd-cch1jh-run node=mesaana"
    assert log =~ "placement refused task=bd-cch1jh-run node=mesaana"
    assert log =~ "reason=unschedulable"
    refute log =~ "timed out"
  end
end
