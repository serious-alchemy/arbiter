defmodule Arbiter.Worker.JailPodNetworkTest do
  @moduledoc """
  A cluster worker pod has no primary-local Unix sockets: `network_command/2`'s
  `UNIX-CONNECT:<primary path>` listeners can never come up there (bd-8tg3uv, #891).
  `pod_network_command/2` forwards the same loopback ports over mTLS TCP to the
  controller's bridge listener (`ARB_BRIDGE_ADDR`, `:9443`), one leaf per bridge name.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Jail

  @network %{
    proxy_socket: "/run/eg/r1.proxy.sock",
    proxy_port: 3128,
    bridges: [{4848, "/run/eg/r1.arb.sock"}, {5432, "/run/eg/r1.t1.sock"}],
    socat: "socat"
  }

  test "the pod script never dials a Unix socket, and the primary paths are not in the argv" do
    argv = Jail.pod_network_command(@network, ["claude", "--print"])
    text = Enum.join(argv, "\n")

    refute text =~ "UNIX-CONNECT"
    refute text =~ "/run/eg"
    refute text =~ ".sock"
  end

  test "each listener is a loopback port named by its bridge, ending in the agent command" do
    argv = Jail.pod_network_command(@network, ["claude", "--print"])

    assert ["sh", "-c", script, "sh", "socat" | rest] = argv
    assert script =~ "OPENSSL:"
    assert script =~ "$ARB_BRIDGE_ADDR"
    assert script =~ "/run/arb/tls/$2.crt"
    assert script =~ "/run/arb/tls/$2.key"
    assert script =~ "cafile=/etc/arb/ca/ca.crt"
    assert script =~ "commonname=arbiter-controller"
    assert script =~ "verify=1"
    assert script =~ "backlog=1024"

    assert rest == ["3128", "proxy", "4848", "4848", "5432", "5432", "--", "claude", "--print"]
  end

  test "bridge_names/1 are the names the run spec declares, so every leaf exists" do
    assert Jail.bridge_names(@network) == ["proxy", "4848", "5432"]
  end

  test "the start-up readiness wait reads /proc/net/tcp and never dials a listener (bd-8midj6)" do
    assert ["sh", "-c", script | _] = Jail.pod_network_command(@network, ["claude"])

    # bd-8midj6 ruled this out: the wait has read /proc/net/tcp since #901, so it
    # opens no TLS-bound connection (a dialled probe would fork a socat child that
    # logs `SSL_write(): unexpected eof` on hang-up). The 3-7 first-second eof lines
    # come from something else dialling a bridge port, not from these probes.
    assert script =~ "/proc/net/tcp"
    refute script =~ ~r/\bnc\b|\/dev\/tcp|socat[^\n]*TCP:/
  end

  test "a missing network spec leaves the command alone" do
    assert Jail.pod_network_command(nil, ["claude"]) == ["claude"]
  end

  test "the script is valid sh" do
    ["sh", "-c", script | _] = Jail.pod_network_command(@network, ["true"])
    assert {_, 0} = System.cmd("sh", ["-n", "-c", script], stderr_to_stdout: true)
  end

  test "the local script is unchanged: it still dials the primary's Unix sockets" do
    argv = Jail.network_command(@network, ["claude"])
    assert Enum.join(argv, "\n") =~ "UNIX-CONNECT:$2"
    assert "/run/eg/r1.proxy.sock" in argv
  end
end
