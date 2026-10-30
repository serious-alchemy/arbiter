defmodule Arbiter.Nodes.SessionClusterTest do
  @moduledoc """
  K12 (bd-4x1usg, `docs/design/remote-workers.md` §16 amendments A3-A5, A7): what the
  primary's `Nodes.Session` does with a cluster node's `kind`, `degraded`, `capacity`,
  per-run stages, refusals, opaque stdout cursors and `pod_disrupted` exits — and that a
  machine node sees none of it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Registry, Session, StdoutFrame}

  @version "1.2.3"

  setup do
    previous = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :node_primary_version, v)
        :error -> Application.delete_env(:arbiter, :node_primary_version)
      end
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    {:ok, %{token: token}} = Nodes.mint_join_token([name: "k12-node"], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)
    %{node: node}
  end

  defp hello(overrides \\ %{}) do
    Map.merge(
      %{
        "agent_version" => @version,
        "proto" => 1,
        "caps" => %{"backend" => "podman"},
        "capacity" => %{"suggestion" => 4},
        "runs" => []
      },
      overrides
    )
  end

  defp cluster_hello(overrides \\ %{}) do
    hello(
      Map.merge(
        %{
          "kind" => "cluster",
          "k8s_version" => "v1.31.2+k3s1",
          "caps" => %{"backend" => "k8s", "image" => "registry", "limits" => "pod"},
          "capacity" => %{"ceiling" => 6}
        },
        overrides
      )
    )
  end

  defp attach(node, params, opts \\ []) do
    Registry.attach(node, self(), params, Keyword.merge([tick_ms: :infinity], opts))
  end

  # Assign `run` and leave it un-ready; returns the waiting task.
  defp assign(pid, run, opts \\ []) do
    owner = self()

    task =
      Task.async(fn -> Session.assign(pid, run, %{"run" => run}, owner, opts) end)

    assert_receive {:node_session, {:push, "assign", %{"run" => ^run}}}
    task
  end

  describe "hello: kind, degraded, version (A7)" do
    test "a cluster hello is recorded in the snapshot", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello(%{"degraded" => "netpol_unenforced"}))

      assert %{kind: "cluster", k8s_version: "v1.31.2+k3s1", degraded: ["netpol_unenforced"]} =
               Session.snapshot(pid)
    end

    test "degraded may be a list; an absent one is empty", %{node: node} do
      {:ok, %{pid: pid}} =
        attach(node, cluster_hello(%{"degraded" => ["netpol_unenforced", "x"]}))

      assert %{degraded: ["netpol_unenforced", "x"]} = Session.snapshot(pid)

      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      assert %{degraded: []} = Session.snapshot(pid)
    end

    test "a machine hello is a machine: no kind sent means machine, nothing degraded", %{
      node: node
    } do
      {:ok, %{pid: pid, hello_ok: ok}} = attach(node, hello())

      assert %{kind: "machine", k8s_version: nil, degraded: [], node_capacity: nil} =
               Session.snapshot(pid)

      refute Map.has_key?(ok, "limits")
    end

    test "a heartbeat can raise or clear degraded; one that is silent on it changes nothing", %{
      node: node
    } do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 1, "degraded" => ["netpol_unenforced"]})
      assert %{degraded: ["netpol_unenforced"]} = Session.snapshot(pid)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 2, "degraded" => []})
      assert %{degraded: []} = Session.snapshot(pid)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 3, "degraded" => "netpol_unenforced"})
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 4})
      assert %{degraded: ["netpol_unenforced"]} = Session.snapshot(pid)
    end
  end

  describe "readiness (K13)" do
    @checks [
      %{
        "id" => "netpol",
        "name" => "NetworkPolicy enforcement",
        "status" => "ok",
        "detail" => "enforced",
        "hint" => nil
      },
      %{"id" => "quota", "name" => "ResourceQuota", "status" => "warn", "detail" => "none"}
    ]

    test "a cluster hello's readiness checks land in the snapshot", %{node: node} do
      {:ok, %{pid: pid}} =
        attach(node, cluster_hello(%{"readiness" => %{"ready" => true, "checks" => @checks}}))

      assert %{readiness: [%{"id" => "netpol", "status" => "ok"}, %{"id" => "quota"}]} =
               Session.snapshot(pid)
    end

    test "a heartbeat replaces them; one that is silent leaves them", %{node: node} do
      {:ok, %{pid: pid}} =
        attach(node, cluster_hello(%{"readiness" => %{"checks" => @checks}}))

      bad = [%{"id" => "netpol", "name" => "n", "status" => "fail", "detail" => "x"}]
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 1, "readiness" => %{"checks" => bad}})
      assert %{readiness: [%{"status" => "fail"}]} = Session.snapshot(pid)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 2})
      assert %{readiness: [%{"status" => "fail"}]} = Session.snapshot(pid)
    end

    test "only well-formed, bounded checks are kept", %{node: node} do
      junk = [
        "nope",
        %{"id" => "ok", "name" => "n", "status" => "bogus", "detail" => "d"},
        %{
          "id" => "fine",
          "name" => "n",
          "status" => "warn",
          "detail" => String.duplicate("x", 5_000)
        }
      ]

      {:ok, %{pid: pid}} =
        attach(node, cluster_hello(%{"readiness" => %{"checks" => junk}}))

      assert %{readiness: [%{"id" => "fine", "detail" => detail}]} = Session.snapshot(pid)
      assert String.length(detail) <= 600
    end

    test "a machine node's readiness is not recorded here", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, hello(%{"readiness" => %{"checks" => @checks}}))
      assert %{readiness: []} = Session.snapshot(pid)
    end

    test "a cluster hello without readiness has none", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      assert %{readiness: []} = Session.snapshot(pid)
    end

    # K14: the controller pushes each canary verdict as `readiness`; the node need not wait
    # for its next heartbeat to be placed on (or taken off placement).
    test "a readiness push replaces degraded and the checks at once", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello(%{"degraded" => ["netpol_unenforced"]}))

      Session.node_event(pid, "readiness", %{
        "degraded" => [],
        "readiness" => %{"ready" => true, "checks" => @checks}
      })

      assert %{degraded: [], readiness: [%{"id" => "netpol", "status" => "ok"} | _]} =
               Session.snapshot(pid)

      Session.node_event(pid, "readiness", %{"degraded" => ["netpol_unenforced"]})
      assert %{degraded: ["netpol_unenforced"], readiness: [_, _]} = Session.snapshot(pid)
    end

    test "a machine's readiness push changes nothing", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, hello())
      Session.node_event(pid, "readiness", %{"degraded" => ["netpol_unenforced"]})
      assert %{degraded: [], readiness: []} = Session.snapshot(pid)
    end
  end

  describe "capacity (A3)" do
    @capacity %{
      "ceiling" => 6,
      "running" => 2,
      "pending" => 1,
      "headroom" => 0,
      "constrained" => true
    }

    test "hb.capacity is kept in the snapshot", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 1, "capacity" => @capacity})
      assert %{node_capacity: @capacity} = Session.snapshot(pid)
    end

    test "a capacity event replaces it and is broadcast", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      Session.node_event(pid, "capacity", Map.put(@capacity, "constrained", false))
      assert %{node_capacity: %{"constrained" => false, "pending" => 1}} = Session.snapshot(pid)
      assert_receive {:node_capacity, id, %{"constrained" => false}}
      assert id == node.id
    end

    test "a capacity event's ceiling lowers the node's effective cap", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      assert %{max_workers: 6} = Session.snapshot(pid)
      Session.node_event(pid, "capacity", Map.put(@capacity, "ceiling", 3))
      assert %{max_workers: 3} = Session.snapshot(pid)
    end

    test "garbage in a capacity event is ignored", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      Session.node_event(pid, "capacity", "nope")
      assert %{node_capacity: nil} = Session.snapshot(pid)
    end
  end

  describe "hello_ok.limits.prepare_timeout_s (A3)" do
    test "a cluster node is told the prepare budget", %{node: node} do
      {:ok, %{hello_ok: ok}} = attach(node, cluster_hello(), prepare_timeout_ms: 90_000)
      assert ok["limits"] == %{"prepare_timeout_s" => 90}
    end

    test "the default budget is the session's long-standing 25 minutes", %{node: node} do
      {:ok, %{hello_ok: ok}} = attach(node, cluster_hello())
      assert ok["limits"] == %{"prepare_timeout_s" => 1500}
    end
  end

  describe "stages and the startup watchdog (A3, K17)" do
    test "a pending run is not started; it counts as started only at running", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      task = assign(pid, "r1")
      assert Session.run_stage(pid, "r1") == :assigned
      refute Session.run_started?(pid, "r1")

      for word <- ~w(pending starting) do
        {:ok, _} =
          Session.heartbeat(pid, %{"seq" => 1, "runs" => %{"r1" => %{"state" => word}}})

        assert Session.run_stage(pid, "r1") == String.to_existing_atom(word)
        refute Session.run_started?(pid, "r1")
      end

      # The node says running: the assign is answered, even without a run.ready.
      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 2, "runs" => %{"r1" => %{"state" => "running"}}})

      assert {:ok, {:remote, _}} = Task.await(task)
      assert Session.run_started?(pid, "r1")
    end

    test "while pending, only the prepare watchdog is armed: no output, no exit, no stall",
         %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      task = assign(pid, "r1", prepare_timeout_ms: 60_000)

      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 1, "runs" => %{"r1" => %{"state" => "pending"}}})

      # Several ticks of silence from the run do nothing to it: not cancelled, nothing sent
      # to its owner, still waiting for the node.
      for _ <- 1..3, do: Session.tick(pid)
      refute_receive {:node_session, {:push, "cancel", _}}, 50
      refute_received {{:remote, _}, _}
      assert Session.run_stage(pid, "r1") == :pending
      refute Session.run_started?(pid, "r1")

      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      assert {:ok, _} = Task.await(task)
      assert Session.run_started?(pid, "r1")
    end

    test "the prepare budget is what bounds a run that never starts", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      task = assign(pid, "r1", prepare_timeout_ms: 80)

      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 1, "runs" => %{"r1" => %{"state" => "pending"}}})

      assert {:error, :prepare_timeout} = Task.await(task)

      assert_receive {:node_session,
                      {:push, "cancel", %{"run" => "r1", "reason" => "prepare_timeout"}}}
    end

    test "once running, the prepare watchdog no longer touches the run", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      task = assign(pid, "r1", prepare_timeout_ms: 80)
      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      assert {:ok, _} = Task.await(task)

      refute_receive {:node_session, {:push, "cancel", _}}, 200
      assert Session.run_live?(pid, "r1")
    end
  end

  # bd-bmecet: a placement that never reaches a live pod is failed over as a hold, not left to
  # hang "placing". The stubbed controller here is the test itself, pushing nothing (it dropped
  # the request) or a pending report (the scheduler cannot place the pod).
  describe "placement watchdogs (bd-bmecet)" do
    @ack_ms 120_000
    @pending_ms 300_000

    # A session on a clock the test advances.
    defp attach_timed(node, params) do
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      now = fn -> Agent.get(clock, & &1) end
      advance = fn ms -> Agent.update(clock, &(&1 + ms)) end

      {:ok, %{pid: pid}} =
        attach(node, params,
          clock: now,
          ack_timeout_ms: @ack_ms,
          pending_timeout_ms: @pending_ms,
          stalled_cooldown_ms: 60_000
        )

      {pid, advance}
    end

    test "a controller that drops the request: held as unacknowledged, and the node cancelled",
         %{node: node} do
      {pid, advance} = attach_timed(node, cluster_hello())
      task = assign(pid, "r1")

      # nothing from the node, but heartbeats keep it alive
      advance.(@ack_ms - 10_000)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 1, "runs" => %{}})
      Session.tick(pid)
      refute_receive {:node_session, {:push, "cancel", _}}, 20

      advance.(10_000)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 2, "runs" => %{}})
      Session.tick(pid)

      assert {:error, {:refused, "unacknowledged", detail}} = Task.await(task)
      assert detail =~ "did not acknowledge"
      assert detail =~ "120s"

      assert_receive {:node_session,
                      {:push, "cancel", %{"run" => "r1", "reason" => "placement_timeout"}}}

      assert Session.run_stage(pid, "r1") == nil
      assert %{placement_stalled?: true} = Session.snapshot(pid)
    end

    test "the held reason maps through Refusal to a hold naming the cause", %{node: node} do
      {pid, advance} = attach_timed(node, cluster_hello())
      task = assign(pid, "r1")
      advance.(@ack_ms)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 1, "runs" => %{}})
      Session.tick(pid)

      {:error, placement_error} = Task.await(task)

      assert {:ok, %{reason: "unacknowledged", detail: detail}} =
               Arbiter.Nodes.Refusal.from_start_error(
                 {:claude_start_failed, {:remote_placement_failed, placement_error}}
               )

      assert detail =~ "controller"
    end

    test "a pod stuck Pending: held as unschedulable with the scheduler's message", %{node: node} do
      {pid, advance} = attach_timed(node, cluster_hello())
      task = assign(pid, "r1")

      message = "0/3 nodes are available: 3 Insufficient cpu."

      pending = %{
        "r1" => %{"state" => "pending", "reason" => "unschedulable", "message" => message}
      }

      {:ok, _} = Session.heartbeat(pid, %{"seq" => 1, "runs" => pending})
      assert Session.run_stage(pid, "r1") == :pending

      # past the ack budget, but the node did acknowledge: not a lost request
      advance.(@ack_ms + 1_000)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 2, "runs" => pending})
      Session.tick(pid)
      assert Session.run_stage(pid, "r1") == :pending

      advance.(@pending_ms)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 3, "runs" => pending})
      Session.tick(pid)

      assert {:error, {:refused, "unschedulable", detail}} = Task.await(task)
      assert detail =~ "Pending"
      assert detail =~ message

      assert_receive {:node_session,
                      {:push, "cancel", %{"run" => "r1", "reason" => "placement_timeout"}}}
    end

    test "a run that starts in time is left alone", %{node: node} do
      {pid, advance} = attach_timed(node, cluster_hello())
      task = assign(pid, "r1")

      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 1, "runs" => %{"r1" => %{"state" => "starting"}}})

      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      assert {:ok, _} = Task.await(task)

      advance.(@pending_ms * 2)

      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 2, "runs" => %{"r1" => %{"state" => "running"}}})

      Session.tick(pid)

      refute_receive {:node_session, {:push, "cancel", _}}, 50
      assert Session.run_live?(pid, "r1")
      assert %{placement_stalled?: false} = Session.snapshot(pid)
    end

    test "a controller that reconnects without the run (a restart) is held at once", %{
      node: node
    } do
      {pid, _advance} = attach_timed(node, cluster_hello())
      task = assign(pid, "r1")

      {:ok, %{pid: ^pid}} = Registry.attach(node, self(), cluster_hello(), tick_ms: :infinity)

      assert {:error, {:refused, "placement_lost", detail}} = Task.await(task)
      assert detail =~ "restarted"
    end

    test "a pod that dies while seeding refuses the placement at once, not after the prepare budget",
         %{node: node} do
      {pid, _advance} = attach_timed(node, cluster_hello())
      task = assign(pid, "r1")

      Session.node_event(pid, "exit", %{
        "run" => "r1",
        "reason" => "init_failed",
        "status" => 75,
        "detail" => "arbiter seed: the session transcript was not served (status 404)",
        "size" => 0
      })

      assert {:error, {:refused, "startup_failed", detail}} = Task.await(task, 1_000)
      assert detail =~ "init_failed"
      assert detail =~ "session transcript was not served"
      assert_receive {:node_session, {:push, "exit_ack", %{"run" => "r1"}}}
      refute Session.run_live?(pid, "r1")
    end

    test "a machine node is not subject to the cluster watchdogs", %{node: node} do
      {pid, advance} = attach_timed(node, hello())
      task = assign(pid, "r1")

      advance.(@pending_ms * 2)
      {:ok, _} = Session.heartbeat(pid, %{"seq" => 1})
      Session.tick(pid)

      refute_receive {:node_session, {:push, "cancel", _}}, 50
      assert Session.run_stage(pid, "r1") == :assigned
      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      assert {:ok, _} = Task.await(task)
    end
  end

  describe "machine nodes are unchanged (no regression)" do
    test "a machine hb naming a phase 'running' does not answer or re-stage a pending assign",
         %{node: node} do
      {:ok, %{pid: pid}} = attach(node, hello())
      task = assign(pid, "r1", prepare_timeout_ms: 60_000)

      {:ok, _} =
        Session.heartbeat(pid, %{
          "seq" => 1,
          "degraded" => ["netpol_unenforced"],
          "capacity" => %{"constrained" => true},
          "runs" => %{"r1" => %{"state" => "running"}}
        })

      # only the node's own run.ready starts a machine run
      assert Session.run_stage(pid, "r1") == :assigned
      refute Session.run_started?(pid, "r1")
      assert %{kind: "machine", degraded: []} = Session.snapshot(pid)

      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      assert {:ok, _} = Task.await(task)
      assert Session.run_started?(pid, "r1")
    end

    test "an ordinary exit and int-offset stdout behave exactly as before", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, hello())
      task = assign(pid, "r1")
      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      {:ok, handle} = Task.await(task)

      Session.node_event(pid, "stdout", {:binary, StdoutFrame.encode("r1", 0, "hi\n")})
      assert_receive {^handle, {:data, {:eol, "hi"}}}
      assert_receive {:node_session, {:push, "ack", %{"run" => "r1", "offset" => 3}}}

      Session.node_event(pid, "exit", %{"run" => "r1", "status" => 0, "size" => 3})
      assert_receive {^handle, {:outcome, outcome}}
      assert outcome == %{oom?: false, exit_code: 0, cancelled?: false, node_lost?: false}
    end
  end

  describe "refusals (A3)" do
    for reason <- ~w(no_capacity unschedulable image_unavailable bad_spec service_not_ready) do
      test "refuse{#{reason}} answers the assign with the reason", %{node: node} do
        {:ok, %{pid: pid}} = attach(node, cluster_hello())
        task = assign(pid, "r1")

        Session.node_event(pid, "run.refused", %{
          "run" => "r1",
          "reason" => unquote(reason),
          "detail" => "d"
        })

        assert {:error, {:refused, unquote(reason), "d"}} = Task.await(task)
        refute Session.run_live?(pid, "r1")
      end
    end
  end

  describe "opaque stdout cursor (A4)" do
    test "an ARB2 frame reaches the owner and is acked with its cursor", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      task = assign(pid, "r1")
      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      {:ok, handle} = Task.await(task)

      frame = StdoutFrame.encode_cursor("r1", "2026-10-06T10:00:00.1Z", "hi\n")
      Session.node_event(pid, "stdout", {:binary, frame})

      assert_receive {^handle, {:data, {:eol, "hi"}}}

      assert_receive {:node_session,
                      {:push, "ack", %{"run" => "r1", "cursor" => "2026-10-06T10:00:00.1Z"}}}
    end
  end

  describe "hello_ok.stdout_cursors (K15)" do
    test "a blip's hello_ok names the last cursor taken for each run", %{node: node} do
      {:ok, %{pid: pid, hello_ok: first}} = attach(node, cluster_hello())
      refute Map.has_key?(first, "stdout_cursors")

      task = assign(pid, "r1")
      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      {:ok, _handle} = Task.await(task)

      frame = StdoutFrame.encode_cursor("r1", "2026-10-06T10:00:00.1Z 1", "hi\n")
      Session.node_event(pid, "stdout", {:binary, frame})

      hello = cluster_hello(%{"runs" => [%{"id" => "r1"}]})
      {:ok, %{hello_ok: ok}} = attach(node, hello)
      assert ok["runs"] == %{"r1" => "known"}
      assert ok["stdout_cursors"] == %{"r1" => "2026-10-06T10:00:00.1Z 1"}
    end
  end

  describe "pod_disrupted (A5)" do
    test "an exit flagged pod_disrupted tells the owner so", %{node: node} do
      {:ok, %{pid: pid}} = attach(node, cluster_hello())
      task = assign(pid, "r1")
      Session.node_event(pid, "run.ready", %{"run" => "r1"})
      {:ok, handle} = Task.await(task)

      Session.node_event(pid, "exit", %{
        "run" => "r1",
        "status" => 137,
        "size" => 0,
        "pod_disrupted" => true
      })

      assert_receive {^handle, {:outcome, %{pod_disrupted?: true, node_lost?: false}}}
    end
  end
end
