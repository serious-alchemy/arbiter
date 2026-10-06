# K4 spike: mint an EC P-256 CA, a controller server cert and per-run/per-bridge client leaves with
# OTP :public_key only (no x509 dependency), then check what OTP :ssl enforces on a listener.
#   elixir k4_mint.exs <outdir> [serve]
# Not product code: it is the evidence for K4 in docs/design/remote-workers.md (§16.15).

defmodule K4 do
  require Record
  Record.defrecord(:tbs, :OTPTBSCertificate, Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:ext, :Extension, Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:atv, :AttributeTypeAndValue, Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:spki, :OTPSubjectPublicKeyInfo, Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:pkalg, :PublicKeyAlgorithm, Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:sigalg, :SignatureAlgorithm, Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:ecpk, :ECPrivateKey, Record.extract(:ECPrivateKey, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:ecpoint, :ECPoint, Record.extract(:ECPoint, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:basic, :BasicConstraints, Record.extract(:BasicConstraints, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:akid, :AuthorityKeyIdentifier, Record.extract(:AuthorityKeyIdentifier, from_lib: "public_key/include/public_key.hrl"))
  @oid_cn {2, 5, 4, 3}
  @oid_ou {2, 5, 4, 11}
  @oid_o {2, 5, 4, 10}
  @ecdsa_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @eku_server {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @eku_client {1, 3, 6, 1, 5, 5, 7, 3, 2}

  def name(parts), do: {:rdnSequence, for({oid, v} <- parts, do: [{:AttributeTypeAndValue, oid, {:utf8String, v}}])}
  def dn(cn, ou \\ nil), do: name([{@oid_o, "arbiter"}] ++ if(ou, do: [{@oid_ou, ou}], else: []) ++ [{@oid_cn, cn}])

  def gen_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  defp pub(ecpk(publicKey: p)), do: p
  defp utc(dt), do: {:utcTime, dt |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}
  defp keyid(k), do: :crypto.hash(:sha, pub(k))

  # extensions is a list of {oid-name, critical, value}
  def cert(subject_dn, subject_key, issuer_dn, issuer_key, issuer_key_for_akid, opts) do
    nb = Keyword.fetch!(opts, :not_before)
    na = Keyword.fetch!(opts, :not_after)
    exts =
      [
        ext(extnID: {2, 5, 29, 14}, critical: false, extnValue: keyid(subject_key)),
        ext(extnID: {2, 5, 29, 35}, critical: false, extnValue: akid(keyIdentifier: keyid(issuer_key_for_akid), authorityCertIssuer: :asn1_NOVALUE, authorityCertSerialNumber: :asn1_NOVALUE))
      ] ++ Keyword.fetch!(opts, :extensions)

    t =
      tbs(
        version: :v3,
        serialNumber: :binary.decode_unsigned(:crypto.strong_rand_bytes(15)) + 1,
        signature: sigalg(algorithm: @ecdsa_sha256, parameters: :asn1_NOVALUE),
        issuer: issuer_dn,
        validity: {:Validity, utc(nb), utc(na)},
        subject: subject_dn,
        subjectPublicKeyInfo: spki(algorithm: pkalg(algorithm: {1, 2, 840, 10045, 2, 1}, parameters: {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}), subjectPublicKey: ecpoint(point: pub(subject_key))),
        extensions: exts
      )

    :public_key.pkix_sign(t, issuer_key)
  end

  def ca(not_before, not_after) do
    key = gen_key()
    d = dn("arbiter-install-ca")
    der = cert(d, key, d, key, key, not_before: not_before, not_after: not_after,
      extensions: [
        ext(extnID: {2, 5, 29, 19}, critical: true, extnValue: basic(cA: true, pathLenConstraint: 0)),
        ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:keyCertSign, :cRLSign])
      ])
    {key, der, d}
  end

  def server(ca_key, ca_dn, names, ips, nb, na) do
    key = gen_key()
    sans = for(n <- names, do: {:dNSName, String.to_charlist(n)}) ++ for(ip <- ips, do: {:iPAddress, Tuple.to_list(ip)})
    der = cert(dn(hd(names)), key, ca_dn, ca_key, ca_key, not_before: nb, not_after: na,
      extensions: [
        ext(extnID: {2, 5, 29, 19}, critical: true, extnValue: basic(cA: false, pathLenConstraint: :asn1_NOVALUE)),
        ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:digitalSignature]),
        ext(extnID: {2, 5, 29, 37}, critical: false, extnValue: [@eku_server]),
        ext(extnID: {2, 5, 29, 17}, critical: false, extnValue: sans)
      ])
    {key, der}
  end

  def leaf(ca_key, ca_dn, run, bridge, nb, na, eku \\ @eku_client) do
    key = gen_key()
    der = cert(dn(run, bridge), key, ca_dn, ca_key, ca_key, not_before: nb, not_after: na,
      extensions: [
        ext(extnID: {2, 5, 29, 19}, critical: true, extnValue: basic(cA: false, pathLenConstraint: :asn1_NOVALUE)),
        ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:digitalSignature]),
        ext(extnID: {2, 5, 29, 37}, critical: false, extnValue: [eku])
      ])
    {key, der}
  end

  def pem_cert(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  def pem_key(k), do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, k)])

  def subject_fields(der) do
    otp = :public_key.pkix_decode_cert(der, :otp)
    {:rdnSequence, rdns} = otp |> elem(1) |> then(&tbs(&1, :subject))
    for [{:AttributeTypeAndValue, oid, {_, v}}] <- rdns, into: %{}, do: {oid, to_string(v)}
  end
  def cn_ou(der) do
    f = subject_fields(der)
    {f[@oid_cn], f[@oid_ou]}
  end
