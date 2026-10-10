defmodule Arbiter.Nodes.LivenessTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes.Liveness
  alias Arbiter.Settings
  alias Arbiter.Settings.Registry

  describe "defaults (design §10.1)" do
    test "10 s heartbeat, suspect at 30 s, fence at 60 s, lost at 90 s" do
      assert %Liveness{
               hb_interval_s: 10,
               suspect_after_s: 30,
               fence_after_s: 60,
               lost_after_s: 90
             } = Liveness.current()
    end

    test "the defaults satisfy the invariant fence < lost" do
      t = Liveness.current()
      assert t.fence_after_s < t.lost_after_s
      assert {:ok, ^t} = Liveness.validate(t)
    end

    # bd-4p1vui (§10.4.8): how long an agent keeps its runs with no socket (a primary
    # restart closes it): twice the measured 91 s deploy, above the 90 s fence ceiling.
    test "an agent with no socket keeps its runs for 180 s" do
      t = Liveness.current()
      assert t.restart_grace_s == 180
      assert t.restart_grace_s > t.lost_after_s
      assert Liveness.restart_grace_s() == 180
    end
  end

  describe "validate/1" do
    test "fence_after_s must be strictly below lost_after_s" do
      assert {:error, :fence_not_before_lost} = Liveness.validate(60, 60)
      assert {:error, :fence_not_before_lost} = Liveness.validate(60, 45)
      assert {:ok, %Liveness{fence_after_s: 60, lost_after_s: 61}} = Liveness.validate(60, 61)
    end

    test "fence_after_s is bounded to 30..90 (design §10.2)" do
      assert {:error, :fence_out_of_range} = Liveness.validate(29, 120)
      assert {:error, :fence_out_of_range} = Liveness.validate(91, 200)
      assert {:ok, _} = Liveness.validate(30, 60)
      assert {:ok, _} = Liveness.validate(90, 120)
    end

    test "lost_after_s defaults to fence_after_s + 30" do
      assert {:ok, %Liveness{fence_after_s: 45, lost_after_s: 75}} = Liveness.validate(45, nil)
    end

    test "suspect always lands before the fence, even at the minimum fence" do
      {:ok, t} = Liveness.validate(30, nil)
      assert t.hb_interval_s < t.suspect_after_s
      assert t.suspect_after_s < t.fence_after_s
    end
  end

  describe "classify/2" do
    setup do
      %{t: Liveness.current()}
    end

    test "online, suspect and lost by silence", %{t: t} do
      assert Liveness.classify(t, 0) == :online
      assert Liveness.classify(t, 29_999) == :online
      assert Liveness.classify(t, 30_000) == :suspect
      assert Liveness.classify(t, 89_999) == :suspect
      assert Liveness.classify(t, 90_000) == :lost
    end

    test "fenced?/2 flips at the fence, strictly before lost", %{t: t} do
      refute Liveness.fenced?(t, 59_999)
      assert Liveness.fenced?(t, 60_000)
      assert Liveness.classify(t, 60_000) == :suspect
    end
  end

  describe "the nodes.* settings enforce the invariant" do
    test "nodes.fence_after_s defaults to 60 and takes 30..90" do
      assert Registry.describe("nodes.fence_after_s").value == 60
      assert {:ok, 45} = Registry.put("nodes.fence_after_s", 45)
      assert Settings.nodes_fence_after_s() == 45
      assert Liveness.current().lost_after_s == 75
      assert {:error, {:invalid, _}} = Registry.put("nodes.fence_after_s", 29)
      assert {:error, {:invalid, _}} = Registry.put("nodes.fence_after_s", 91)
      assert {:ok, nil} = Registry.put("nodes.fence_after_s", nil)
    end

    test "nodes.lost_after_s must exceed the fence in force" do
      assert Registry.describe("nodes.lost_after_s").value == 90
      assert {:error, {:invalid, msg}} = Registry.put("nodes.lost_after_s", 60)
      assert msg =~ "fence"
      assert {:error, {:invalid, _}} = Registry.put("nodes.lost_after_s", 30)
      assert {:ok, 120} = Registry.put("nodes.lost_after_s", 120)
      assert Liveness.current().lost_after_s == 120
    end

    test "raising the fence to or past an explicit lost_after_s is refused" do
      assert {:ok, 70} = Registry.put("nodes.lost_after_s", 70)
      assert {:error, {:invalid, msg}} = Registry.put("nodes.fence_after_s", 70)
      assert msg =~ "lost"
      assert {:error, {:invalid, _}} = Registry.put("nodes.fence_after_s", 80)
      assert {:ok, 69} = Registry.put("nodes.fence_after_s", 69)
      assert Settings.nodes_fence_after_s() == 69
      assert Liveness.current().fence_after_s < Liveness.current().lost_after_s
    end

    test "clearing the fence is refused when the default 60 s would reach an explicit lost_after_s" do
      assert {:ok, 45} = Registry.put("nodes.fence_after_s", 45)
      assert {:ok, 55} = Registry.put("nodes.lost_after_s", 55)
      assert {:error, {:invalid, _}} = Registry.put("nodes.fence_after_s", nil)
      assert Settings.nodes_fence_after_s() == 45

      # Clearing the lost override is always safe: it falls back to fence + 30.
      assert {:ok, nil} = Registry.put("nodes.lost_after_s", nil)
      assert {:ok, nil} = Registry.put("nodes.fence_after_s", nil)
      assert Liveness.current().lost_after_s == 90
    end
  end
end
