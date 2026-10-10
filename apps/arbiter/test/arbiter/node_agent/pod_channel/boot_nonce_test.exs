defmodule Arbiter.NodeAgent.PodChannel.BootNonceTest do
  @moduledoc """
  The `/boot` nonce (`docs/design/remote-workers.md` §16 K§12): 256 bits,
  single-use, expiring at `boot_s`, and bound to the pod's IP and the run.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PodChannel.BootNonce

  @ip {10, 42, 0, 61}

  defp new(ttl_ms \\ 120_000) do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000)
    state = BootNonce.new(ttl_ms: ttl_ms, clock: fn -> :atomics.get(clock, 1) end)
    {state, fn ms -> :atomics.add(clock, 1, ms) end}
  end

  test "a nonce is 256 bits of fresh randomness" do
    {state, _} = new()
    {a, state} = BootNonce.issue(state, "run-1")
    {b, _state} = BootNonce.issue(state, "run-2")

    assert a != b
    assert byte_size(Base.url_decode64!(a, padding: false)) == 32
  end

  test "a bound nonce redeems once, for its run, from the pod's IP" do
    {state, _} = new()
    {nonce, state} = BootNonce.issue(state, "run-1")
    state = BootNonce.bind(state, "run-1", @ip)

    assert {{:ok, "run-1"}, state} = BootNonce.redeem(state, nonce, @ip)
    assert {{:error, :unknown}, _} = BootNonce.redeem(state, nonce, @ip)
  end

  test "a nonce from another address is refused and is spent" do
    {state, _} = new()
    {nonce, state} = BootNonce.issue(state, "run-1")
    state = BootNonce.bind(state, "run-1", @ip)

    assert {{:error, :wrong_ip}, state} = BootNonce.redeem(state, nonce, {10, 42, 0, 99})
    # a leaked nonce used from the wrong place burns it: the real pod fails closed
    assert {{:error, :unknown}, _} = BootNonce.redeem(state, nonce, @ip)
  end

  test "a nonce is not redeemable before the pod's IP is known, and is not spent by trying" do
    {state, _} = new()
    {nonce, state} = BootNonce.issue(state, "run-1")

    assert {{:error, :unbound}, state} = BootNonce.redeem(state, nonce, @ip)

    state = BootNonce.bind(state, "run-1", @ip)
    assert {{:ok, "run-1"}, _} = BootNonce.redeem(state, nonce, @ip)
  end

  test "a nonce expires at the boot window, bound or not" do
    {state, advance} = new(1_000)
    {nonce, state} = BootNonce.issue(state, "run-1")
    state = BootNonce.bind(state, "run-1", @ip)

    advance.(1_001)
    assert {{:error, :expired}, state} = BootNonce.redeem(state, nonce, @ip)
    assert {{:error, :unknown}, _} = BootNonce.redeem(state, nonce, @ip)
  end

  test "binding does not extend the window" do
    {state, advance} = new(1_000)
    {nonce, state} = BootNonce.issue(state, "run-1")
    advance.(900)
    state = BootNonce.bind(state, "run-1", @ip)
    advance.(200)

    assert {{:error, :expired}, _} = BootNonce.redeem(state, nonce, @ip)
  end

  test "a guess is unknown, and revoking a run drops its nonce" do
    {state, _} = new()
    {nonce, state} = BootNonce.issue(state, "run-1")
    state = BootNonce.bind(state, "run-1", @ip)

    assert {{:error, :unknown}, _} = BootNonce.redeem(state, "nope", @ip)

    state = BootNonce.revoke(state, "run-1")
    assert {{:error, :unknown}, _} = BootNonce.redeem(state, nonce, @ip)
  end

  test "issuing again for a run replaces the earlier nonce" do
    {state, _} = new()
    {first, state} = BootNonce.issue(state, "run-1")
    {second, state} = BootNonce.issue(state, "run-1")
    state = BootNonce.bind(state, "run-1", @ip)

    assert {{:error, :unknown}, state} = BootNonce.redeem(state, first, @ip)
    assert {{:ok, "run-1"}, _} = BootNonce.redeem(state, second, @ip)
  end

  test "the state never holds a nonce in the clear" do
    {state, _} = new()
    {nonce, state} = BootNonce.issue(state, "run-1")

    refute inspect(state) =~ nonce
  end

  test "sweep drops expired nonces" do
    {state, advance} = new(1_000)
    {_nonce, state} = BootNonce.issue(state, "run-1")
    advance.(2_000)

    assert BootNonce.size(BootNonce.sweep(state)) == 0
  end
end
