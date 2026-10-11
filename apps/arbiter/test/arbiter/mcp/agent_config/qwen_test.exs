defmodule Arbiter.MCP.AgentConfig.QwenTest do
  # async: false — the home root is Application env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Qwen.ConfigDir
  alias Arbiter.MCP.AgentConfig
  alias Arbiter.MCP.AgentConfig.Qwen

  @opts [mcp_url: "http://127.0.0.1:4848/mcp", scope_token: "tok-123", server_name: "arbiter"]

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "qwen-mcp-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    wt = Path.join(base, "wt")
    File.mkdir_p!(wt)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok,
     wt: wt, settings: Path.join(ConfigDir.qwen_home(worktree: wt), "settings.json"), base: base}
  end

  test "is registered for the qwen provider" do
    assert AgentConfig.adapter_for("qwen") == Qwen
  end

  test "settings hold only the arbiter server with httpUrl and a Bearer header" do
    assert %{"mcpServers" => servers} = Qwen.settings(@opts)
    assert Map.keys(servers) == ["arbiter"]

    assert servers["arbiter"] == %{
             "httpUrl" => "http://127.0.0.1:4848/mcp",
             "headers" => %{"Authorization" => "Bearer tok-123"}
           }
  end

  test "writes the per-worker QWEN_HOME settings 0600, nothing in the worktree", %{
    wt: wt,
    settings: settings
  } do
    assert :ok = Qwen.write_mcp_config(wt, @opts)
    assert %{"mcpServers" => %{"arbiter" => _}} = Jason.decode!(File.read!(settings))
    assert File.ls!(wt) == []
    assert Bitwise.band(File.stat!(settings).mode, 0o077) == 0
  end

  test "a repo .mcp.json server is excluded by the allow-list flags, not spawned", %{base: base} do
    flags = Qwen.flags()
    assert ["--allowed-mcp-server-names", "arbiter"] = Enum.take(flags, 2)
    assert ["--allowed-tools", "mcp__arbiter"] = Enum.drop(flags, 2)

    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "qwen"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin, "qwen"), 0o755)
    old_path = System.get_env("PATH")
    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", old_path) end)

    {:ok, argv} = Arbiter.Agents.Qwen.default_argv("hi", [])

    assert Enum.join(argv, " ") =~
             "--allowed-mcp-server-names arbiter --allowed-tools mcp__arbiter"
  end

  test "regenerates idempotently, dropping planted servers", %{wt: wt, settings: settings} do
    File.mkdir_p!(Path.dirname(settings))
    File.write!(settings, ~s({"mcpServers": {"evil": {"command": "x"}}}))

    assert :ok = Qwen.write_mcp_config(wt, @opts)
    assert :ok = Qwen.write_mcp_config(wt, @opts)
    refute File.read!(settings) =~ "evil"
  end

  test "a planted symlink is replaced, never followed", %{wt: wt, settings: settings, base: base} do
    target = Path.join(base, "operator.json")
    File.write!(target, "{}")
    File.mkdir_p!(Path.dirname(settings))
    File.ln_s!(target, settings)

    assert :ok = Qwen.write_mcp_config(wt, @opts)
    assert File.read!(target) == "{}"
    assert {:ok, %{type: :regular}} = File.lstat(settings)
  end
end
