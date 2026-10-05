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

  ## Residual risk

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
        with {:ok, login} <- tailscale_login(conn) do
          grant = grant_session("tailscale", login)
          {:ok, put_session(conn, @session_key, grant[@session_key]), login}
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
  def mode do
    %{
      impl: "default",
      mode: if(allowlist() == [], do: "token", else: "token+tailscale"),
      tailscale_logins: length(allowlist())
    }
  end

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
