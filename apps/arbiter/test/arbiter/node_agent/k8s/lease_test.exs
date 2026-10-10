defmodule Arbiter.NodeAgent.K8s.LeaseTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Lease
  alias Arbiter.Test.FakeK8sApi

  @name "arbiter-controller"

  setup do
    env = FakeK8sApi.start!()
    FakeK8sApi.put_lease(env.api, base_lease())
    {:ok, env}
  end

  defp base_lease(spec \\ %{}) do
    %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => %{"name" => @name, "namespace" => "arb"},
      "spec" => Map.merge(%{"leaseDurationSeconds" => 30}, spec)
    }
  end

  # A clock the test moves by hand: no sleeping, no flakiness.
  defp clock!, do: start_supervised!({Agent, fn -> 0 end}, id: make_ref())
  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))
  defp read(clock), do: fn -> Agent.get(clock, & &1) end

  defp start!(client, identity, opts \\ []) do
    start_supervised!(
      {Lease,
       opts ++
         [
           client: client,
           name: nil,
           lease_name: @name,
           identity: identity,
           interval_ms: nil,
           lease_duration_ms: 60_000,
           renew_deadline_ms: 60_000,
           notify: self()
         ]},
      id: {Lease, identity}
    )
  end

  defp holder(api), do: FakeK8sApi.lease(api, @name)["spec"]["holderIdentity"]

  test "not held until the first cycle has won it", %{client: client} do
    lease = start!(client, "pod-a")
    refute Lease.held?(lease)
  end

  test "acquires a lease nobody holds and says so", %{api: api, client: client} do
    lease = start!(client, "pod-a")

    assert :held = Lease.tick(lease)
    assert Lease.held?(lease)
    assert holder(api) == "pod-a"
    assert_receive {:lease, ^lease, :acquired}

    spec = FakeK8sApi.lease(api, @name)["spec"]
    assert spec["leaseTransitions"] == 1
    assert is_binary(spec["renewTime"]) and is_binary(spec["acquireTime"])
    assert spec["leaseDurationSeconds"] == 60
  end

  test "renews while holding: renewTime moves, no new 'acquired'", %{api: api, client: client} do
    lease = start!(client, "pod-a")
    Lease.tick(lease)
    assert_receive {:lease, ^lease, :acquired}
    first = FakeK8sApi.lease(api, @name)["spec"]["renewTime"]

    assert :held = Lease.tick(lease)
    assert FakeK8sApi.lease(api, @name)["spec"]["renewTime"] != first
    assert FakeK8sApi.lease(api, @name)["spec"]["leaseTransitions"] == 1
    refute_received {:lease, _, _}
  end

  test "another controller's fresh lease is not ours to take", %{api: api, client: client} do
    FakeK8sApi.put_lease(
      api,
      base_lease(%{"holderIdentity" => "pod-b", "renewTime" => "2026-10-10T12:00:00.000000Z"})
    )

    lease = start!(client, "pod-a")
    assert :standby = Lease.tick(lease)
    refute Lease.held?(lease)
    assert holder(api) == "pod-b"
    refute_received {:lease, _, :acquired}
  end

  test "a holder that stops renewing is replaced once a lease duration has passed unchanged", %{
    api: api,
    client: client
  } do
    FakeK8sApi.put_lease(
      api,
      base_lease(%{"holderIdentity" => "pod-b", "renewTime" => "2026-10-10T12:00:00.000000Z"})
    )

    clock = clock!()
    lease = start!(client, "pod-a", lease_duration_ms: 30, clock: read(clock))
    assert :standby = Lease.tick(lease)
    advance(clock, 29)
    assert :standby = Lease.tick(lease)
    advance(clock, 1)

    assert :held = Lease.tick(lease)
    assert holder(api) == "pod-a"
    assert FakeK8sApi.lease(api, @name)["spec"]["leaseTransitions"] == 1
  end

  test "a holder that keeps renewing is never taken over", %{api: api, client: client} do
    clock = clock!()
    lease = start!(client, "pod-a", lease_duration_ms: 40, clock: read(clock))
    Lease.tick(lease)

    for n <- 1..4 do
      advance(clock, 15)

      FakeK8sApi.put_lease(
        api,
        base_lease(%{"holderIdentity" => "pod-b", "renewTime" => "t#{n}"})
      )

      assert :standby = Lease.tick(lease)
    end

    assert holder(api) == "pod-b"
  end

  test "losing the race (a conflict on renew) steps down at once", %{api: api, client: client} do
    lease = start!(client, "pod-a")
    Lease.tick(lease)
    assert_receive {:lease, ^lease, :acquired}

    # pod-b writes between our read and our write: simulated by taking it over
    # right before the next cycle reads, with a fresh resourceVersion each time.
    FakeK8sApi.put_lease(
      api,
      base_lease(%{"holderIdentity" => "pod-b", "renewTime" => "2026-10-10T13:00:00.000000Z"})
    )

    assert :standby = Lease.tick(lease)
    refute Lease.held?(lease)
    assert_receive {:lease, ^lease, :lost}
  end

  test "an API outage shorter than the renew deadline keeps the lease", %{
    api: api,
    client: client
  } do
    lease = start!(client, "pod-a", renew_deadline_ms: 60_000)
    Lease.tick(lease)
    assert_receive {:lease, ^lease, :acquired}

    FakeK8sApi.fail_next(api, :lease_get, 500, 3)
    assert :held = Lease.tick(lease)
    assert Lease.held?(lease)
    refute_received {:lease, _, :lost}
  end

  test "failing to renew past the deadline steps down, and recovers when the API does", %{
    api: api,
    client: client
  } do
    clock = clock!()
    lease = start!(client, "pod-a", renew_deadline_ms: 20, clock: read(clock))
    Lease.tick(lease)
    assert_receive {:lease, ^lease, :acquired}

    advance(clock, 40)
    refute Lease.held?(lease)
    FakeK8sApi.fail_next(api, :lease_update, 500, 1)
    assert :standby = Lease.tick(lease)
    refute Lease.held?(lease)
    assert_receive {:lease, ^lease, :lost}

    # The lease still names us; the next good cycle takes it back.
    assert :held = Lease.tick(lease)
    assert_receive {:lease, ^lease, :acquired}
  end

  test "an unreachable API never grants a lease we did not hold", %{api: api, client: client} do
    lease = start!(client, "pod-a")
    FakeK8sApi.fail_next(api, :lease_get, 500, 2)
    assert :standby = Lease.tick(lease)
    refute Lease.held?(lease)
  end

  test "a missing Lease object (install not applied) is standby, not a crash", %{client: client} do
    {:ok, other} = {:ok, %{client | namespace: "elsewhere"}}
    lease = start!(other, "pod-a")
    assert :standby = Lease.tick(lease)
    refute Lease.held?(lease)
  end

  test "stopping cleanly hands the lease back so a restart does not wait it out", %{
    api: api,
    client: client
  } do
    lease = start!(client, "pod-a")
    Lease.tick(lease)
    assert holder(api) == "pod-a"

    stop_supervised!({Lease, "pod-a"})
    assert holder(api) in [nil, ""]
  end

  test "polls on its own interval", %{client: client} do
    lease = start!(client, "pod-a", interval_ms: 10)
    assert_receive {:lease, ^lease, :acquired}, 2_000
  end
end
