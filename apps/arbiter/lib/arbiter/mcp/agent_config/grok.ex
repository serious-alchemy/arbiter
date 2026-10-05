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

  Other settings already in the file (e.g. a retry threshold) are kept; any
  earlier `[mcp_servers.<name>]` table, and its sub-tables, is replaced, so the
  write is idempotent across respawns.

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
      existing = if File.exists?(path), do: File.read!(path), else: ""
      name = Keyword.get(opts, :server_name, "arbiter")
      merged = String.trim_trailing(strip_server(existing, name)) <> "\n\n" <> config_toml(opts)

      with :ok <- File.write(path, String.trim_leading(merged)) do
        File.chmod(path, 0o600)
      end
    end
  end

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
    url = #{inspect(url)}
    headers = { "Authorization" = #{inspect("Bearer " <> token)} }
    """
  end

  # Drop `[mcp_servers.<name>]` and `[mcp_servers.<name>.*]` tables, keeping
  # everything else byte-for-byte.
  defp strip_server(text, name) do
    own? = fn line ->
      t = String.trim(line)
      t == "[mcp_servers.#{name}]" or String.starts_with?(t, "[mcp_servers.#{name}.")
    end

    {kept, _skipping} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {acc, skipping} ->
        header? = String.starts_with?(String.trim(line), "[")

        cond do
          header? and own?.(line) -> {acc, true}
          header? -> {[line | acc], false}
          skipping -> {acc, true}
          true -> {[line | acc], false}
        end
      end)

    kept |> Enum.reverse() |> Enum.join("\n")
  end
end
