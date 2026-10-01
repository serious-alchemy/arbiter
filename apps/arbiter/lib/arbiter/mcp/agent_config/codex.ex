defmodule Arbiter.MCP.AgentConfig.Codex do
  @moduledoc """
  OpenAI Codex CLI's `Arbiter.MCP.AgentConfig` adapter (Phase 3).

  Writes a per-spawn `.codex/config.toml` into the worker's worktree,
  declaring the Arbiter MCP server as a remote HTTP server with the spawn's
  scope token in a bearer header. The token can be provided in two ways:

  1. **Inline in config.toml** (default):
      [mcp_servers.arbiter]
      url = "http://127.0.0.1:4848/mcp"

      [mcp_servers.arbiter.http_headers]
      Authorization = "Bearer <scope-token>"

  2. **Via environment variable** (if `bearer_token_env_var` is specified):
      [mcp_servers.arbiter]
      url = "http://127.0.0.1:4848/mcp"

      [mcp_servers.arbiter.http_headers]
      Authorization = "${ARBITER_MCP_TOKEN}"

  The environment variable approach keeps the token off disk. Callers that
  choose this route should set the env var in the spawn's environment before
  Codex reads the config.

  ## Post-spawn connect check

  Codex MCP support is newer than Claude's or Gemini's and has reports of
  **silent connect failures** — Codex starts without error but never actually
  connects to the MCP server. Callers should invoke `verify_connection/1`
  *after* the Codex session is started to confirm the MCP endpoint responds
  to the spawn's token before treating the session as operational.

  `verify_connection/1` sends a minimal MCP `initialize` call to the endpoint
  and returns `:ok` on a successful `200` response, or `{:error, reason}` if
  the endpoint is unreachable, returns an unexpected status, or replies with
  `401 Unauthorized` (indicating a bad / expired token).

  ## Worker-side verification

  After Codex is spawned, call `verify_config_loaded/2` with the output of
  `codex mcp list --json` to confirm the configuration was actually loaded.
  This catches regressions where the config key (e.g., `http_headers` vs
  `headers`) is silently ignored.
  """

  @behaviour Arbiter.MCP.AgentConfig

  @dirname ".codex"
  @filename "config.toml"
  @connect_timeout_ms 5_000

  @impl true
  def write_mcp_config(worktree, opts) when is_binary(worktree) do
    dir = Path.join(worktree, @dirname)

    with :ok <- File.mkdir_p(dir) do
      File.write(Path.join(dir, @filename), config_toml(opts))
    end
  end

  @doc """
  The `.codex/config.toml` content as a string. Exposed for tests /
  inspection.

  Requires `:mcp_url` and `:scope_token`. Optional:
  - `:server_name` — defaults to `"arbiter"`.
  - `:bearer_token_env_var` — if set, uses an environment variable name
    instead of embedding the token inline. E.g., `bearer_token_env_var: "ARBITER_MCP_TOKEN"`
    will write `Authorization = "${ARBITER_MCP_TOKEN}"` instead of the token value.
    Callers must set this env var in the spawn's environment.
  """
  @spec config_toml(keyword()) :: String.t()
  def config_toml(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)
    name = Keyword.get(opts, :server_name, "arbiter")
    env_var = Keyword.get(opts, :bearer_token_env_var)

    auth_value =
      if env_var do
        # Use environment variable placeholder
        "${#{env_var}}"
      else
        # Use inline token (default)
        "Bearer " <> token
      end

    """
    [mcp_servers.#{name}]
    url = #{inspect(url)}

    [mcp_servers.#{name}.http_headers]
    Authorization = #{inspect(auth_value)}
    """
  end

  @doc """
  Verify that the MCP server is reachable and the spawn's scope token is
  accepted. Should be called *after* the Codex session is started.

  Sends a minimal MCP `initialize` JSON-RPC call to `:mcp_url` with the
  bearer token from `:scope_token`. Returns `:ok` on a `200` response,
  `{:error, :unauthorized}` on `401`, or `{:error, reason}` for other
  failures.

  This check exists because Codex MCP support has reports of silent connect
  failures — it starts without error but never connects. A `200` here
  confirms the channel is open.

  ## Limitations

  This function tests the MCP endpoint from the coordinator's perspective
  with the spawn token. It cannot detect whether Codex actually loaded the
  `http_headers` from the generated `config.toml` — that requires running
  `codex mcp list --json` from the worker's context to inspect the loaded
  configuration. See bd-6mo6be for the full context: `headers` (old) vs
  `http_headers` (current, correct) is silently dropped if written to the
  wrong key, so end-to-end verification on the worker side is critical
  for catching config regressions.
  """
  @spec verify_connection(keyword()) :: :ok | {:error, term()}
  def verify_connection(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)

    req =
      Req.new(
        url: url,
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/json"}
        ],
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "arbiter-codex-probe", "version" => "0.0.1"}
          }
        },
        receive_timeout: @connect_timeout_ms
      )

    case Req.post(req) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: 401}} -> {:error, :unauthorized}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  @doc "The config directory name written into the worktree (`.codex`)."
  @spec dirname() :: String.t()
  def dirname, do: @dirname

  @doc "The config filename within the `.codex` directory (`config.toml`)."
  @spec filename() :: String.t()
  def filename, do: @filename

  @doc """
  Verify that Codex loaded the MCP config by inspecting `codex mcp list --json` output.

  This is a **worker-side check** that runs in the spawned Codex process context.
  It parses the JSON output from `codex mcp list --json` and verifies that
  the `http_headers` with Authorization is present for the arbiter server.

  Returns `:ok` if the config was loaded correctly, `{:error, reason}` otherwise.

  ## Why this is needed

  Codex has reports of silent config failures: it starts without error but the
  MCP config may not be loaded (or loaded incorrectly). The `verify_connection/1`
  function tests the endpoint from the coordinator's perspective and cannot detect
  whether the *worker's* loaded config contains the Authorization header.

  This function catches the G3 gap regression: if code accidentally writes `headers`
  instead of `http_headers`, the token would be silently dropped on the worker side
  and every MCP call would get a 401 Unauthorized.

  ## Example

  From the worker's context, after Codex is spawned:

      $ codex mcp list --json > /tmp/codex-mcp-list.json
      $ Arbiter.MCP.AgentConfig.Codex.verify_config_loaded("/path/to/worktree", Jason.decode!(File.read!(...)))
      :ok
  """
  @spec verify_config_loaded(String.t(), map()) :: :ok | {:error, atom()}
  def verify_config_loaded(worktree, codex_mcp_list_json) when is_binary(worktree) and is_map(codex_mcp_list_json) do
    case get_in(codex_mcp_list_json, ["mcp_servers", "arbiter", "http_headers", "Authorization"]) do
      nil -> {:error, :http_headers_missing}
      "" -> {:error, :authorization_header_empty}
      _auth_header -> :ok
    end
  end

  @doc "Patterns to add to `.git/info/exclude` so `git add -A` never stages this directory."
  @spec gitignore_paths() :: [String.t()]
  def gitignore_paths, do: [@dirname <> "/"]
end
