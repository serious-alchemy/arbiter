defmodule Arbiter.NodeAgent.PodChannel.Cert do
  @moduledoc """
  X.509 minting for the pod channel (`docs/design/remote-workers.md` §16, K§9.2),
  with OTP `:public_key` alone (K1-A5: no `x509` dependency; the K1 spike's
  `k4_mint.exs` is the evidence this follows).

  Three kinds of certificate, all EC P-256 / ECDSA-SHA256:

    * the **CA** (`CA:TRUE, pathlen:0`, `keyCertSign`), created once per install;
    * the controller's **server certificate** (`serverAuth` only, SANs: the DNS
      names and IP addresses the pods dial);
    * **leaves**, one per run per bridge: `CN = <run id>`, `OU = <bridge name>`,
      `clientAuth` only, valid until the run's deadline.

  The EKUs are enforced by `:ssl` on the listener: a `serverAuth`-only
  certificate offered as a client certificate is rejected with
  `invalid_ext_keyusage`, so a server certificate can never be replayed as a
  bridge identity.

  A "cert" here is `%{key: ec_private_key, der: binary}`.
  """

  require Record

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :ext,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :pkalg,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :sigalg,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :ecpk,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :ecpoint,
    :ECPoint,
    Record.extract(:ECPoint, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :basic,
    :BasicConstraints,
    Record.extract(:BasicConstraints, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :akid,
    :AuthorityKeyIdentifier,
    Record.extract(:AuthorityKeyIdentifier, from_lib: "public_key/include/public_key.hrl")
  )

  @type t :: %{key: tuple(), der: binary()}

  @oid_cn {2, 5, 4, 3}
  @oid_ou {2, 5, 4, 11}
  @oid_o {2, 5, 4, 10}
  @ecdsa_sha256 {1, 2, 840, 10_045, 4, 3, 2}
  @eku_server {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @eku_client {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @ca_cn "arbiter-install-ca"

  @doc "A new self-signed CA valid from `not_before` to `not_after`."
  @spec ca(DateTime.t(), DateTime.t()) :: t()
  def ca(%DateTime{} = not_before, %DateTime{} = not_after) do
    key = gen_key()
    dn = dn(@ca_cn)

    der =
      sign(dn, key, dn, key, not_before, not_after, [
        ext(
          extnID: {2, 5, 29, 19},
          critical: true,
          extnValue: basic(cA: true, pathLenConstraint: 0)
        ),
        ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:keyCertSign, :cRLSign])
      ])

    %{key: key, der: der}
  end

  @doc """
  The controller's server certificate: `names` are DNS SANs (the first is also
  the CN), `ips` are IPv4/IPv6 tuples (an `iPAddress` SAN is a **list of
  integers**, not a tuple or a binary).
  """
  @spec server(t(), [String.t()], [:inet.ip_address()], DateTime.t(), DateTime.t()) :: t()
  def server(ca, [first | _] = names, ips, not_before, not_after) do
    key = gen_key()

    sans =
      for(n <- names, do: {:dNSName, String.to_charlist(n)}) ++
        for(ip <- ips, do: {:iPAddress, ip_list(ip)})

    der =
      sign(dn(first), key, issuer_dn(ca), ca.key, not_before, not_after, [
        ext(
          extnID: {2, 5, 29, 19},
          critical: true,
          extnValue: basic(cA: false, pathLenConstraint: :asn1_NOVALUE)
        ),
        ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:digitalSignature]),
        ext(extnID: {2, 5, 29, 37}, critical: false, extnValue: [@eku_server]),
        ext(extnID: {2, 5, 29, 17}, critical: false, extnValue: sans)
      ])

    %{key: key, der: der}
  end

  @doc """
  A client leaf: `CN = run`, `OU = bridge`, `clientAuth` only. `eku: :server`
  mints the wrong-purpose fixture the tests use to prove `:ssl` refuses it.
  """
  @spec leaf(t(), String.t(), String.t(), DateTime.t(), DateTime.t(), keyword()) :: t()
  def leaf(ca, run, bridge, not_before, not_after, opts \\ []) do
    key = gen_key()
    eku = if Keyword.get(opts, :eku) == :server, do: @eku_server, else: @eku_client

    der =
      sign(dn(run, bridge), key, issuer_dn(ca), ca.key, not_before, not_after, [
        ext(
          extnID: {2, 5, 29, 19},
          critical: true,
          extnValue: basic(cA: false, pathLenConstraint: :asn1_NOVALUE)
        ),
        ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:digitalSignature]),
        ext(extnID: {2, 5, 29, 37}, critical: false, extnValue: [eku])
      ])

    %{key: key, der: der}
  end

  @doc "The `%{cn:, ou:}` of a DER certificate's subject (`ou` is `nil` when absent)."
  @spec subject(binary()) :: %{cn: String.t() | nil, ou: String.t() | nil}
  def subject(der) when is_binary(der) do
    {:rdnSequence, rdns} = der |> tbs_of() |> tbs(:subject)

    fields =
      for [{:AttributeTypeAndValue, oid, {_, value}}] <- rdns,
          into: %{},
          do: {oid, to_string(value)}

    %{cn: fields[@oid_cn], ou: fields[@oid_ou]}
  end

  @doc "PEM for a certificate."
  @spec pem_cert(binary()) :: binary()
  def pem_cert(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  @doc "PEM for an EC private key."
  @spec pem_key(tuple()) :: binary()
  def pem_key(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

  @doc """
  Rebuild a CA from the PEM a store kept. Refuses a certificate that is not
  currently valid or a key that is not the certificate's.
  """
  @spec load_ca(binary(), binary()) :: {:ok, t()} | {:error, term()}
  def load_ca(cert_pem, key_pem) do
    with {:ok, der} <- decode_cert(cert_pem),
         {:ok, key} <- decode_key(key_pem),
         :ok <- key_matches(der, key),
         {:ok, _} <- validate_self(der) do
      {:ok, %{key: key, der: der}}
    end
  end

  # -- internals ---------------------------------------------------------------------

  defp decode_cert(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted} | _] -> {:ok, der}
      _ -> {:error, :bad_ca_certificate}
    end
  rescue
    _ -> {:error, :bad_ca_certificate}
  end

  defp decode_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:ECPrivateKey, _, :not_encrypted} = entry | _] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      _ ->
        {:error, :bad_ca_key}
    end
  rescue
    _ -> {:error, :bad_ca_key}
  end

  defp key_matches(der, key) do
    spki(subjectPublicKey: ecpoint(point: point)) = der |> tbs_of() |> tbs(:subjectPublicKeyInfo)
    if point == ecpk(key, :publicKey), do: :ok, else: {:error, :key_mismatch}
  end

  defp validate_self(der) do
    case :public_key.pkix_path_validation(der, [], []) do
      {:ok, _} = ok -> ok
      {:error, {:bad_cert, reason}} -> {:error, {:ca_invalid, reason}}
    end
  end

  defp tbs_of(der), do: der |> :public_key.pkix_decode_cert(:otp) |> elem(1)

  defp issuer_dn(%{der: der}), do: der |> tbs_of() |> tbs(:subject)

  defp gen_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  defp name(parts),
    do:
      {:rdnSequence,
       for({oid, v} <- parts, do: [{:AttributeTypeAndValue, oid, {:utf8String, v}}])}

  defp dn(cn), do: name([{@oid_o, "arbiter"}, {@oid_cn, cn}])
  defp dn(cn, ou), do: name([{@oid_o, "arbiter"}, {@oid_ou, ou}, {@oid_cn, cn}])

  defp ip_list(ip) when tuple_size(ip) == 4, do: Tuple.to_list(ip)

  defp ip_list(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.flat_map(fn w -> [div(w, 256), rem(w, 256)] end)

  defp pub(ecpk(publicKey: p)), do: p
  defp keyid(key), do: :crypto.hash(:sha, pub(key))

  # RFC 5280 §4.1.2.5: UTCTime to 2049, GeneralizedTime from 2050.
  defp time(%DateTime{year: year} = dt) when year < 2050,
    do: {:utcTime, dt |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}

  defp time(%DateTime{} = dt),
    do: {:generalTime, dt |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}

  defp sign(subject, subject_key, issuer, issuer_key, not_before, not_after, extensions) do
    exts =
      [
        ext(extnID: {2, 5, 29, 14}, critical: false, extnValue: keyid(subject_key)),
        ext(
          extnID: {2, 5, 29, 35},
          critical: false,
          extnValue:
            akid(
              keyIdentifier: keyid(issuer_key),
              authorityCertIssuer: :asn1_NOVALUE,
              authorityCertSerialNumber: :asn1_NOVALUE
            )
        )
      ] ++ extensions

    body =
      tbs(
        version: :v3,
        serialNumber: :binary.decode_unsigned(:crypto.strong_rand_bytes(15)) + 1,
        signature: sigalg(algorithm: @ecdsa_sha256, parameters: :asn1_NOVALUE),
        issuer: issuer,
        validity: {:Validity, time(not_before), time(not_after)},
        subject: subject,
        subjectPublicKeyInfo:
          spki(
            algorithm:
              pkalg(
                algorithm: {1, 2, 840, 10_045, 2, 1},
                parameters: {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}
              ),
            subjectPublicKey: ecpoint(point: pub(subject_key))
          ),
        extensions: exts
      )

    :public_key.pkix_sign(body, issuer_key)
  end
end
