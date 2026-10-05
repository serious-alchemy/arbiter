defmodule ArbiterWeb.DashboardAuth.Default do
  @moduledoc """
  The stock `ArbiterWeb.DashboardAuth` implementation (bd-3gycsz).

  **Loopback is not an identity here either.** `tailscale serve` terminates on
  the tailnet and proxies to `http://127.0.0.1:4848`, so a request from
  127.0.0.1 may be anyone on the tailnet. Every dashboard request therefore
  needs a grant; there is no address bypass.

  Two ways to get one, both ending in the same signed session cookie (the
  cookie is what the LiveView websocket sees):

    1. **Login token** (always on). `arb dashboard login` mints a one-time
       token over the authenticated API and prints a URL; opening it and
       confirming sets a session valid for 7 days. Chosen as
       the baseline because it needs no network identity at all, works over
       plain `http://127.0.0.1:4848`, and the only way to get a token is to
       already hold a coordinator bearer token (i.e. be the operator).
    2. **Tailscale identity allowlist** (opt-in). When
       `ARB_DASHBOARD_TAILSCALE_LOGINS` (comma-separated) or
       `config :arbiter_web, :dashboard_tailscale_logins` names logins, a
       request carrying `Tailscale-User-Login` is accepted if that login is on
       the list **and** the request came through `tailscale serve`: the peer
       is loopback *and* serve's `X-Forwarded-For` is present. A request from
       any other peer carrying the same headers is a spoof (a tailnet client
       talking to a non-loopback bind directly can set any header it likes)
       and is ignored. The login is re-checked against the allowlist on every
       request and LiveView mount, so removing it revokes live sessions.

  3. **Direct loopback (opt-in, off by default).** `ARB_DASHBOARD_TRUST_LOOPBACK=true`
     or `config :arbiter_web, :dashboard_trust_loopback, true`. A request is
     trusted without a login only if the peer is loopback, it carries no
     proxy/identity header (`X-Forwarded-*`, `Forwarded`, `Tailscale-*`) and
     its `Host` is exactly `127.0.0.1`, `localhost` or `[::1]` (optionally
     with a port; the DNS-rebinding defence). It is re-evaluated on every
     request and mount, never minted into a long-lived grant: the HTTP request
     only stamps a `"loopback"` marker in the session, which proves the page
     was fetched by a clean request (the websocket upgrade cannot see
     `Forwarded`/`Tailscale-*`), and the mount re-checks the flag, the peer,
     the `x-*` headers and the host. Turning the flag off revokes at once.

  ## Residual risk

  With direct loopback trust on, any local process or other Unix user on the
  host, and anyone with an `ssh -L` tunnel to the port, arrives as direct
  loopback and is trusted.

  A process on this host can reach 127.0.0.1 directly and forge the serve
  headers. That is the same trust boundary as `/api` (a local process can
  already read the operator's token files and mint a login token), so the
  Tailscale path does not widen it. If it matters, leave the allowlist empty
  and use tokens only.
  """

  @behaviour ArbiterWeb.DashboardAuth

  import Plug.Conn

  alias ArbiterWeb.Loopback

  @session_key "dashboard_auth"
  @max_age_seconds 7 * 86_400

  @impl true
  def authenticate(conn) do
    session = %{@session_key => get_session(conn, @session_key)}

    case authenticate_session(session) do
      {:ok, identity} ->
        {:ok, conn, identity}

      :error ->
        case tailscale_login(conn) do
          {:ok, login} ->
            grant = grant_session("tailscale", login)
            {:ok, put_session(conn, @session_key, grant[@session_key]), login}

          :error ->
            direct_loopback(conn)
        end
    end
  end

  @impl true
  def authenticate_session(%{@session_key => %{"kind" => kind, "sub" => sub, "at" => at}})
      when is_binary(kind) and is_binary(sub) and is_integer(at) do
    cond do
      System.system_time(:second) - at >= @max_age_seconds -> :error
      kind == "token" -> {:ok, sub}
      kind == "tailscale" and allowlisted?(sub) -> {:ok, sub}
      true -> :error
    end
  end

  def authenticate_session(_session), do: :error

  @impl true
  def authenticate_socket(
        %{@session_key => %{"kind" => "loopback", "at" => at}},
        connect_info
      )
      when is_integer(at) do
    with true <- trust_loopback?(),
         true <- System.system_time(:second) - at < @max_age_seconds,
         %{address: address} <- connect_info[:peer_data],
         true <- Loopback.loopback?(address),
         true <- Enum.all?(connect_info[:x_headers] || [], fn {k, _} -> not proxy_header?(k) end),
         %URI{host: host} when is_binary(host) <- connect_info[:uri],
         true <- loopback_host?(host) do
      {:ok, "loopback"}
    else
      _ -> :error
    end
  end

  def authenticate_socket(_session, _connect_info), do: :error

  @impl true
  def mode do
    base = if(allowlist() == [], do: "token", else: "token+tailscale")
    trust = trust_loopback?()

    %{
      impl: "default",
      mode: if(trust, do: base <> "+loopback", else: base),
      tailscale_logins: length(allowlist()),
      trust_loopback: trust
    }
  end

  @doc "Whether the opt-in direct-loopback grant is enabled."
  @spec trust_loopback?() :: boolean()
  def trust_loopback? do
    truthy?(Application.get_env(:arbiter_web, :dashboard_trust_loopback, false)) or
      truthy?(System.get_env("ARB_DASHBOARD_TRUST_LOOPBACK"))
  end

  defp truthy?(v) when v in [true, "true", "1"], do: true
  defp truthy?(_), do: false

  @doc """
  The session map a granted login carries. `max_age` (seconds) only exists so
  a test can mint an already-expired one.
  """
  @spec grant_session(String.t(), String.t(), integer()) :: map()
  def grant_session(kind, subject, age \\ 0) do
    %{
      @session_key => %{
        "kind" => kind,
        "sub" => subject,
        "at" => System.system_time(:second) - age_offset(age)
      }
    }
  end

  # `age` 0 → fresh; any larger value → that many seconds past expiry.
  defp age_offset(0), do: 0
  defp age_offset(age), do: @max_age_seconds + age

  @doc "Write a token grant onto the conn's session (after a successful login)."
  @spec put_token_grant(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_token_grant(conn, subject) do
    grant = grant_session("token", subject)
    conn |> configure_session(renew: true) |> put_session(@session_key, grant[@session_key])
  end

  @doc "Drop any grant."
  @spec revoke(Plug.Conn.t()) :: Plug.Conn.t()
  def revoke(conn), do: configure_session(conn, drop: true)

  # ---- direct loopback -------------------------------------------------------

  defp direct_loopback(conn) do
    with true <- trust_loopback?(),
         true <- Loopback.loopback?(conn.remote_ip),
         true <- not Enum.any?(conn.req_headers, fn {k, _} -> proxy_header?(k) end),
         true <- loopback_host?(conn.host) do
      marker = %{"kind" => "loopback", "sub" => "loopback", "at" => System.system_time(:second)}
      {:ok, put_session(conn, @session_key, marker), "loopback"}
    else
      _ -> :error
    end
  end

  defp proxy_header?(name) do
    name = String.downcase(name)

    String.starts_with?(name, "x-forwarded-") or name == "forwarded" or
      String.starts_with?(name, "tailscale-")
  end

  # `conn.host` / `uri.host` is the Host header without its port. Anything but
  # these literal names (127.0.0.2, a rebound domain) is refused.
  defp loopback_host?(host), do: host in ["127.0.0.1", "localhost", "::1", "[::1]"]

  # ---- tailscale -------------------------------------------------------------

  defp tailscale_login(conn) do
    with [_ | _] = allowed <- allowlist(),
         true <- Loopback.loopback?(conn.remote_ip),
         [_ | _] <- get_req_header(conn, "x-forwarded-for"),
         [login] <- get_req_header(conn, "tailscale-user-login"),
         login = String.downcase(String.trim(login)),
         true <- login in allowed do
      {:ok, login}
    else
      _ -> :error
    end
  end

  defp allowlisted?(login), do: String.downcase(login) in allowlist()

  defp allowlist do
    configured = Application.get_env(:arbiter_web, :dashboard_tailscale_logins, [])
    env = String.split(System.get_env("ARB_DASHBOARD_TAILSCALE_LOGINS") || "", ",")

    (List.wrap(configured) ++ env)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
