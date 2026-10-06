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
      assert {:push, "ack", %{"run" => "r1", "offset" => 5}} in effects

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
end
