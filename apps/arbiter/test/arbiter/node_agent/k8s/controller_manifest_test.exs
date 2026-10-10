defmodule Arbiter.NodeAgent.K8s.ControllerManifestTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.ControllerManifest

  @opts [
    image: "registry.example/arbiter-agent@sha256:abc",
    primary_url: "https://primary.tail1234.ts.net",
    node_name: "mesaana-k3s"
  ]

  defp containers(deployment), do: deployment["spec"]["template"]["spec"]["containers"]
  defp container(deployment, name), do: Enum.find(containers(deployment), &(&1["name"] == name))

  describe "parse_reach/1" do
    test "maps the ?reach= query value" do
      assert ControllerManifest.parse_reach(nil) == {:ok, :direct}
      assert ControllerManifest.parse_reach("direct") == {:ok, :direct}
      assert ControllerManifest.parse_reach("tailscale") == {:ok, :tailscale}
      assert ControllerManifest.parse_reach("wireguard") == {:error, {:bad_reach, "wireguard"}}
    end
  end

  describe "deployment/1 default" do
    test "has no tailscale sidecar and no proxy" do
      {:ok, d} = ControllerManifest.deployment(@opts)
      assert [%{"name" => "controller"}] = containers(d)
      refute Enum.any?(container(d, "controller")["env"], &(&1["name"] == "ARB_NODE_PROXY"))
    end
  end

  describe "deployment/1 reach: :tailscale" do
    setup do
      {:ok, d} = ControllerManifest.deployment([reach: :tailscale] ++ @opts)
      %{d: d, ts: container(d, "tailscale"), spec: d["spec"]["template"]["spec"]}
    end

    test "adds the sidecar and points the controller at its proxy", %{d: d, ts: ts} do
      assert ts
      env = Map.new(container(d, "controller")["env"], &{&1["name"], &1["value"]})
      assert env["ARB_NODE_PROXY"] == "http://127.0.0.1:1055"
    end

    test "runs in userspace networking with an ephemeral tagged key from the Secret", %{ts: ts} do
      env = Map.new(ts["env"], &{&1["name"], &1})
      assert env["TS_USERSPACE"]["value"] == "true"
      assert env["TS_OUTBOUND_HTTP_PROXY_LISTEN"]["value"] == "127.0.0.1:1055"
      assert env["TS_EXTRA_ARGS"]["value"] =~ "--advertise-tags=tag:arbiter-node"
      assert env["TS_AUTHKEY"]["valueFrom"]["secretKeyRef"]["name"] == "arbiter-tailscale"
    end

    test "needs no NET_ADMIN and no /dev/net/tun", %{d: d, ts: ts, spec: spec} do
      json = Jason.encode!(d)
      refute json =~ "NET_ADMIN"
      refute json =~ "/dev/net/tun"
      refute json =~ "net_admin"
      assert ts["securityContext"]["capabilities"] == %{"drop" => ["ALL"]}
      assert ts["securityContext"]["privileged"] == false
      assert ts["securityContext"]["allowPrivilegeEscalation"] == false
      refute Enum.any?(spec["volumes"], &Map.has_key?(&1, "hostPath"))
    end

    test "is ready on `tailscale status` Running, not on the port being open", %{ts: ts} do
      assert %{"exec" => %{"command" => command}} = ts["readinessProbe"]
      assert Enum.join(command, " ") =~ "status"
      assert Enum.join(command, " ") =~ "Running"
      refute Map.has_key?(ts["readinessProbe"], "tcpSocket")
    end
  end
end
