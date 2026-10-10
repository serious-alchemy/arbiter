defmodule Arbiter.NodeAgent.PodChannel.Tls do
  @moduledoc """
  The `:ssl` options both pod-channel listeners share
  (`docs/design/remote-workers.md` §16 K§9.2, K§9.3, K1-A4).

  `verify_peer` against the install's CA only (`cacerts: [ca]`, `depth: 0`: the
  CA signs leaves directly, so no chain can be longer), TLS 1.3 with 1.2 as a
  fallback, and `backlog: 1024` (socat's default accept backlog of 5 left a
  quarter of a 100-connection burst unanswered in the K3 spike; this is the
  listener's, but the same lesson). `:ssl` itself enforces expiry, an unknown
  CA and the extended key usage: a `serverAuth`-only certificate offered as a
  client certificate is rejected with `invalid_ext_keyusage`.

  `fail_if_no_peer_cert` is `true` on `:9443` and `false` on `:9444`, whose
  `/boot` is server-authenticated only; the other `:9444` routes check the
  certificate themselves.
  """

  alias Arbiter.NodeAgent.PodChannel.Cert

  @send_timeout_ms 30_000

  @doc """
  Server options for `identity` (`%{key:, der:}`, the controller's server
  certificate) and `ca`. Extra options: `:require_client_cert` (default `true`),
  `:send_timeout_ms`.
  """
  @spec server_options(Cert.t(), Cert.t(), keyword()) :: keyword()
  def server_options(identity, ca, opts \\ []) do
    [
      cert: identity.der,
      key: {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, identity.key)},
      cacerts: [ca.der],
      verify: :verify_peer,
      depth: 0,
      fail_if_no_peer_cert: Keyword.get(opts, :require_client_cert, true),
      versions: [:"tlsv1.3", :"tlsv1.2"],
      reuse_sessions: false,
      honor_cipher_order: true
    ]
  end

  @doc "Socket options a listener's accepted sockets need (the stream relies on them)."
  @spec socket_options(keyword()) :: keyword()
  def socket_options(opts \\ []) do
    [
      :binary,
      active: false,
      packet: :raw,
      reuseaddr: true,
      backlog: Keyword.get(opts, :backlog, 1024),
      nodelay: true,
      send_timeout: Keyword.get(opts, :send_timeout_ms, @send_timeout_ms),
      send_timeout_close: true
    ]
  end
end
