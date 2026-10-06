defmodule Arbiter.Nodes.SessionTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Registry, Session}
  alias Arbiter.Workers.Run

  @version Arbiter.Version.app_version()

  @moduletag :tmp_dir

  # An outdated hello looks up the release to upgrade to (`Nodes.Agent`); keep
  # that off the operator's real `~/.arbiter`.
  setup %{tmp_dir: home} do
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

    test "per-run verdicts: known to the primary, or unknown", %{node: node, clock: c} do
      live = run!(:working)
      done = run!(:finished)

      runs = [
        %{"id" => live.id, "state" => "running"},
        %{"id" => done.id, "state" => "running"},
        %{"id" => Ash.UUID.generate(), "state" => "running"},
        %{"id" => "not-a-uuid", "state" => "running"}
      ]

      assert {:ok, %{hello_ok: ok}} = attach(node, c, self(), hello(%{"runs" => runs}))

      assert ok["runs"] == %{
               live.id => "known",
               done.id => "unknown",
               Enum.at(runs, 2)["id"] => "unknown",
               "not-a-uuid" => "unknown"
             }
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
      live = run!(:working)
      params = hello(%{"agent_version" => "0.0.1", "runs" => [%{"id" => live.id}]})
      assert {:ok, %{hello_ok: ok}} = attach(node, c, self(), params)
      assert ok["health"] == "outdated"
      assert ok["max_workers"] == 0
      assert ok["runs"][live.id] == "known"
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
