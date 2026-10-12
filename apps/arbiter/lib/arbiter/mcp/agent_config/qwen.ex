defmodule Arbiter.MCP.AgentConfig.Qwen do
  @moduledoc """
  The `Arbiter.MCP.AgentConfig` adapter for the qwen CLI (bd-a2cnea).

  qwen reads `mcpServers` from `settings.json`. The writer puts the table into
  the spawn's own `$QWEN_HOME/settings.json` (`Arbiter.Agents.Qwen.ConfigDir`,
  keyed on the same worktree), never the operator's `~/.qwen` and never the
  worktree — so the scope token cannot be swept into a commit. The file is
  `0600`.

  Remote servers use qwen's `httpUrl` + `headers`:

      {"mcpServers": {"arbiter": {
        "httpUrl": "http://127.0.0.1:4848/mcp",
        "headers": {"Authorization": "Bearer <scope-token>"}}}}

  The file holds only the arbiter server and is regenerated from known keys on
  every write; whatever is at the path (including a planted symlink) is removed,
  never followed. A repo `.mcp.json` server is kept from spawning by the argv
  flags `flags/0` (`--allowed-mcp-server-names arbiter`, `--allowed-tools
  mcp__arbiter`), which `Arbiter.Agents.Qwen` appends to every spawn.
  """

  @behaviour Arbiter.MCP.AgentConfig

  alias Arbiter.Agents.Qwen.ConfigDir

  @filename "settings.json"
  @server "arbiter"

  @doc "The argv flags that restrict qwen to the arbiter MCP server."
  @spec flags() :: [String.t()]
  def flags,
    do: ["--allowed-mcp-server-names", @server, "--allowed-tools", "mcp__" <> @server]

  @impl true
  def write_mcp_config(worktree, opts) when is_binary(worktree) do
    with {:ok, _home} <- ConfigDir.ensure(worktree: worktree) do
      path = Path.join(ConfigDir.qwen_home(worktree: worktree), @filename)

      with :ok <- remove_existing(path),
           :ok <- File.write(path, ""),
           :ok <- File.chmod(path, 0o600) do
        File.write(path, settings_json(opts))
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
  The settings map. Requires `:mcp_url` and `:scope_token`; `:server_name`
  defaults to `"arbiter"`.
  """
  @spec settings(keyword()) :: map()
  def settings(opts) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)
    name = Keyword.get(opts, :server_name, @server)

    %{
      "mcpServers" => %{
        name => %{"httpUrl" => url, "headers" => %{"Authorization" => "Bearer " <> token}}
      }
    }
  end

  @doc "The settings as pretty JSON."
  @spec settings_json(keyword()) :: String.t()
  def settings_json(opts), do: Jason.encode!(settings(opts), pretty: true)
end
