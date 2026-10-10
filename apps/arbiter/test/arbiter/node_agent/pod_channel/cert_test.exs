defmodule Arbiter.NodeAgent.PodChannel.CertTest do
  @moduledoc """
  The per-install CA, the controller's server certificate and the per-run,
  per-bridge client leaves (`docs/design/remote-workers.md` §16 K§9.2), minted with
  OTP `:public_key` alone. The certificates are judged by `:ssl`/`:public_key`,
  not by reading our own encoder back.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PodChannel.Cert

  defp window(from, to),
    do: {DateTime.add(DateTime.utc_now(), from), DateTime.add(DateTime.utc_now(), to)}

  setup do
    {nb, na} = window(-60, 86_400)
    %{ca: Cert.ca(nb, na), nb: nb, na: na}
  end

  test "the CA is a self-signed CA certificate", %{ca: ca} do
    assert {:ok, _} = :public_key.pkix_path_validation(ca.der, [], [])
    assert Cert.subject(ca.der).cn == "arbiter-install-ca"
    assert :public_key.pkix_is_self_signed(ca.der)
  end

  test "a leaf carries CN = run and OU = bridge and chains to the CA", %{ca: ca, nb: nb, na: na} do
    leaf = Cert.leaf(ca, "run-0123456789ab", "proxy", nb, na)

    assert %{cn: "run-0123456789ab", ou: "proxy"} = Cert.subject(leaf.der)
    assert {:ok, _} = :public_key.pkix_path_validation(ca.der, [leaf.der], [])
  end

  test "a leaf from another CA does not chain to this one", %{ca: ca, nb: nb, na: na} do
    other = Cert.ca(nb, na)
    leaf = Cert.leaf(other, "run-x", "proxy", nb, na)

    assert {:error, _} = :public_key.pkix_path_validation(ca.der, [leaf.der], [])
  end

  test "an expired leaf fails validation", %{ca: ca} do
    {nb, na} = window(-7200, -3600)
    leaf = Cert.leaf(ca, "run-x", "proxy", nb, na)

    assert {:error, {:bad_cert, :cert_expired}} =
             :public_key.pkix_path_validation(ca.der, [leaf.der], [])
  end

  test "a CA survives a PEM round trip (what the store keeps)", %{ca: ca, nb: nb, na: na} do
    {:ok, reloaded} = Cert.load_ca(Cert.pem_cert(ca.der), Cert.pem_key(ca.key))
    leaf = Cert.leaf(reloaded, "run-x", "arb", nb, na)

    assert {:ok, _} = :public_key.pkix_path_validation(ca.der, [leaf.der], [])
  end

  test "load_ca/2 refuses a key that does not belong to the certificate", %{
    ca: ca,
    nb: nb,
    na: na
  } do
    other = Cert.ca(nb, na)
    assert {:error, :key_mismatch} = Cert.load_ca(Cert.pem_cert(ca.der), Cert.pem_key(other.key))
  end

  test "the server certificate has the controller's name and the Service IP as SANs", %{
    ca: ca,
    nb: nb,
    na: na
  } do
    server = Cert.server(ca, ["arbiter-controller"], [{10, 43, 98, 199}], nb, na)

    assert {:ok, _} = :public_key.pkix_path_validation(ca.der, [server.der], [])
    assert :public_key.pkix_verify_hostname(server.der, [{:dns_id, ~c"arbiter-controller"}])
    assert :public_key.pkix_verify_hostname(server.der, [{:ip, {10, 43, 98, 199}}])
    refute :public_key.pkix_verify_hostname(server.der, [{:dns_id, ~c"evil.example"}])
  end

  test "validity past 2049 is encoded as GeneralizedTime and still validates", %{ca: ca} do
    nb = DateTime.add(DateTime.utc_now(), -60)
    na = DateTime.new!(~D[2060-01-01], ~T[00:00:00], "Etc/UTC")
    leaf = Cert.leaf(ca, "run-x", "proxy", nb, na)

    assert {:ok, _} = :public_key.pkix_path_validation(ca.der, [leaf.der], [])
  end
end
