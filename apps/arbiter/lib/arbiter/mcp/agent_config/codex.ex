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

  2. **Via environment variable** (if `bearer_token_env_var` is specified;
     what Arbiter's dispatch uses, so the token stays off disk):
      [mcp_servers.arbiter]
      url = "http://127.0.0.1:4848/mcp"
      bearer_token_env_var = "ARBITER_MCP_TOKEN"

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

  `check_worker_config/2` runs `codex mcp list --json` in the worktree with
  the spawn's env and feeds the decoded array to `verify_config_loaded/2`.
  This catches a config key that Codex silently ignores (`headers` vs
  `http_headers`), a project config Codex did not load (untrusted project),
  and an unset `bearer_token_env_var` (Codex reports
  `auth_status: "bearer_token"` even then, so the env is checked directly).
  """

  @behaviour Arbiter.MCP.AgentConfig

  alias Arbiter.Worker.ReleaseEnv

  @dirname ".codex"
  @filename "config.toml"
  @connect_timeout_ms 5_000
  @mcp_list_timeout_ms 15_000

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

  Requires `:mcp_url`, plus `:scope_token` unless `:bearer_token_env_var` is
  given. Optional:
  - `:server_name` — defaults to `"arbiter"`.
  - `:bearer_token_env_var` — if set, uses Codex's env-var expansion
    instead of embedding the token inline. E.g., `bearer_token_env_var: "ARBITER_MCP_TOKEN"`
    will write `bearer_token_env_var = "ARBITER_MCP_TOKEN"` (Codex expands it at runtime).
    Callers must set this env var in the spawn's environment. This keeps the token off disk.
  """
  @spec config_toml(keyword()) :: String.t()
  def config_toml(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    name = Keyword.get(opts, :server_name, "arbiter")
    env_var = Keyword.get(opts, :bearer_token_env_var)

    if env_var do
      # Use bearer_token_env_var for env-based token expansion (Codex expands at runtime).
      # This keeps the token off disk.
      """
      [mcp_servers.#{name}]
      url = #{inspect(url)}
      tool_timeout_sec = #{Arbiter.MCP.tool_timeout_sec()}
      bearer_token_env_var = #{inspect(env_var)}
      """
    else
      # Use inline token in http_headers (default, for backward compat).
      token = Keyword.fetch!(opts, :scope_token)

      """
      [mcp_servers.#{name}]
      url = #{inspect(url)}
      tool_timeout_sec = #{Arbiter.MCP.tool_timeout_sec()}

      [mcp_servers.#{name}.http_headers]
      Authorization = #{inspect("Bearer " <> token)}
      """
    end
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
  Check decoded `codex mcp list --json` output (a JSON array of servers, each
  with a `"transport"` map) for the named server's authentication.

  Returns `:ok` when `transport.bearer_token_env_var` or a non-empty
  `transport.http_headers.Authorization` is present.
  """
  @spec verify_config_loaded(list(), keyword()) :: :ok | {:error, atom()}
  def verify_config_loaded(servers, opts \\ []) when is_list(servers) do
    server_name = Keyword.get(opts, :server_name, "arbiter")

    case Enum.find(servers, &(is_map(&1) and &1["name"] == server_name)) do
      nil ->
        {:error, :server_not_configured}

      server ->
        transport_auth(server["transport"] || %{})
    end
  end

  defp transport_auth(%{"bearer_token_env_var" => var}) when is_binary(var), do: :ok

  defp transport_auth(%{"http_headers" => %{} = headers}) do
    case headers["Authorization"] do
      auth when is_binary(auth) and auth != "" -> :ok
      _ -> {:error, :authorization_header_empty}
    end
  end

  defp transport_auth(_transport), do: {:error, :no_authentication_configured}

  @doc """
  Run `codex mcp list --json` from the worker's point of view (`:cwd` = the
  worktree, `:env` = the spawn env) and verify the loaded config.

  When the config uses `bearer_token_env_var`, also confirms that variable is
  non-empty in `:env`. Options: `:cwd`, `:env` (list of `{name, value}`),
  `:server_name`, `:cli_args` (global `-c` overrides, as the spawn passes
  them), `:executable` (defaults to `codex` on PATH), and `:timeout_ms`
  (defaults to #{@mcp_list_timeout_ms}).
  """
  @spec check_worker_config(String.t(), keyword()) :: :ok | {:error, term()}
  def check_worker_config(worktree, opts) do
    env = Keyword.get(opts, :env, [])
    exe = Keyword.get(opts, :executable) || System.find_executable("codex")
    timeout_ms = Keyword.get(opts, :timeout_ms, @mcp_list_timeout_ms)

    with exe when is_binary(exe) <- exe || {:error, :codex_not_found},
         {out, 0} <-
           mcp_list(
             exe,
             Keyword.get(opts, :cli_args, []) ++ ["mcp", "list", "--json"],
             worktree,
             env,
             timeout_ms
           ),
         {:ok, servers} when is_list(servers) <- Jason.decode(out),
         :ok <- verify_config_loaded(servers, opts) do
      check_env_var_set(servers, env, Keyword.get(opts, :server_name, "arbiter"))
    else
      {:error, _} = err ->
        err

      {_out, status} when status in [124, 137] ->
        {:error, {:codex_mcp_list_timed_out, timeout_ms}}

      {_out, status} when is_integer(status) ->
        {:error, {:codex_mcp_list_failed, status}}

      other ->
        {:error, {:unexpected_mcp_list_output, other}}
    end
  end

  # `Task.shutdown/2` only stops Erlang from waiting on System.cmd/3; it does
  # not reliably terminate the CLI process. GNU timeout kills the actual CLI
  # when the deadline expires, including a SIGKILL fallback for ignored TERM.
  defp mcp_list(exe, args, worktree, env, timeout_ms) do
    ReleaseEnv.cmd(
      "timeout",
      ["--kill-after=1s", "#{timeout_ms / 1_000}s", exe | args],
      cd: worktree,
      env: env,
      stderr_to_stdout: false
    )
  end

  defp check_env_var_set(servers, env, server_name) do
    var =
      servers
      |> Enum.find(&(&1["name"] == server_name))
      |> get_in(["transport", "bearer_token_env_var"])

    case var && List.keyfind(env, var, 0) do
      nil when is_nil(var) -> :ok
      {_, v} when is_binary(v) and v != "" -> :ok
      _ -> {:error, {:bearer_token_env_var_unset, var}}
    end
  end

  @doc "Patterns to add to `.git/info/exclude` so `git add -A` never stages this directory."
  @spec gitignore_paths() :: [String.t()]
  def gitignore_paths, do: [@dirname <> "/"]
end
