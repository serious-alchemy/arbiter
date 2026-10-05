defmodule ArbiterWeb.DashboardAuth do
  @moduledoc """
  The dashboard's authentication slot (bd-3gycsz).

  Everything under the `:browser` pipeline and every LiveView mounted through
  the router's `live_session` goes through one implementation of this
  behaviour, chosen by config:

      config :arbiter_web, :dashboard_auth, MyPackage.SsoAuth

  With nothing configured the implementation is `ArbiterWeb.DashboardAuth.Default`
  (one-time login token → signed session, plus an opt-in Tailscale identity
  allowlist). A future SSO extension replaces it by setting that key from its
  own config; it never has to touch the router, the plug or the LiveView hook.

  `/api` and `/mcp` are **not** governed by this slot: they keep their bearer
  token model (`ArbiterWeb.Plugs.ApiAuth`).

  ## Callbacks

    * `authenticate/1` — decide an HTTP request. The session is already
      fetched. Return `{:ok, conn, identity}` (the conn may carry a freshly
      written session grant) or `:error` to send the browser to the login page.
    * `authenticate_session/1` — decide from the session map alone. This is
      what the LiveView socket can see: `Phoenix.LiveView.Socket` has no
      overridable `connect/3`, so `ArbiterWeb.LiveHooks`' `:dashboard_auth`
      `on_mount` hook (first in the router's `live_session`) re-checks the
      session on every mount, connected or not. An HTTP-only trust signal
      (a proxy header) must therefore be turned into a session grant by
      `authenticate/1`, and `authenticate_session/1` must re-validate it.
    * `authenticate_socket/2` (optional) — a second chance for a LiveView mount
      whose session alone was refused: it also gets the mount's connect info
      (`:peer_data`, `:x_headers`, `:uri`), for grants that depend on the
      request rather than a stored session.
    * `mode/0` — a small map describing the active mode; `arb server doctor`
      reports it.
    * `login_path/0` (optional, default `"/login"`) — where unauthenticated
      requests are redirected.
  """

  @typedoc "Whatever the implementation wants to call the authenticated party."
  @type identity :: String.t()

  @callback authenticate(Plug.Conn.t()) :: {:ok, Plug.Conn.t(), identity()} | :error
  @callback authenticate_session(map()) :: {:ok, identity()} | :error
  @callback mode() :: %{
              required(:impl) => String.t(),
              required(:mode) => String.t(),
              optional(atom()) => term()
            }
  @callback login_path() :: String.t()
  @callback authenticate_socket(map(), map()) :: {:ok, identity()} | :error
  @optional_callbacks login_path: 0, authenticate_socket: 2

  @default_login_path "/login"

  @doc "The configured implementation module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:arbiter_web, :dashboard_auth) || __MODULE__.Default

  @spec authenticate(Plug.Conn.t()) :: {:ok, Plug.Conn.t(), identity()} | :error
  def authenticate(conn), do: impl().authenticate(conn)

  @spec authenticate_session(map()) :: {:ok, identity()} | :error
  def authenticate_session(session), do: impl().authenticate_session(session)

  @doc "Like `authenticate_session/1`, with connect info; falls back to `:error`."
  @spec authenticate_socket(map(), map()) :: {:ok, identity()} | :error
  def authenticate_socket(session, connect_info) do
    mod = impl()
    Code.ensure_loaded(mod)

    if function_exported?(mod, :authenticate_socket, 2),
      do: mod.authenticate_socket(session, connect_info),
      else: :error
  end

  @spec mode() :: map()
  def mode, do: impl().mode()

  @spec login_path() :: String.t()
  def login_path do
    mod = impl()
    Code.ensure_loaded(mod)
    if function_exported?(mod, :login_path, 0), do: mod.login_path(), else: @default_login_path
  end
end
