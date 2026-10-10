defmodule Arbiter.NodeAgent.K8s.QuantityTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Quantity

  test "podman memory: bytes by default, k/m/g are binary" do
    assert Quantity.memory("1024", :podman) == {:ok, 1024}
    assert Quantity.memory("1k", :podman) == {:ok, 1024}
    assert Quantity.memory("2M", :podman) == {:ok, 2 * 1_048_576}
    assert Quantity.memory("3g", :podman) == {:ok, 3 * 1_073_741_824}
    assert Quantity.memory("5b", :podman) == {:ok, 5}
  end

  test "podman memory refuses zero, signs, fractions and other units" do
    for bad <- ["0", "-1", "1.5g", "1Gi", "g", "", "1 g"],
        do: assert(Quantity.memory(bad, :podman) == :error, bad)
  end

  test "k8s memory: Gi is binary, G is decimal, fractions are exact" do
    assert Quantity.memory("4Gi", :k8s) == {:ok, 4 * 1_073_741_824}
    assert Quantity.memory("1G", :k8s) == {:ok, 1_000_000_000}
    assert Quantity.memory("1.5Gi", :k8s) == {:ok, 1_610_612_736}
    assert Quantity.memory("512", :k8s) == {:ok, 512}
    assert Quantity.memory("500m", :k8s) == :error
    assert Quantity.memory("0", :k8s) == :error
  end

  test "cpu: podman decimals and k8s millicores agree" do
    assert Quantity.cpu("1.5", :podman) == {:ok, 1500}
    assert Quantity.cpu("0.1", :podman) == {:ok, 100}
    assert Quantity.cpu("2", :k8s) == {:ok, 2000}
    assert Quantity.cpu("500m", :k8s) == {:ok, 500}
    assert Quantity.cpu("0", :podman) == :error
    assert Quantity.cpu("abc", :k8s) == :error
    assert Quantity.cpu("1Gi", :k8s) == :error
  end

  test "format picks the largest exact unit" do
    assert Quantity.format_memory(3 * 1_073_741_824) == "3Gi"
    assert Quantity.format_memory(1536 * 1_048_576) == "1536Mi"
    assert Quantity.format_memory(2048) == "2Ki"
    assert Quantity.format_memory(1000) == "1000"
    assert Quantity.format_cpu(2000) == "2"
    assert Quantity.format_cpu(1500) == "1500m"
  end

  test "format and parse round-trip" do
    for bytes <- [1, 1000, 4096, 5_000_000, 7 * 1_073_741_824] do
      assert Quantity.memory(Quantity.format_memory(bytes), :k8s) == {:ok, bytes}
    end
  end

  test "valid? accepts positive quantities only" do
    assert Quantity.valid?("4Gi") and Quantity.valid?("100m") and Quantity.valid?("1")

    refute Quantity.valid?("0") or Quantity.valid?("lots") or Quantity.valid?(nil) or
             Quantity.valid?("-1")
  end
end
