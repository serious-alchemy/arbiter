defmodule Arbiter.Nodes.SessionTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Registry, Session}
  alias Arbiter.Workers.Run

  @version "1.2.3"

  @moduletag :tmp_dir

  # An outdated hello looks up the release to upgrade to (`Nodes.Agent`); keep
  # that off the operator's real `~/.arbiter`.
  setup %{tmp_dir: home} do
    # The skew verdict compares against the primary's version, which `git
    # describe` makes ambient (a tagless CI clone is 0.0.0): pin it.
    previous_version = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)

    on_exit(fn ->
      case previous_version do
        {:ok, v} -> Application.put_env(:arbiter, :node_primary_version, v)
        :error -> Application.delete_env(:arbiter, :node_primary_version)
      end
    end)

    previous = Application.fetch_env(:arbiter, :data_dir)
    Application.put_env(:arbiter, :data_dir, home)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :data_dir, v)
        :error -> Application.delete_env(:arbiter, :data_dir)
      end
    end)

    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)
    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    %{clock: clock, node: enroll!("session-node")}
  end

  defp enroll!(name) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)
    node
  end

  defp advance(clock, seconds), do: Agent.update(clock, &(&1 + seconds * 1000))

  defp hello(overrides \\ %{}) do
    Map.merge(
      %{
        "agent_version" => @version,
        "proto" => 1,
        "arch" => "x86_64",
        "caps" => %{"backend" => "podman"},
        "capacity" => %{"cpus" => 8, "mem_total" => 16_000_000_000, "suggestion" => 4},
        "runs" => []
      },
      overrides
    )
  end

  # `tick_ms: :infinity` — the test drives time (`advance/2` + `Session.tick/1`)
  # instead of waiting on a real timer.
  defp attach(node, clock, channel \\ self(), params \\ hello()) do
    Registry.attach(node, channel, params,
      clock: fn -> Agent.get(clock, & &1) end,
      tick_ms: :infinity
    )
  end

  defp kinds(node), do: node.id |> then(&Nodes.events(node_id: &1)) |> Enum.map(& &1.kind)

  describe "hello" do
    test "hello_ok carries the boot_epoch and the liveness settings", %{node: node, clock: c} do
      assert {:ok, %{hello_ok: ok}} = attach(node, c)
      assert ok["boot_epoch"] == Nodes.boot_epoch()
      assert is_binary(ok["boot_epoch"]) and ok["boot_epoch"] != ""
      assert ok["hb_interval"] == 10
      assert ok["fence_after"] == 60
      assert ok["lost_after"] == 90
      assert ok["health"] == "ready"
      assert ok["draining"] == false
    end

    test "the boot_epoch is stable within a BEAM and 128 bits of random" do
      assert Nodes.boot_epoch() == Nodes.boot_epoch()
      assert byte_size(Base.url_decode64!(Nodes.boot_epoch(), padding: false)) == 16
    end

    test "per-run verdicts: known only to a session that holds the run, else unknown (§10.4)",
         %{node: node, clock: c} do
      # A live worker_runs row is NOT enough: after a primary restart the row is still
      # live, but its Worker is gone, and the agent must quiesce the run, not reattach it.
      live = run!(:working)
      done = run!(:finished)
      {:ok, %{pid: pid}} = attach(node, c)
      held = Ash.UUID.generate()
      place!(pid, held)

      runs = [
        %{"id" => live.id, "state" => "running"},
        %{"id" => done.id, "state" => "running"},
        %{"id" => held, "state" => "running"},
        %{"id" => "not-a-uuid", "state" => "running"}
      ]

      assert {:ok, %{hello_ok: ok}} = attach(node, c, self(), hello(%{"runs" => runs}))

      assert ok["runs"] == %{
               live.id => "unknown",
               done.id => "unknown",
               held => "known",
               "not-a-uuid" => "unknown"
             }
    end

    test "a restarted primary (a fresh session) knows none of the agent's runs", %{
      node: node,
      clock: c
    } do
      live = run!(:working)
      runs = [%{"id" => live.id, "state" => "running"}]
      assert {:ok, %{hello_ok: ok}} = attach(node, c, self(), hello(%{"runs" => runs}))
      assert ok["runs"] == %{live.id => "unknown"}
    end

    test "records a connected event", %{node: node, clock: c} do
      {:ok, _} = attach(node, c)
      assert :connected in kinds(node)
    end

    test "the node's capacity ceiling and the operator's max_workers combine by min", %{clock: c} do
      {:ok, %{token: t}} =
        Nodes.mint_join_token([name: "capped", max_workers: 2], "operator:test")

      {:ok, %{node: capped}} = Nodes.redeem_join_token(t)

      # Neither ceiling: the node's suggestion.
      assert {:ok, %{hello_ok: %{"max_workers" => 4}}} = attach(enroll!("plain"), c)

      # Operator 2, node ceiling 3 -> 2; node ceiling 1 -> 1.
      with_ceiling = fn ceiling ->
        hello(%{"capacity" => %{"suggestion" => 4, "ceiling" => ceiling}})
      end

      assert {:ok, %{hello_ok: %{"max_workers" => 2}}} =
               attach(capped, c, self(), with_ceiling.(3))

      assert {:ok, %{hello_ok: %{"max_workers" => 1}}} =
               attach(capped, c, self(), with_ceiling.(1))
    end
  end

  describe "version skew" do
    test "an older agent is outdated: connected, not assignable, runs continue", %{
      node: node,
      clock: c
    } do
      {:ok, %{pid: pid}} = attach(node, c)
      live = Ash.UUID.generate()
      place!(pid, live)
      params = hello(%{"agent_version" => "0.0.1", "runs" => [%{"id" => live}]})
      assert {:ok, %{hello_ok: ok}} = attach(node, c, self(), params)
      assert ok["health"] == "outdated"
      assert ok["max_workers"] == 0
      assert ok["runs"][live] == "known"
      refute Registry.assignable?(node.id)
      assert %{health: :outdated, connected?: true} = Session.snapshot(node.id)
    end

    test "a proto below min_proto is incompatible", %{node: node, clock: c} do
      assert {:ok, %{hello_ok: %{"health" => "incompatible"}}} =
               attach(node, c, self(), hello(%{"proto" => 0}))

      refute Registry.assignable?(node.id)
    end

    test "a ready node is assignable", %{node: node, clock: c} do
      {:ok, _} = attach(node, c)
      assert Registry.assignable?(node.id)
    end
  end

  describe "heartbeat" do
    test "acks and keeps the node's per-run table", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)

      payload = %{
        "seq" => 7,
        "runs" => %{"r1" => %{"state" => "running", "stdout_seq" => 42}},
        "free_mem" => 123
      }

      assert {:ok, %{"seq" => 7, "boot_epoch" => epoch}} = Session.heartbeat(pid, payload)
      assert epoch == Nodes.boot_epoch()

      assert %{runs: %{"r1" => %{"state" => "running", "stdout_seq" => 42}}, free_mem: 123} =
               Session.snapshot(node.id)
    end

    test "a heartbeat from a node that is not attached is refused" do
      assert {:error, :no_session} = Session.heartbeat(Ash.UUID.generate(), %{"seq" => 1})
    end
  end

  describe "suspect -> fenced -> lost" do
    test "missed heartbeats move the node to suspect at 30 s and lost at 90 s", %{
      node: node,
      clock: c
    } do
      {:ok, %{pid: pid}} = attach(node, c)
      id = node.id
      ref = Process.monitor(pid)

      advance(c, 29)
      Session.tick(pid)
      assert %{state: :online} = Session.snapshot(id)
      refute_received {:node_state, ^id, :suspect}

      advance(c, 1)
      Session.tick(pid)
      assert %{state: :suspect} = Session.snapshot(id)
      assert_received {:node_state, ^id, :suspect}
      refute Registry.assignable?(id)

      advance(c, 29)
      Session.tick(pid)
      assert %{state: :suspect} = Session.snapshot(id)
      refute :fenced in kinds(node)

      advance(c, 1)
      Session.tick(pid)
      assert %{state: :suspect} = Session.snapshot(id)
      assert :fenced in kinds(node)
      refute :node_lost in kinds(node)

      advance(c, 30)
      Session.tick(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Registry.lookup(id) == nil
      assert :node_lost in kinds(node)
    end

    test "the fence is recorded once, strictly before lost", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)

      advance(c, 59)
      Session.tick(pid)
      refute :fenced in kinds(node)

      advance(c, 1)
      Session.tick(pid)
      assert :fenced in kinds(node)
      refute :node_lost in kinds(node)

      advance(c, 5)
      Session.tick(pid)
      assert Enum.count(kinds(node), &(&1 == :fenced)) == 1
    end

    test "a heartbeat clears suspect", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      id = node.id
      advance(c, 45)
      Session.tick(pid)
      assert %{state: :suspect} = Session.snapshot(id)

      assert {:ok, _} = Session.heartbeat(pid, %{"seq" => 1})
      assert %{state: :online} = Session.snapshot(id)
      assert_received {:node_state, ^id, :online}
      assert Registry.assignable?(id)
    end

    test "the thresholds come from the nodes.* settings", %{node: node, clock: c} do
      {:ok, _} = Arbiter.Settings.Registry.put("nodes.fence_after_s", 40)
      {:ok, %{pid: pid, hello_ok: ok}} = attach(node, c)
      assert ok["fence_after"] == 40 and ok["lost_after"] == 70

      advance(c, 69)
      Session.tick(pid)
      assert Registry.lookup(node.id) == pid
      advance(c, 1)
      Session.tick(pid)
      assert Registry.lookup(node.id) == nil
    end

    test "lost tells the runs' owners and the channel, and does not fail the runs", %{
      node: node,
      clock: c
    } do
      live = run!(:working)
      id = node.id
      {:ok, %{pid: pid}} = attach(node, c, self(), hello(%{"runs" => [%{"id" => live.id}]}))

      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 1, "runs" => %{live.id => %{"state" => "running"}}})

      advance(c, 90)
      Session.tick(pid)

      assert_receive {:node_lost, ^id, run_ids}
      assert run_ids == [live.id]
      assert_receive {:node_session, {:disconnect, :lost}}
      [event] = Nodes.events(node_id: id, kind: :node_lost)
      assert event.detail["runs"] == [live.id]
      assert Ash.get!(Run, live.id).state == :working
    end
  end

  describe "channel blips" do
    test "a dropped channel keeps the session; a reconnect before lost resumes it", %{
      node: node,
      clock: c
    } do
      channel = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: pid}} = attach(node, c, channel)

      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 1, "runs" => %{"r1" => %{"state" => "running"}}})

      Process.exit(channel, :kill)
      id = node.id
      assert_receive {:node_connection, ^id, :down}
      refute Session.snapshot(id).connected?
      assert :disconnected in kinds(node)

      advance(c, 20)
      Session.tick(pid)
      assert Registry.lookup(node.id) == pid

      assert {:ok, %{pid: ^pid, hello_ok: ok}} = attach(node, c)
      assert ok["boot_epoch"] == Nodes.boot_epoch()
      assert %{connected?: true, state: :online} = Session.snapshot(node.id)
    end

    test "a node that stays away is lost even with no channel", %{node: node, clock: c} do
      channel = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: pid}} = attach(node, c, channel)
      ref = Process.monitor(pid)
      Process.exit(channel, :kill)
      id = node.id
      assert_receive {:node_connection, ^id, :down}

      advance(c, 90)
      Session.tick(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert :node_lost in kinds(node)
    end

    test "a second connection supersedes the first, which is told to go", %{node: node, clock: c} do
      first = forwarding_channel()
      {:ok, %{pid: pid}} = attach(node, c, first)
      assert {:ok, %{pid: ^pid}} = attach(node, c, self())
      assert_receive {:forwarded, {:node_session, {:disconnect, :superseded}}}
    end
  end

  describe "drain" do
    test "stops new assignments without disturbing live runs", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)

      {:ok, _} =
        Session.heartbeat(pid, %{"seq" => 1, "runs" => %{"r1" => %{"state" => "running"}}})

      assert Registry.assignable?(node.id)

      assert {:ok, drained} = Nodes.drain(node, "operator:test")
      assert drained.status == :draining
      assert_receive {:node_session, :drain}
      refute_received {:node_session, {:cancel, _}}
      refute_received {:node_session, {:disconnect, _}}

      refute Registry.assignable?(node.id)
      assert %{draining?: true, state: :online, runs: %{"r1" => _}} = Session.snapshot(node.id)
      assert Registry.lookup(node.id) == pid
      assert :drained in kinds(node)
    end

    test "undrain makes a ready node assignable again", %{node: node, clock: c} do
      {:ok, _} = attach(node, c)
      {:ok, _} = Nodes.drain(node, "operator:test")
      assert {:ok, %{status: :active}} = Nodes.undrain(node, "operator:test")
      assert Registry.assignable?(node.id)

      assert [%{detail: %{"drain" => false}}, %{detail: %{"drain" => true}}] =
               Nodes.events(node_id: node.id, kind: :drained) |> Enum.reverse()
    end

    test "a drain persists: a node that reconnects is still draining", %{node: node, clock: c} do
      {:ok, _} = Nodes.drain(node, "operator:test")
      assert {:ok, %{hello_ok: ok}} = attach(node, c)
      assert ok["draining"] == true
      assert ok["max_workers"] == 0
      refute Registry.assignable?(node.id)
    end

    test "a revoked node cannot be drained", %{node: node} do
      {:ok, revoked} = Nodes.revoke(node, "operator:test")
      assert {:error, :revoked} = Nodes.drain(revoked, "operator:test")
    end
  end

  describe "revoke" do
    test "disconnects a live session at once", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      ref = Process.monitor(pid)
      id = node.id

      {:ok, _} = Nodes.revoke(node, "operator:test")

      assert_receive {:node_session, {:disconnect, :revoked}}
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Registry.lookup(id) == nil
      assert_receive {:node_revoked, ^id}
    end

    test "falls back to the session stopping itself on its next heartbeat", %{
      node: node,
      clock: c
    } do
      {:ok, %{pid: pid}} = attach(node, c)
      ref = Process.monitor(pid)
      # Revoked behind the session's back: no notification is sent.
      {:ok, _} = Ash.update(node, %{}, action: :revoke)

      assert {:error, :revoked} = Session.heartbeat(pid, %{"seq" => 1})
      assert_receive {:node_session, {:disconnect, :revoked}}
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    test "a revoked node cannot attach", %{node: node, clock: c} do
      {:ok, _} = Nodes.revoke(node, "operator:test")
      assert {:error, :revoked} = attach(node, c)
    end
  end

  describe "checkout context (RW11)" do
    setup %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      ctx = %{home: "/h", branch: "arbiter/b", base: "main", seeded_paths: []}

      owner = self()

      task =
        Task.async(fn ->
          Session.assign(pid, "run1", %{"run" => "run1"}, owner, checkout: ctx)
        end)

      assert_receive {:node_session, {:push, "assign", %{"run" => "run1"}}}
      Session.node_event(pid, "run.ready", %{"run" => "run1"})
      assert {:ok, _handle} = Task.await(task)
      %{pid: pid, ctx: ctx}
    end

    test "a run's checkout context is served only for a run placed with one", %{
      pid: pid,
      ctx: ctx
    } do
      assert {:ok, ^ctx} = Session.checkout_context(pid, "run1")
      assert :error = Session.checkout_context(pid, "other")
    end

    test "collect pushes `collect` to the node and returns the ingest result", %{pid: pid} do
      waiter = Task.async(fn -> Session.collect(pid, "run1", :checkout, 5_000) end)
      assert_receive {:node_session, {:push, "collect", %{"run" => "run1", "kind" => "checkout"}}}
      Session.checkout_done(pid, "run1", {:ok, %{head: "abc"}})
      assert {:ok, %{head: "abc"}} = Task.await(waiter)
    end

    test "a collect for a run that is gone is an error, and releasing the run answers waiters", %{
      pid: pid
    } do
      assert {:error, :unknown_run} = Session.collect(pid, "nope", :checkout, 1_000)

      waiter = Task.async(fn -> Session.collect(pid, "run1", :checkout, 5_000) end)
      assert_receive {:node_session, {:push, "collect", _}}
      Session.release_run(pid, "run1")
      assert {:error, :run_gone} = Task.await(waiter)
      assert :error = Session.checkout_context(pid, "run1")
    end

    test "a rejected ingest is recorded as a checkout_rejected event", %{pid: pid, node: node} do
      Session.checkout_done(pid, "run1", {:error, {:veto, :submodule, "vendor/dep"}})
      _ = Session.snapshot(pid)
      assert :checkout_rejected in kinds(node)
    end
  end

  describe "restart recovery (RW12)" do
    @ctx %{home: "/h", branch: "arbiter/b", base: "main", seeded_paths: [], config_dir: "/c"}

    defp retained_report(run),
      do: %{"run" => run, "task" => "bd-1", "checkout" => %{"bytes" => 1}, "transcripts" => nil}

    test "a hello lists what the agent retained, and the snapshot shows it", %{
      node: node,
      clock: c
    } do
      params = hello(%{"inventory" => %{"runs" => [], "retained" => [retained_report("r1")]}})
      assert {:ok, %{pid: pid}} = attach(node, c, self(), params)
      assert %{retained: %{"r1" => %{"run" => "r1"}}} = Session.snapshot(pid)
    end

    test "a retained push is stored and recorded as an event", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      Session.node_event(pid, "retained", retained_report("r1"))
      assert %{retained: %{"r1" => _}} = Session.snapshot(pid)
      assert :retained in kinds(node)
    end

    test "recover asks a retained run's node for it and returns what the uploads say", %{
      node: node,
      clock: c
    } do
      {:ok, %{pid: pid}} = attach(node, c)
      Session.node_event(pid, "retained", retained_report("r1"))

      waiter = Task.async(fn -> Session.recover(pid, "r1", @ctx, 5_000) end)
      assert_receive {:node_session, {:push, "recover", %{"run" => "r1"}}}

      # the upload endpoints are authorized for the recovery, and only for it
      assert {:ok, @ctx} = Session.checkout_context(pid, "r1")
      assert :error = Session.checkout_context(pid, "other")

      Session.checkout_done(pid, "r1", {:ok, %{head: "abc"}})

      Session.node_event(pid, "recovered", %{
        "run" => "r1",
        "transcripts" => "none",
        "checkout" => "ok"
      })

      assert {:ok, %{checkout: %{head: "abc"}, agent: %{"checkout" => "ok"}}} = Task.await(waiter)
      assert :error = Session.checkout_context(pid, "r1")
      assert :recovered in kinds(node)
    end

    test "a failed upload is an error, and the recovery context is withdrawn", %{
      node: node,
      clock: c
    } do
      {:ok, %{pid: pid}} = attach(node, c)
      Session.node_event(pid, "retained", retained_report("r1"))
      waiter = Task.async(fn -> Session.recover(pid, "r1", @ctx, 5_000) end)
      assert_receive {:node_session, {:push, "recover", _}}
      Session.checkout_done(pid, "r1", {:error, {:veto, :submodule, "x"}})

      Session.node_event(pid, "recovered", %{
        "run" => "r1",
        "transcripts" => "none",
        "checkout" => "failed: {:rejected, 422, %{}}"
      })

      assert {:error, {:recovery_failed, _}} = Task.await(waiter)
      assert :error = Session.checkout_context(pid, "r1")
    end

    test "a run the node neither holds nor retained is not on the node", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      assert {:error, :not_on_node} = Session.recover(pid, "ghost", @ctx, 1_000)
    end

    test "a run the agent is still quiescing is asked for once it reports retained", %{
      node: node,
      clock: c
    } do
      params = hello(%{"runs" => [%{"id" => "r1", "state" => "running"}]})
      {:ok, %{pid: pid}} = attach(node, c, self(), params)

      waiter = Task.async(fn -> Session.recover(pid, "r1", @ctx, 5_000) end)
      _ = Session.snapshot(pid)
      refute_received {:node_session, {:push, "recover", _}}

      Session.node_event(pid, "retained", retained_report("r1"))
      assert_receive {:node_session, {:push, "recover", %{"run" => "r1"}}}

      Session.node_event(pid, "recovered", %{
        "run" => "r1",
        "transcripts" => "none",
        "checkout" => "none"
      })

      assert {:ok, _} = Task.await(waiter)
    end

    test "recover_abort withdraws a recovery that ran out of budget", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      Session.node_event(pid, "retained", retained_report("r1"))
      waiter = Task.async(fn -> Session.recover(pid, "r1", @ctx, 100) end)
      assert {:error, :timeout} = Task.await(waiter)
      assert :error = Session.checkout_context(pid, "r1")
    end

    test "a recovered run can be dropped on the node", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      Session.node_event(pid, "retained", retained_report("r1"))
      assert :ok = Session.drop_retained(pid, "r1")
      assert_receive {:node_session, {:push, "retained.drop", %{"run" => "r1"}}}
      assert %{retained: retained} = Session.snapshot(pid)
      refute Map.has_key?(retained, "r1")
    end
  end

  describe "reaping (RW12)" do
    setup do
      previous = Application.fetch_env(:arbiter, :node_reaper)
      Application.put_env(:arbiter, :node_reaper, enabled: true, primary?: fn -> true end)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, :node_reaper, v)
          :error -> Application.delete_env(:arbiter, :node_reaper)
        end
      end)
    end

    test "every hello is answered with a reap carrying the install and the live set", %{
      node: node,
      clock: c
    } do
      live = run!(:working)
      _done = run!(:finished)
      {:ok, _} = attach(node, c)

      assert_receive {:node_session, {:push, "reap", %{"install" => install, "live_set" => set}}}
      assert install == Arbiter.Nodes.InstallId.get()
      assert live.id in set
      assert length(set) == 1
    end

    test "the live set also holds runs the session itself placed", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      assert_receive {:node_session, {:push, "reap", _}}
      placed = Ash.UUID.generate()
      place!(pid, placed)
      Session.reap_now(pid)
      assert_receive {:node_session, {:push, "reap", %{"live_set" => set}}}
      assert placed in set
    end

    test "a second instance (not the primary) never reaps", %{node: node, clock: c} do
      Application.put_env(:arbiter, :node_reaper, enabled: true, primary?: fn -> false end)
      {:ok, %{pid: pid}} = attach(node, c)
      Session.reap_now(pid)
      _ = Session.snapshot(pid)
      refute_received {:node_session, {:push, "reap", _}}
    end

    test "reap/2 sends an explicit live set, install-scoped; disabled when not the primary", %{
      node: node,
      clock: c
    } do
      {:ok, %{pid: pid}} = attach(node, c)
      assert_receive {:node_session, {:push, "reap", _}}

      assert :ok = Session.reap(pid, ["a", "b", "a"])
      assert_receive {:node_session, {:push, "reap", %{"install" => i, "live_set" => ["a", "b"]}}}
      assert i == Arbiter.Nodes.InstallId.get()

      Application.put_env(:arbiter, :node_reaper, enabled: true, primary?: fn -> false end)
      assert {:error, :disabled} = Session.reap(pid, ["a"])
    end

    test "a reaped report is recorded", %{node: node, clock: c} do
      {:ok, %{pid: pid}} = attach(node, c)
      Session.node_event(pid, "reaped", %{"containers" => ["arb-x"], "pods" => [], "dirs" => []})
      _ = Session.snapshot(pid)
      assert :reaped in kinds(node)
    end
  end

  # Place `run` on the session as a Worker would, and mark it running.
  defp place!(pid, run, opts \\ []) do
    owner = self()

    task =
      Task.async(fn ->
        Session.assign(pid, run, %{"run" => run}, owner, opts)
      end)

    assert_receive {:node_session, {:push, "assign", %{"run" => ^run}}}
    Session.node_event(pid, "run.ready", %{"run" => run})
    assert {:ok, handle} = Task.await(task)
    handle
  end

  defp run!(state) do
    Ash.create!(Run, %{
      task_id: "bd-node-test",
      base_task_id: "bd-node-test",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: state,
      started_at: DateTime.utc_now()
    })
  end

  defp forwarding_channel do
    parent = self()

    spawn(fn ->
      receive_loop = fn loop ->
        receive do
          msg ->
            send(parent, {:forwarded, msg})
            loop.(loop)
        end
      end

      receive_loop.(receive_loop)
    end)
  end
end
