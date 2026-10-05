defmodule Arbiter.MCP.AgentConfig.GrokTest do
  # async: false — the home root is Application env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Grok.ConfigDir
  alias Arbiter.MCP.AgentConfig
  alias Arbiter.MCP.AgentConfig.Grok

  @opts [mcp_url: "http://127.0.0.1:4848/mcp", scope_token: "tok-123", server_name: "arbiter"]

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "grok-mcp-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    prev = Application.get_env(:arbiter, :worker_grok_home_root)
    Application.put_env(:arbiter, :worker_grok_home_root, Path.join(base, "homes"))

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :worker_grok_home_root, prev),
        else: Application.delete_env(:arbiter, :worker_grok_home_root)

      File.rm_rf!(base)
    end)

    wt = Path.join(base, "wt")
    File.mkdir_p!(wt)
    {:ok, wt: wt, config: Path.join(ConfigDir.grok_home(worktree: wt), "config.toml")}
  end

  test "is registered for the grok provider" do
    assert AgentConfig.adapter_for("grok") == Grok
  end

  test "config_toml/1 uses grok's url + headers inline table" do
    toml = Grok.config_toml(@opts)
    assert toml =~ "[mcp_servers.arbiter]"
    assert toml =~ ~s(url = "http://127.0.0.1:4848/mcp")
    assert toml =~ ~s(headers = { "Authorization" = "Bearer tok-123" })
  end

  test "writes the per-worker GROK_HOME config, nothing in the worktree", %{
    wt: wt,
    config: config
  } do
    assert :ok = Grok.write_mcp_config(wt, @opts)
    assert File.read!(config) =~ "Bearer tok-123"
    assert File.ls!(wt) == []
    assert Bitwise.band(File.stat!(config).mode, 0o077) == 0
  end

  test "never touches the operator's ~/.grok", %{wt: wt} do
    refute String.starts_with?(
             ConfigDir.grok_home(worktree: wt),
             Path.join(System.user_home!(), ".grok")
           )
  end

  test "preserves other settings and replaces a stale arbiter block", %{wt: wt, config: config} do
    File.mkdir_p!(Path.dirname(config))

    File.write!(config, """
    rate_limit_retry_threshold = 2

    [mcp_servers.arbiter]
    url = "http://old"

    [mcp_servers.arbiter.extra]
    x = 1

    [mcp_servers.other]
    url = "http://other"
    """)

    assert :ok = Grok.write_mcp_config(wt, @opts)
    assert :ok = Grok.write_mcp_config(wt, @opts)
    out = File.read!(config)

    assert out =~ "rate_limit_retry_threshold = 2"
    assert out =~ "[mcp_servers.other]"
    refute out =~ "http://old"
    refute out =~ "extra"
    assert length(String.split(out, "[mcp_servers.arbiter]")) == 2
  end
end
