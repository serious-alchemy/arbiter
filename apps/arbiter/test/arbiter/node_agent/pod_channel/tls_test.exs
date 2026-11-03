defmodule Arbiter.NodeAgent.PodChannel.TlsTest do
  @moduledoc "The `:ssl` server options both pod-channel listeners share."
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PodChannel.Cert
  alias Arbiter.NodeAgent.PodChannel.Tls

  setup do
    nb = DateTime.add(DateTime.utc_now(), -60)
    na = DateTime.add(DateTime.utc_now(), 86_400)
    ca = Cert.ca(nb, na)
    %{ca: ca, identity: Cert.leaf(ca, "controller", "server", nb, na)}
  end

  test "session tickets are disabled", %{ca: ca, identity: id} do
    assert Tls.server_options(id, ca)[:session_tickets] == :disabled
  end

  test "TLS 1.3 with 1.2 fallback by default", %{ca: ca, identity: id} do
    assert Tls.server_options(id, ca)[:versions] == [:"tlsv1.3", :"tlsv1.2"]
  end

  test "tls12_only pins the listener to TLS 1.2", %{ca: ca, identity: id} do
    assert Tls.server_options(id, ca, tls12_only: true)[:versions] == [:"tlsv1.2"]
  end
end
