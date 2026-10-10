defmodule Arbiter.NodeAgent.K8s.AdmissionTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Admission

  defp facts(overrides \\ %{}) do
    Map.merge(%{max_concurrent: 2, running: 0, pending: 0, headroom: 5, draining?: false}, overrides)
  end

  test "room under the ceiling and in the quota is admitted" do
    assert :ok = Admission.decide(facts())
    assert :ok = Admission.decide(facts(%{running: 1}))
    assert :ok = Admission.decide(facts(%{headroom: :unbounded}))
  end

  test "running + pending at max_concurrent is refused" do
    assert {:refuse, :no_capacity, detail} = Admission.decide(facts(%{running: 2}))
    assert detail =~ "max_concurrent"
    assert {:refuse, :no_capacity, _} = Admission.decide(facts(%{running: 1, pending: 1}))
    assert {:refuse, :no_capacity, _} = Admission.decide(facts(%{pending: 2}))
  end

  test "no quota headroom is refused even with ceiling room" do
    assert {:refuse, :no_capacity, detail} = Admission.decide(facts(%{headroom: 0}))
    assert detail =~ "ResourceQuota"
  end

  test "a draining controller takes no new pods" do
    assert {:refuse, :no_capacity, detail} = Admission.decide(facts(%{draining?: true}))
    assert detail =~ "draining"
  end

  test "an unknown quota (the read failed) is not a licence to over-admit" do
    assert {:refuse, :no_capacity, detail} = Admission.decide(facts(%{headroom: :unknown}))
    assert detail =~ "ResourceQuota"
  end

  test "capacity/1 is the hb.capacity map" do
    assert Admission.capacity(facts(%{running: 1, pending: 1, headroom: 3})) == %{
             "ceiling" => 2,
             "running" => 1,
             "pending" => 1,
             "headroom" => 3,
             "constrained" => false
           }
  end

  test "constrained when a pod waits on the scheduler or the quota is exhausted" do
    assert %{"constrained" => true} =
             Admission.capacity(facts(%{pending: 1, unschedulable: 1}))

    assert %{"constrained" => true} = Admission.capacity(facts(%{headroom: 0}))
    assert %{"constrained" => false} = Admission.capacity(facts(%{pending: 1}))
  end

  test "an unbounded quota reports the remaining ceiling room as headroom" do
    assert %{"headroom" => 1} =
             Admission.capacity(facts(%{running: 1, headroom: :unbounded}))
  end

  test "headroom is never negative on the wire" do
    assert %{"headroom" => 0} = Admission.capacity(facts(%{headroom: :unknown}))
  end
end
