defmodule ArbiterWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The same positive, fail-closed role check as `Arbiter.Application.start/2`
    # (docs/design/remote-workers.md §3). An agent-role VM runs no web tier: with
    # no `ArbiterWeb.Endpoint` there is no listener and no port is bound.
    with {:ok, role} <- Arbiter.NodeAgent.role(),
         {:ok, children} <- supervisor_children(role) do
      # See https://hexdocs.pm/elixir/Supervisor.html
      # for other strategies and supported options
      Supervisor.start_link(children, strategy: :one_for_one, name: ArbiterWeb.Supervisor)
    end
  end

  @doc """
  The web tier's top-level children for `role`. `:agent` returns `[]` and never
  calls `primary_fun`; `:primary` returns `primary_fun.()`; any other role is an
  error and nothing starts.
  """
  @spec supervisor_children(term(), (-> list())) ::
          {:ok, list()} | {:error, {:unknown_role, term()}}
  def supervisor_children(role, primary_fun \\ &primary_children/0)
  def supervisor_children(:agent, _primary_fun), do: {:ok, []}
  def supervisor_children(:primary, primary_fun), do: {:ok, primary_fun.()}
  def supervisor_children(other, _primary_fun), do: {:error, {:unknown_role, other}}

  # Boot-time side effects live here, not in `start/2`, so they run only for a
  # role that serves the dashboard.
  defp primary_children do
    # Resolve the running git SHA at boot so /api/version always reflects
    # the currently-checked-out commit, not a stale compile-time value.
    Application.put_env(:arbiter_web, :runtime_git_sha, resolve_git_sha())

    # Initialize the version tooltip cache for efficient access in layouts
    ArbiterWeb.VersionHelper.init_cache()

    warn_if_bound_off_loopback()

    [
      ArbiterWeb.Telemetry,
      # Outbound HTTP pool for the Anthropic proxy (bd-5boun6) — forwards Claude
      # CLI traffic to api.anthropic.com and streams SSE responses back.
      {Finch, name: ArbiterWeb.Finch},
      # Routes Arbiter.MCP session ids → their open GET /mcp SSE streams so
      # server-initiated messages reach the right client (ArbiterWeb.MCP.Session).
      {Registry, keys: :unique, name: ArbiterWeb.MCP.Session.registry()},
      # One-time dashboard login tokens (bd-3gycsz).
      ArbiterWeb.DashboardAuth.LoginTokens,
      # Start a worker by calling: ArbiterWeb.Worker.start_link(arg)
      # {ArbiterWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      ArbiterWeb.Endpoint
    ] ++ operator_socket_children()
  end

  @doc """
  The operator socket (`Arbiter.MCP.OperatorSocket`, bd-8381tk) that
  `arb mcp token mint` proves operator identity over. It runs only beside an
  endpoint that actually serves HTTP, and its path is keyed by that
  endpoint's port, so a dev server and the release on the same host don't
  collide. `config :arbiter, Arbiter.MCP.OperatorSocket, enabled: false`
  turns it off. Tokens can then only be minted by a caller that already
  holds one.

  Options (defaults read from the running config): `:serve?`, `:port`,
  `:enabled?`.
  """
  @spec operator_socket_children(keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def operator_socket_children(opts \\ []) do
    serve? =
      Keyword.get_lazy(opts, :serve?, fn ->
        Phoenix.Endpoint.server?(:arbiter_web, ArbiterWeb.Endpoint)
      end)

    enabled? =
      Keyword.get_lazy(opts, :enabled?, fn ->
        :arbiter
        |> Application.get_env(Arbiter.MCP.OperatorSocket, [])
        |> Keyword.get(:enabled, true)
      end)

    port =
      Keyword.get_lazy(opts, :port, fn ->
        :arbiter_web
        |> Application.get_env(ArbiterWeb.Endpoint, [])
        |> Keyword.get(:http, [])
        |> Keyword.get(:port, 4848)
      end)

    if serve? and enabled? and is_integer(port) do
      [{Arbiter.MCP.OperatorSocket, path: Arbiter.MCP.OperatorProof.socket_path(port)}]
    else
      []
    end
  end

  defp warn_if_bound_off_loopback do
    ip =
      :arbiter_web
      |> Application.get_env(ArbiterWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:ip)

    if ip, do: ArbiterWeb.Boot.BindAddressCheck.warn_if_off_loopback(ip)
  end

  defp resolve_git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    # No Endpoint runs in agent mode, so there is nothing to reconfigure.
    if Arbiter.NodeAgent.agent?(),
      do: :ok,
      else: ArbiterWeb.Endpoint.config_change(changed, removed)

    :ok
  end
end