end

[out | rest] = System.argv()
File.mkdir_p!(out)
now = DateTime.utc_now()
{ca_key, ca_der, ca_dn} = K4.ca(DateTime.add(now, -60), DateTime.add(now, 365 * 86400))
File.write!(Path.join(out, "ca.crt"), K4.pem_cert(ca_der))
File.write!(Path.join(out, "ca.key"), K4.pem_key(ca_key))
# the server certificate has SANs: DNS arbiter-controller + the Service ClusterIP (K§9.2)
srv_ips = System.get_env("SPIKE_SERVER_IP", "10.43.98.199") |> String.split(",") |> Enum.map(fn ip -> ip |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple() end)
{skey, sder} = K4.server(ca_key, ca_dn, ["arbiter-controller"], srv_ips, DateTime.add(now, -60), DateTime.add(now, 86400))
File.write!(Path.join(out, "server.crt"), K4.pem_cert(sder))
File.write!(Path.join(out, "server.key"), K4.pem_key(skey))
# per-run, per-bridge leaves valid until the run deadline (here +2 h)
for b <- ~w(proxy arb git) do
  {k, d} = K4.leaf(ca_key, ca_dn, "run-0123456789ab", b, DateTime.add(now, -60), DateTime.add(now, 7200))
  File.write!(Path.join(out, "leaf-#{b}.crt"), K4.pem_cert(d))
  File.write!(Path.join(out, "leaf-#{b}.key"), K4.pem_key(k))
end
# negative fixtures
{ek, ed} = K4.leaf(ca_key, ca_dn, "run-expired", "proxy", DateTime.add(now, -7200), DateTime.add(now, -3600))
File.write!(Path.join(out, "leaf-expired.crt"), K4.pem_cert(ed)); File.write!(Path.join(out, "leaf-expired.key"), K4.pem_key(ek))
{ok_, _od, odn} = K4.ca(DateTime.add(now, -60), DateTime.add(now, 86400))
{xk, xd} = K4.leaf(ok_, odn, "run-0123456789ab", "proxy", DateTime.add(now, -60), DateTime.add(now, 7200))
File.write!(Path.join(out, "leaf-othercA.crt"), K4.pem_cert(xd)); File.write!(Path.join(out, "leaf-othercA.key"), K4.pem_key(xk))
{sk2, sd2} = K4.leaf(ca_key, ca_dn, "run-0123456789ab", "proxy", DateTime.add(now, -60), DateTime.add(now, 7200), {1, 3, 6, 1, 5, 5, 7, 3, 1})
File.write!(Path.join(out, "leaf-ekuserver.crt"), K4.pem_cert(sd2)); File.write!(Path.join(out, "leaf-ekuserver.key"), K4.pem_key(sk2))

# throughput of minting
{us, _} = :timer.tc(fn -> for i <- 1..200, do: K4.leaf(ca_key, ca_dn, "run-#{i}", "proxy", DateTime.add(now, -60), DateTime.add(now, 7200)) end)
IO.puts("minted 200 leaves in #{div(us, 1000)} ms (#{Float.round(us / 200 / 1000, 2)} ms each)")
IO.puts("CN/OU read back from the minted proxy leaf: #{inspect(K4.cn_ou(File.read!(Path.join(out, "leaf-proxy.crt")) |> :public_key.pem_decode() |> hd() |> elem(1)))}")

if rest == ["serve"] do
  :ssl.start()
  port = String.to_integer(System.get_env("SPIKE_PORT", "19443"))
  {:ok, l} = :ssl.listen(port, [:binary, active: false, reuseaddr: true, backlog: 1024,
    certfile: String.to_charlist(Path.join(out, "server.crt")), keyfile: String.to_charlist(Path.join(out, "server.key")),
    cacertfile: String.to_charlist(Path.join(out, "ca.crt")), verify: :verify_peer, fail_if_no_peer_cert: true, versions: (if System.get_env("SPIKE_TLS") == "1.2", do: [:"tlsv1.2"], else: [:"tlsv1.3", :"tlsv1.2"])])
  IO.puts("LISTENING #{port}")
  loop = fn loop ->
    case :ssl.transport_accept(l, 30_000) do
      {:ok, s} ->
        spawn(fn ->
          case :ssl.handshake(s, 5_000) do
            {:ok, s2} ->
              {:ok, der} = :ssl.peercert(s2)
              {cn, ou} = K4.cn_ou(der)
              IO.puts("ACCEPT cn=#{cn} ou=#{ou}")
              :ssl.send(s2, "HELLO cn=#{cn} ou=#{ou}\n")
              count =
                if System.get_env("SPIKE_ACTIVE") == "1" do
                  # active-mode read: the controller relay should read like this (see K3 notes)
                  :ssl.setopts(s2, active: true)
                  fn count, n ->
                    receive do
                      {:ssl, ^s2, d} -> count.(count, n + byte_size(d))
                      {:ssl_closed, ^s2} -> n
                      {:ssl_error, ^s2, _} -> n
                    after 3_000 -> n
                    end
                  end
                else
                  fn count, n ->
                    case :ssl.recv(s2, 0, 3_000) do
                      {:ok, d} -> count.(count, n + byte_size(d))
                      _ -> n
                    end
                  end
                end
              IO.puts("BYTES #{count.(count, 0)} cn=#{cn} ou=#{ou}")
              :ssl.close(s2)
            {:error, r} -> IO.puts("REJECT #{inspect(r)}")
          end
        end)
        loop.(loop)
      {:error, :timeout} -> loop.(loop)
      {:error, e} -> IO.puts("listener stop #{inspect(e)}")
    end
  end
  loop.(loop)
end
