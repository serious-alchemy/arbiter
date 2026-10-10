defmodule Arbiter.NodeAgent.K8s.E2EGuardTest do
  @moduledoc """
  The `:k8s` end-to-end suite must never reach a real cluster by accident
  (`Arbiter.Test.K8sE2E.guard!/2`). These run in the default suite: no cluster needed.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Test.K8sE2E

  defp view(context, server),
    do: %{
      "current-context" => context,
      "clusters" => [%{"cluster" => %{"server" => server}}]
    }

  test "a kind or k3d context on loopback is allowed" do
    assert :ok = K8sE2E.guard!(nil, view("kind-arb-e2e", "https://127.0.0.1:41233"))
    assert :ok = K8sE2E.guard!(nil, view("k3d-arb-e2e", "https://0.0.0.0:6550"))
    assert :ok = K8sE2E.guard!(nil, view("kind-x", "https://localhost:6443"))
  end

  test "any other context is refused, whatever the address" do
    for context <- ["default", "mesaana", "k3s", "prod-kind", "", nil] do
      assert_raise RuntimeError, ~r/refusing context/, fn ->
        K8sE2E.guard!(nil, view(context, "https://127.0.0.1:6443"))
      end
    end
  end

  test "a kind-named context on a LAN or public address is refused" do
    for server <- [
          "https://192.168.1.169:6443",
          "https://k3s.example.com:6443",
          "https://10.0.0.5"
        ] do
      assert_raise RuntimeError, ~r/refusing API server/, fn ->
        K8sE2E.guard!(nil, view("kind-looks-fine", server))
      end
    end
  end

  test "without the opt-in env the suite does not connect" do
    previous = {System.get_env("ARB_K8S_E2E"), System.get_env("ARB_K8S_E2E_KUBECONFIG")}
    System.delete_env("ARB_K8S_E2E")
    System.delete_env("ARB_K8S_E2E_KUBECONFIG")

    try do
      assert_raise RuntimeError, ~r/ARB_K8S_E2E=1/, fn -> K8sE2E.connect!() end
    after
      {flag, path} = previous
      if flag, do: System.put_env("ARB_K8S_E2E", flag)
      if path, do: System.put_env("ARB_K8S_E2E_KUBECONFIG", path)
    end
  end

  test "the default test run excludes the :k8s tag" do
    assert :k8s in Keyword.fetch!(ExUnit.configuration(), :exclude)
  end
end
