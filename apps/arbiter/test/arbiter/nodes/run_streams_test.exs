defmodule Arbiter.Nodes.RunStreamsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.RunStreams, as: S

  @handle {:remote, :h1}

  defp table(waiter \\ {self(), make_ref()}),
    do: S.open(%S{}, "r1", @handle, self(), waiter)

  defp apply_effects(effects), do: Enum.reject(effects, &match?({:reply, _, _}, &1))

  defp data_msgs(effects), do: for({:send, _, {_, {:data, d}}} <- effects, do: d)

  test "ready answers the waiter with the handle, once" do
    {t, [{:reply, _from, {:ok, handle}}]} = S.ready(table(), "r1")
    assert handle == @handle
    assert {_, []} = S.ready(t, "r1")
  end

  test "refused answers the waiter with the reason and drops the stream" do
    {t, [{:reply, _, {:error, {:refused, "unschedulable", "memory"}}}]} =
      S.refused(table(), "r1", %{"reason" => "unschedulable", "detail" => "memory"})

    assert S.fetch(t, "r1") == :error
  end

  describe "stdout" do
    test "lines go to the owner in Port shape and the ack is cumulative" do
      {t, _} = S.ready(table(), "r1")
      {t, effects} = S.data(t, "r1", 0, "ab\ncd")
      assert data_msgs(effects) == [{:eol, "ab"}]
      # bd-4p1vui: the held partial "cd" is not acked yet (see the line-boundary tests)
      assert {:push, "ack", %{"run" => "r1", "offset" => 3}} in effects

      {_t, effects} = S.data(t, "r1", 5, "e\n")
      assert data_msgs(effects) == [{:eol, "cde"}]
      assert {:push, "ack", %{"run" => "r1", "offset" => 7}} in effects
    end

    test "a replay after a blip is dropped, re-acked, and never delivered twice" do
      {t, _} = S.ready(table(), "r1")
      {t, e1} = S.data(t, "r1", 0, "one\ntwo\n")
      assert data_msgs(e1) == [{:eol, "one"}, {:eol, "two"}]

      # the node never saw our ack and resends everything from 0
      {t, e2} = S.data(t, "r1", 0, "one\ntwo\n")
      assert data_msgs(e2) == []
      assert e2 == [{:push, "ack", %{"run" => "r1", "offset" => 8}}]

      # an overlapping resend delivers only the new tail
      {_t, e3} = S.data(t, "r1", 4, "two\nthree\n")
      assert data_msgs(e3) == [{:eol, "three"}]
    end

    test "a gap is ignored, so the node's last ack stays the replay point" do
      {t, _} = S.ready(table(), "r1")
      {_t, effects} = S.data(t, "r1", 10, "late\n")
      assert effects == []
    end
  end

  # bd-4p1vui (docs/design/remote-workers.md §10.4.5): the node's replay point is always the
  # start of a line, so a stream picked up by a new owner after a primary restart never
  # begins mid-line (the head of that line died with the old primary's partial buffer).
  describe "line-boundary acks" do
    test "the ack stops at the start of a held partial line, and a replay from it delivers that line once" do
      {t, _} = S.ready(table(), "r1")
      {t, e} = S.data(t, "r1", 0, "ab\ncd")
      assert data_msgs(e) == [{:eol, "ab"}]
      assert {:push, "ack", %{"run" => "r1", "offset" => 3}} in e

      # the node resends from the ack: the held "cd" is trimmed, not delivered twice
      {_t, e} = S.data(t, "r1", 3, "cde\n")
      assert data_msgs(e) == [{:eol, "cde"}]
      assert {:push, "ack", %{"run" => "r1", "offset" => 7}} in e
    end

    test "bytes that only extend the held partial line move no ack" do
      {t, _} = S.ready(table(), "r1")
      {t, _} = S.data(t, "r1", 0, "ab\ncd")
      {_t, e} = S.data(t, "r1", 5, "ef")
      assert data_msgs(e) == []
      assert {:push, "ack", %{"run" => "r1", "offset" => 3}} in e
    end

    test "a line cut at the port's 64 KiB limit is acked past the chunk it delivered" do
      {t, _} = S.ready(table(), "r1")
      {_t, e} = S.data(t, "r1", 0, String.duplicate("x", 65_536 + 10))
      assert [{:noeol, chunk}] = data_msgs(e)
      assert byte_size(chunk) == 65_536
      assert {:push, "ack", %{"run" => "r1", "offset" => 65_536}} in e
    end

    test "a replay wholly before the held line is re-acked at the line start" do
      {t, _} = S.ready(table(), "r1")
      {t, _} = S.data(t, "r1", 0, "ab\ncd")
      {_t, e} = S.data(t, "r1", 0, "ab\n")
      assert e == [{:push, "ack", %{"run" => "r1", "offset" => 3}}]
    end
  end

  # bd-4p1vui (§10.4.3): a run a node kept across a primary restart, taken over by a new owner.
  describe "adoption" do
    test "an adopted run resumes at the node's acked offset and its owner is answered on run.ready" do
      waiter = {self(), make_ref()}
      t = S.adopt(%S{}, "r1", @handle, self(), waiter, %{"arb" => "/new/arb.sock"}, 120)
      assert S.adopting?(t, "r1")
      assert S.bridge_target(t, "r1", "arb") == {:ok, "/new/arb.sock"}
      refute S.started?(t, "r1")

      {t, effects} = S.ready(t, "r1", %{"adopted" => true, "acked" => 120})
      # an adopted run's owner also learns where its stream starts
      assert effects == [{:reply, waiter, {:ok, @handle, 120}}]
      refute S.adopting?(t, "r1")
      assert S.started?(t, "r1")

      {_t, e} = S.data(t, "r1", 120, "next\n")
      assert data_msgs(e) == [{:eol, "next"}]
      assert {:push, "ack", %{"run" => "r1", "offset" => 125}} in e
    end

    test "an offset the old owner had already processed past the node's ack is not delivered again" do
      # the old Worker processed up to 130 (persisted at its graceful stop); the node's
      # last ack is 120, so its resend starts there
      t = S.adopt(%S{}, "r1", @handle, self(), nil, %{}, 130)
      {t, _} = S.ready(t, "r1", %{"acked" => 120})
      {_t, e} = S.data(t, "r1", 120, "processed\nnew\n")
      assert data_msgs(e) == [{:eol, "new"}]
      assert {:push, "ack", %{"run" => "r1", "offset" => 134}} in e
    end

    test "run.ready's acked offset wins over the one the run was adopted at" do
      t = S.adopt(%S{}, "r1", @handle, self(), nil, %{}, 100)
      {t, _} = S.ready(t, "r1", %{"acked" => 140})
      {_t, e} = S.data(t, "r1", 140, "x\n")
      assert data_msgs(e) == [{:eol, "x"}]
    end

    test "a plain run.ready (a reattach after a blip mid-handshake) keeps the adopted offset" do
      t = S.adopt(%S{}, "r1", @handle, self(), nil, %{}, 100)
      {t, _} = S.ready(t, "r1")
      {_t, e} = S.data(t, "r1", 100, "x\n")
      assert data_msgs(e) == [{:eol, "x"}]
    end

    test "an acked offset in run.ready does not move a run that was placed, not adopted" do
      {t, _} = S.ready(table(), "r1", %{"acked" => 50})
      {_t, e} = S.data(t, "r1", 0, "x\n")
      assert data_msgs(e) == [{:eol, "x"}]
    end
  end

  describe "exit" do
    test "the owner hears the outcome and exit_status only after every stdout byte" do
      owner = self()
      {t, _} = S.ready(table(), "r1")

      {t, e} =
        S.exit(t, "r1", %{"status" => 137, "oom" => true, "size" => 6, "cancelled" => false})

      assert e == []

      {t, e} = S.data(t, "r1", 0, "abc\n")
      refute Enum.any?(e, &match?({:send, _, {_, {:exit_status, _}}}, &1))

      {t, e} = S.data(t, "r1", 4, "de")

      assert [
               {:send, ^owner, {@handle, {:data, {:noeol, "de"}}}},
               {:send, ^owner,
                {@handle, {:outcome, %{oom?: true, exit_code: 137, cancelled?: false}}}},
               {:send, ^owner, {@handle, {:exit_status, 137}}}
             ] =
               e
               |> apply_effects()
               |> Enum.reject(&match?({:push, _, _}, &1))
               |> Enum.reject(&match?({:send, _, {_, {:data, {:eol, _}}}}, &1))

      assert {:push, "exit_ack", %{"run" => "r1"}} in e
      assert {:ok, %{oom?: true, exit_code: 137}} = S.outcome(t, "r1")
      assert S.live(t) == []
    end

    test "an exit whose bytes already arrived finishes at once; a repeated exit is just re-acked" do
      {t, _} = S.ready(table(), "r1")
      {t, _} = S.data(t, "r1", 0, "x\n")
      {t, e} = S.exit(t, "r1", %{"status" => 0, "oom" => false, "size" => 2})
      assert Enum.any?(e, &match?({:send, _, {_, {:exit_status, 0}}}, &1))
      {_t, e2} = S.exit(t, "r1", %{"status" => 0, "size" => 2})
      assert e2 == [{:push, "exit_ack", %{"run" => "r1"}}]
    end
  end

  describe "cancel and node loss" do
    test "cancel is pushed and re-pushed on every new connection until the run ends" do
      {t, _} = S.ready(table(), "r1")
      {t, e} = S.cancel(t, "r1", "operator")
      assert e == [{:push, "cancel", %{"run" => "r1", "reason" => "operator"}}]
      assert [{:push, "cancel", _}] = S.reattach(t)

      {t, _} = S.exit(t, "r1", %{"status" => 137, "size" => 0})
      assert S.reattach(t) == []
    end

    test "an abandoned run has no owner to send to, and its owner's death owns nothing" do
      owner = self()
      {t, _} = S.ready(table(), "r1")
      t = S.abandon(t, "r1")

      assert S.owned_by(t, owner) == []
      assert {:ok, %{owner: nil, cancel?: false}} = S.fetch(t, "r1")
    end

    test "a lost node ends every live run, flagged, so no worker waits forever" do
      owner = self()
      {t, _} = S.ready(table(), "r1")
      {t, e} = S.node_lost(t)

      assert Enum.any?(
               e,
               &match?(
                 {:send, ^owner, {@handle, {:outcome, %{node_lost?: true, exit_code: 255}}}},
                 &1
               )
             )

      assert {:send, owner, {@handle, {:exit_status, 255}}} in e
      assert S.live(t) == []
    end

    test "reconcile ends only the runs a reconnecting node no longer lists" do
      owner = self()
      t = S.open(%S{}, "keep", {:remote, :keep}, owner, nil)
      t = S.open(t, "gone", {:remote, :gone}, owner, nil)
      {t, _} = S.ready(t, "keep")
      {t, _} = S.ready(t, "gone")

      {t, e} = S.reconcile(t, ["keep"])
      assert {:send, owner, {{:remote, :gone}, {:exit_status, 255}}} in e
      refute Enum.any?(e, &match?({:send, _, {{:remote, :keep}, _}}, &1))
      assert S.live(t) == ["keep"]
    end

    test "a lost node fails a run that was still being prepared" do
      {_t, e} = S.node_lost(table())
      assert [{:reply, _, {:error, :node_lost}}] = e
    end
  end

  describe "A3: per-run stages" do
    test "a ready run counts as started (stage running)" do
      {t, _} = S.ready(table(), "r1")
      assert S.stage(t, "r1") == :running
      assert S.started?(t, "r1")
    end

    test "a run still waiting for the node is not started, whatever it reports short of running" do
      t = table()
      assert S.stage(t, "r1") == :assigned
      refute S.started?(t, "r1")

      for reported <- ["pending", "starting"] do
        t = S.report_stage(t, "r1", reported)
        assert S.stage(t, "r1") == String.to_existing_atom(reported)
        refute S.started?(t, "r1")
      end
    end

    test "terminating is recorded once running; an unknown word changes nothing" do
      {t, _} = S.ready(table(), "r1")
      assert S.stage(S.report_stage(t, "r1", "terminating"), "r1") == :terminating
      assert S.stage(S.report_stage(t, "r1", "bogus"), "r1") == :running
    end

    test "a late pending report cannot move a started run back" do
      {t, _} = S.ready(table(), "r1")
      assert S.stage(S.report_stage(t, "r1", "pending"), "r1") == :running
    end

    test "a node reporting running starts the run even if run.ready was lost" do
      {t, effects} = S.report_running(table(), "r1")
      assert [{:reply, _, {:ok, @handle}}] = effects
      assert S.started?(t, "r1")
    end

    test "an unknown run has no stage and is not started" do
      assert S.stage(%S{}, "nope") == nil
      refute S.started?(%S{}, "nope")
    end
  end

  describe "A3: refusals" do
    test "every refuse reason is passed through for the dispatch to hold on" do
      for reason <- ~w(no_capacity unschedulable image_unavailable bad_spec) do
        {_t, [{:reply, _, {:error, {:refused, ^reason, "why"}}}]} =
          S.refused(table(), "r1", %{"reason" => reason, "detail" => "why"})
      end
    end
  end

  describe "A4: opaque stdout cursors" do
    test "an opaque frame is delivered and acked with its own cursor, uninterpreted" do
      {t, _} = S.ready(table(), "r1")
      {t, e} = S.data_cursor(t, "r1", "2026-10-06T10:00:00.000000001Z", "ab\ncd")
      assert data_msgs(e) == [{:eol, "ab"}]

      assert {:push, "ack", %{"run" => "r1", "cursor" => "2026-10-06T10:00:00.000000001Z"}} in e

      {_t, e} = S.data_cursor(t, "r1", "2026-10-06T10:00:01.5Z", "e\n")
      assert data_msgs(e) == [{:eol, "cde"}]
      assert {:push, "ack", %{"run" => "r1", "cursor" => "2026-10-06T10:00:01.5Z"}} in e
    end

    test "an exit naming the final cursor finishes once that cursor has been delivered" do
      owner = self()
      {t, _} = S.ready(table(), "r1")
      {t, e} = S.exit(t, "r1", %{"status" => 0, "cursor" => "c2"})
      assert e == []

      {t, _} = S.data_cursor(t, "r1", "c1", "one\n")
      assert S.outcome(t, "r1") == :pending

      {t, e} = S.data_cursor(t, "r1", "c2", "two\n")
      assert {:send, owner, {@handle, {:exit_status, 0}}} in e
      assert {:push, "exit_ack", %{"run" => "r1"}} in e
      assert {:ok, %{exit_code: 0}} = S.outcome(t, "r1")
    end

    test "an exit that already matches the delivered cursor finishes at once" do
      {t, _} = S.ready(table(), "r1")
      {t, _} = S.data_cursor(t, "r1", "c1", "one\n")
      {_t, e} = S.exit(t, "r1", %{"status" => 0, "cursor" => "c1"})
      assert Enum.any?(e, &match?({:send, _, {_, {:exit_status, 0}}}, &1))
    end

    test "an integer-offset stream is untouched by the opaque path" do
      {t, _} = S.ready(table(), "r1")
      {_t, e} = S.data(t, "r1", 0, "ab\n")
      assert {:push, "ack", %{"run" => "r1", "offset" => 3}} in e
    end
  end

  describe "A5: pod_disrupted" do
    test "an exit flagged pod_disrupted carries the flag in the outcome" do
      {t, _} = S.ready(table(), "r1")
      {t, _} = S.exit(t, "r1", %{"status" => 137, "size" => 0, "pod_disrupted" => true})
      assert {:ok, %{pod_disrupted?: true, node_lost?: false}} = S.outcome(t, "r1")
    end

    test "an ordinary exit has no pod_disrupted key at all (machine outcome unchanged)" do
      {t, _} = S.ready(table(), "r1")
      {t, _} = S.exit(t, "r1", %{"status" => 1, "size" => 0})
      assert {:ok, outcome} = S.outcome(t, "r1")
      assert outcome |> Map.keys() |> Enum.sort() == [:cancelled?, :exit_code, :node_lost?, :oom?]
    end
  end

  describe "bd-bg87oz: checkout_failed" do
    test "an exit whose final checkout upload failed carries the flag in the outcome" do
      {t, _} = S.ready(table(), "r1")

      {t, _} =
        S.exit(t, "r1", %{"status" => 0, "size" => 0, "checkout" => "failed: {:error, :timeout}"})

      assert {:ok, %{checkout_failed?: true}} = S.outcome(t, "r1")
    end

    test "an exit whose checkout landed (or that had none) has no such key" do
      for checkout <- ["ok", nil] do
        {t, _} = S.ready(table(), "r1")
        exit = %{"status" => 0, "size" => 0} |> Map.put("checkout", checkout)
        {t, _} = S.exit(t, "r1", exit)
        assert {:ok, outcome} = S.outcome(t, "r1")
        refute Map.has_key?(outcome, :checkout_failed?)
      end
    end
  end
end
