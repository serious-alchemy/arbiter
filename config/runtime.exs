import Config

config :arbiter_web, ArbiterWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4848"))]

# The VM's role (docs/design/remote-workers.md §3). `ARB_ROLE=agent` makes this
# release a node agent: it starts only `Arbiter.NodeAgent.Supervisor`, so none
# of the primary's runtime config below applies — no SECRET_KEY_BASE, no Repo,
# no Endpoint. Unset (or empty) leaves the application default, `:primary`, and
# an unrecognised value refuses to boot instead of quietly becoming a primary.
# `Arbiter.NodeAgent.role/0` reads this back at boot.
agent? =
  case System.get_env("ARB_ROLE") do
    role when role in [nil, ""] ->
      false

    "primary" ->
      config :arbiter, role: :primary
      false

    "agent" ->
      config :arbiter, role: :agent
      true

    other ->
      raise "ARB_ROLE must be \"primary\" or \"agent\", got: #{inspect(other)}"
  end

# Single source of truth for the SQLite DB path. Applies to all environments
# (dev, prod) except test, which sets its own tmp path in config/test.exs.
#
# Default: ~/.arbiter/arbiter.sqlite3 (the canonical post-cutover location).
# Until T7 (DB-copy cutover) completes, set DATABASE_PATH to point at the
# live database so the server never boots against an empty file.
if config_env() != :test and not agent? do
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.expand("~/.arbiter/arbiter.sqlite3")

  config :arbiter, Arbiter.Repo,
    database: database_path,
    journal_mode: :wal,
    cache_size: -64_000,
    temp_store: :memory,
    busy_timeout: 5000,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
end

if config_env() == :prod and not agent? do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  # The dashboard's auth model is "a loopback peer is trusted; there is no
  # login" (see ArbiterWeb.Loopback) — bind loopback-only by default
  # (bd-1c4pg3). ARB_BIND_ADDRESS overrides it explicitly; ArbiterWeb.Application
  # logs a WARNING at boot if the result isn't loopback.
  bind_ip =
    case System.get_env("ARB_BIND_ADDRESS") do
      addr when addr in [nil, ""] ->
        {127, 0, 0, 1}

      addr ->
        case :inet.parse_address(String.to_charlist(addr)) do
          {:ok, parsed} -> parsed
          {:error, _} -> raise "ARB_BIND_ADDRESS is not a valid IP address: #{inspect(addr)}"
        end
    end

  config :arbiter_web, ArbiterWeb.Endpoint,
    http: [ip: bind_ip],
    secret_key_base: secret_key_base,
    server: true,
    url: [
      host: System.get_env("PHX_HOST") || "localhost",
      port: String.to_integer(System.get_env("PORT", "4848")),
      scheme: "http"
    ],
    check_origin: false

  config :arbiter, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end

if config_env() == :dev and not agent? do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.

      Generate one with `mix phx.gen.secret` and add it to .arbiter.env:
        SECRET_KEY_BASE=<generated-value>
      """

  config :arbiter_web, ArbiterWeb.Endpoint, secret_key_base: secret_key_base
end
