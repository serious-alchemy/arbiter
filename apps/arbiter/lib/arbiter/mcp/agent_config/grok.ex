defmodule Arbiter.MCP.AgentConfig.Grok do
  @moduledoc """
  The `Arbiter.MCP.AgentConfig` adapter for the grok CLI (bd-bggx6a).

  grok has no per-invocation `--mcp-config` flag in `-p` mode, so MCP servers
  come from `[mcp_servers.<name>]` in `$GROK_HOME/config.toml`. The writer puts
  that table into the spawn's own `GROK_HOME` (`Arbiter.Agents.Grok.ConfigDir`,
  keyed on the same worktree), never the operator's `~/.grok` and never the
  worktree — so the scope token cannot be swept into a commit. The file is
  `0600`.

  Remote servers use grok's `url` + `headers` inline table:

      [mcp_servers.arbiter]
      url = "http://127.0.0.1:4848/mcp"
      headers = { "Authorization" = "Bearer <scope-token>" }

  The file is regenerated from known keys on every write (Arbiter owns this
  per-worker home, and the jailed worker can write free-form content into it, so
  nothing is merged). Anything already at the path — including a symlink the
  worker planted — is removed, never followed, and the fresh file is created
  `0600` before the token goes in.

  grok namespaces MCP tools by server name, and `MCPTool(...)` allow/deny rules
  apply to them; the server enforces the worker's capability from the token.
  """

  @behaviour Arbiter.MCP.AgentConfig

  alias Arbiter.Agents.Grok.ConfigDir

  @filename "config.toml"

  @impl true
  def write_mcp_config(worktree, opts) when is_binary(worktree) do
    with {:ok, _home} <- ConfigDir.ensure(worktree: worktree) do
      path = Path.join(ConfigDir.grok_home(worktree: worktree), @filename)

      # rm (not follow) whatever is there: a symlink to a host file must stay
      # untouched, and the new file must be 0600 before the token lands in it.
      with :ok <- remove_existing(path),
           :ok <- File.write(path, ""),
           :ok <- File.chmod(path, 0o600) do
        File.write(path, config_toml(opts))
      end
    end
  end

  defp remove_existing(path) do
    case File.lstat(path) do
      {:ok, _} -> File.rm_rf(path) |> rm_result()
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rm_result({:ok, _}), do: :ok
  defp rm_result({:error, reason, _}), do: {:error, reason}

  @doc """
  The `[mcp_servers.<name>]` table as a string. Requires `:mcp_url` and
  `:scope_token`; `:server_name` defaults to `"arbiter"`.
  """
  @spec config_toml(keyword()) :: String.t()
  def config_toml(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)
    name = Keyword.get(opts, :server_name, "arbiter")

    """
    [mcp_servers.#{name}]
    url = #{toml_string(url)}
    headers = { "Authorization" = #{toml_string("Bearer " <> token)} }
    """
  end

  # TOML basic string: escape backslash, quote and control characters.
  defp toml_string(value) do
    escaped =
      for <<c <- value>>, into: "" do
        case c do
          ?\\ ->
            "\\\\"

          ?" ->
            "\\\""

          ?\n ->
            "\\n"

          ?\r ->
            "\\r"

          ?\t ->
            "\\t"

          c when c < 0x20 or c == 0x7F ->
            "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")

          c ->
            <<c>>
        end
      end

    ~s("#{escaped}")
  end
end
