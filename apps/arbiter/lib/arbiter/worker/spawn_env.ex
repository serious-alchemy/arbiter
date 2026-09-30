defmodule Arbiter.Worker.SpawnEnv do
  @moduledoc """
  The one place a worker/agent child process's environment is decided
  (bd-7r0qrj, GitHub #143).

  ## Why

  `Port.open`'s `{:env, pairs}` and `System.cmd/3`'s `:env` **extend** the BEAM's
  own OS environment. The server's environment holds its master secrets
  (`ARBITER_CLOAK_KEY`, `SECRET_KEY_BASE`, `DATABASE_PATH`, everything in
  `~/.arbiter/arbiter.env`) and operator session handles (`SSH_AUTH_SOCK`,
  `DBUS_SESSION_BUS_ADDRESS`), so an inherit-and-denylist scheme handed every
  one of them to every worker. This module inverts it: the child starts from an
  empty environment and receives **only**

    1. the allowlisted names in `@exact` (below), copied from the server's env,
    2. the `extras` the caller explicitly builds — the adapter's `spawn_env/1`
       (its own provider's credential, isolated `HOME`/`CLAUDE_CONFIG_DIR`),
       the workspace's user-defined `worker_env`, the task-scoped dev-server
       overrides and `ARB_WORKER_BEAD_ID`.

  Because the OS API can only extend, "empty" is implemented by emitting an
  explicit unset (`{name, false}` for a Port, `{name, nil}` for `System.cmd/3`)
  for every inherited name that is not allowlisted.

  ## Credentials

  A worker receives only its own provider's credential. `port_env/2` /
  `cmd_env/2` drop any *other* provider's credential var from `extras` — so an
  agy worker can never get `CLAUDE_CODE_OAUTH_TOKEN` even when its workspace is
  linked to a Claude account as well (`Arbiter.Worker.WorkerEnv` resolves every
  linked account). A `nil` provider is treated as `"claude"`, the historical
  default of the bare `ClaudeSession.start/1` callers.

  ## Deliberate omissions and exceptions

    * `SSH_AUTH_SOCK` — dropped. git over ssh must use a key file in `~/.ssh`
      (same-UID readable, see `docs/worker-security.md`) or https + a
      `GH_TOKEN`/`GITLAB_TOKEN` from the workspace's `worker_env`. A workspace
      that really needs the agent can set `SSH_AUTH_SOCK` in its `worker_env`.
    * `DBUS_SESSION_BUS_ADDRESS` — dropped, **except** for the `gemini` (agy)
      provider when the session bus socket exists: agy keeps its own Google
      grant in the freedesktop Secret Service, so without the bus a keyring
      host's agy worker is unauthenticated
      (`Arbiter.Agents.Gemini.ConfigDir.keyring_available?/0`).
    * `MIX_ENV` — not inherited; the server's own `MIX_ENV` (often `prod`) must
      not steer a worktree's `mix test`.
    * `DATABASE_PATH` / `PORT` — never the server's. `Arbiter.Worker.DevServerEnv`
      supplies task-scoped throwaway values through `extras` so a worker-started
      dev server cannot touch the live database or port.
  """

  alias Arbiter.Agents.Gemini.ConfigDir, as: GeminiConfigDir
  alias Arbiter.Worker.ReleaseEnv

  # Why each entry is here: a worker runs real toolchains (`mise`-shimmed
  # erlang/elixir/node, git, gh/glab, the agent CLI itself), so it needs a PATH
  # and HOME, a locale/terminal, temp and cache roots, the tool-home overrides,
  # CA/proxy settings for TLS and egress, and the two `arb` CLI endpoints. None
  # of these can unlock another credential by itself.
  @exact MapSet.new(~w(
    PATH HOME USER LOGNAME SHELL
    LANG LANGUAGE TERM COLORTERM NO_COLOR TZ
    TMPDIR TEMP TMP
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
    XDG_CONFIG_DIRS XDG_DATA_DIRS
    MIX_HOME MIX_ARCHIVES HEX_HOME HEX_MIRROR REBAR_CACHE_DIR ERL_AFLAGS
    ELIXIR_ERL_OPTIONS
    MISE_DATA_DIR MISE_CONFIG_DIR MISE_CACHE_DIR MISE_STATE_DIR
    MISE_TRUSTED_CONFIG_PATHS ASDF_DATA_DIR
    CARGO_HOME RUSTUP_HOME GOPATH GOROOT GOMODCACHE NPM_CONFIG_CACHE
    GH_CONFIG_DIR GLAB_CONFIG_DIR GH_HOST
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
    SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE REQUESTS_CA_BUNDLE
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
    http_proxy https_proxy all_proxy no_proxy
    ARB_HOST ARB_WORKSPACE
  ))

  @prefixes ["LC_"]

  # Every provider-credential var Arbiter knows, grouped by the provider whose
  # worker may hold it. `Arbiter.Accounts.Census.credential_keys/0` covers the
  # account-managed subset; the Gemini adapter's API-key names are not in it.
  @own_credentials %{
    "claude" => ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY),
    "codex" => ~w(OPENAI_API_KEY CODEX_API_KEY),
    "gemini" => ~w(GEMINI_API_KEY GOOGLE_GENAI_API_KEY ANTIGRAVITY_API_KEY)
  }
  @all_credentials @own_credentials |> Map.values() |> List.flatten() |> MapSet.new()

  @type pair :: {String.t(), String.t() | false}

  @doc "Whether `name` is copied from the server's environment into a worker's."
  @spec allowed?(String.t()) :: boolean()
  def allowed?(name) when is_binary(name) do
    MapSet.member?(@exact, name) or Enum.any?(@prefixes, &String.starts_with?(name, &1))
  end

  @doc """
  Env pairs for `Port.open`'s `{:env, …}`: unset every non-allowlisted inherited
  var, apply the release cleanup, then `extras` (minus other providers'
  credentials), which win on a name collision.
  """
  @spec port_env([pair()], String.t() | atom() | nil) :: [pair()]
  def port_env(extras, provider) when is_list(extras) do
    provider = normalize_provider(provider)

    (unset_pairs(provider) ++ drop_foreign_credentials(extras, provider))
    |> ReleaseEnv.port_env()
    |> dedupe()
  end

  @doc "`port_env/2` translated to `System.cmd/3`'s `nil`-means-unset convention."
  @spec cmd_env([pair()], String.t() | atom() | nil) :: [{String.t(), String.t() | nil}]
  def cmd_env(extras, provider) when is_list(extras) do
    extras
    |> port_env(provider)
    |> Enum.map(fn
      {name, false} -> {name, nil}
      pair -> pair
    end)
  end

  @doc """
  Drops every credential var belonging to a provider other than `provider` from
  `pairs`. Non-credential pairs pass through.
  """
  @spec drop_foreign_credentials([pair()], String.t() | atom() | nil) :: [pair()]
  def drop_foreign_credentials(pairs, provider) do
    own = provider |> normalize_provider() |> then(&Map.get(@own_credentials, &1, []))

    Enum.reject(pairs, fn {name, _} ->
      MapSet.member?(@all_credentials, name) and name not in own
    end)
  end

  defp unset_pairs(provider) do
    System.get_env()
    |> Map.keys()
    |> Enum.reject(&(allowed?(&1) or &1 in bus_names(provider)))
    |> Enum.sort()
    |> Enum.map(&{&1, false})
  end

  # agy's keyring exception — see the moduledoc.
  defp bus_names("gemini"), do: if(bus_reachable?(), do: ["DBUS_SESSION_BUS_ADDRESS"], else: [])
  defp bus_names(_), do: []

  defp bus_reachable?, do: GeminiConfigDir.keyring_available?()

  defp normalize_provider(nil), do: "claude"
  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(provider) when is_binary(provider), do: provider

  # Last write wins, but keep first-seen order so the list stays readable.
  defp dedupe(pairs) do
    last = Map.new(pairs)

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.fetch!(last, &1)})
  end
end
