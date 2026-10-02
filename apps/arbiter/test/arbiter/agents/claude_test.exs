defmodule Arbiter.Agents.ClaudeTest do
  use ExUnit.Case, async: false

  # No Ecto sandbox here, so ConfigDir's workspace-less read of the
  # install-wide account credential can't reach the database and degrades to
  # "no credential". Capture any log so the run stays readable (logs still
  # surface on failure).
  @moduletag :capture_log

  alias Arbiter.Agents.Claude

  describe "behaviour" do
    test "module declares the Agent behaviour" do
      behaviours =
        Claude.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
    end

    test "provider/0 returns \"claude\"" do
      assert Claude.provider() == "claude"
    end

    test "done_sentinel/0 matches `arb done`" do
      assert Regex.match?(Claude.done_sentinel(), "work finished\narb done")
      refute Regex.match?(Claude.done_sentinel(), "I am done — arb done")
      refute Regex.match?(Claude.done_sentinel(), "arb doneness")
    end
  end

  describe "write_confinement/1 (bd-1abj7u)" do
    test "always :permission_layer regardless of mode" do
      base = Arbiter.Agents.SecurityPolicy.base()
      assert Claude.write_confinement(base) == :permission_layer

      strict = %{base | permissions: %{base.permissions | mode: :strict}}
      assert Claude.write_confinement(strict) == :permission_layer
    end
  end

  describe "default_argv/2 with a stubbed claude binary" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-claude-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      stub = Path.join(tmp, "claude")
      File.write!(stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(stub, 0o755)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{tmp}:#{old_path}")

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, stub: stub, old_path: old_path, tmp: tmp}
    end

    test "returns {:error, ...} when the `claude` CLI isn't on PATH", %{
      old_path: old_path,
      tmp: tmp
    } do
      # Inside this test, drop our stub dir from PATH so resolution fails,
      # then restore the stubbed PATH so subsequent tests see the stub.
      stubbed_path = "#{tmp}:#{old_path}"
      System.put_env("PATH", "/nonexistent-dir-for-test")

      try do
        assert {:error, {:executable_not_found, "claude"}} = Claude.default_argv("hello", [])
      after
        System.put_env("PATH", stubbed_path)
      end
    end

    test "produces a streaming-json argv wrapped in sh", %{stub: stub} do
      assert {:ok, argv} = Claude.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--output-format" in rest
      assert "stream-json" in rest
      assert "--verbose" in rest
      refute "--model" in rest
    end

    test "passes through `:model` opt as `--model <name>`", %{stub: stub} do
      assert {:ok, argv} = Claude.default_argv("the prompt", model: "opus")
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "opus" in rest
    end

    test "falls back to the active per-process model when no opt given", %{stub: stub} do
      Claude.Config.put_active(%{"model" => "haiku"})

      on_exit(fn -> Claude.Config.clear() end)

      assert {:ok, argv} = Claude.default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "haiku" in rest
    end

    test "resolves :model_tier to a concrete model via the default tier map", %{stub: stub} do
      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "premium")
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "opus" in rest

      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "standard")
      assert "sonnet" in argv

      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "economy")
      assert "haiku" in argv
    end

    test ":model wins over :model_tier when both are set", %{stub: stub} do
      assert {:ok, argv} =
               Claude.default_argv("the prompt", model: "opus", model_tier: "economy")

      assert ["sh", "-c", _exec, "sh", ^stub, "--print", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "opus" in rest
      refute "haiku" in argv
    end

    test ":model_tier can be overridden per-workspace via tier_models config" do
      Claude.Config.put_active(%{
        "tier_models" => %{"premium" => "opus-custom"}
      })

      on_exit(fn -> Claude.Config.clear() end)

      assert {:ok, argv} = Claude.default_argv("the prompt", model_tier: "premium")
      assert "opus-custom" in argv
      refute "opus" in argv
    end

    test ":thinking emits --effort for every level on the ladder", %{stub: _stub} do
      # #1519: the ladder is low < medium < high < xhigh < max. `xhigh`/`max`
      # used to be absent from the built-in map, so an unrecognised level
      # silently emitted NO effort flag at all — a D4 routed to "max" would
      # have got less reasoning than a D3 routed to "high".
      for level <- ["low", "medium", "high", "xhigh", "max"] do
        {:ok, argv} = Claude.default_argv("the prompt", thinking: level)
        assert "--effort" in argv, "no --effort for thinking level #{level}"
        assert level in argv, "--effort value missing for thinking level #{level}"
      end
    end

    test ":thinking 'none' / nil emits no effort flag" do
      {:ok, argv1} = Claude.default_argv("the prompt", thinking: "none")
      refute "--effort" in argv1

      {:ok, argv2} = Claude.default_argv("the prompt", thinking: nil)
      refute "--effort" in argv2
    end

    test ":thinking argv can be overridden per-workspace via thinking_argv config" do
      Claude.Config.put_active(%{
        "thinking_argv" => %{"high" => ["--max-thinking-tokens", "16384"]}
      })

      on_exit(fn -> Claude.Config.clear() end)

      {:ok, argv} = Claude.default_argv("the prompt", thinking: "high")
      assert "--max-thinking-tokens" in argv
      assert "16384" in argv
      refute "--effort" in argv
    end

    test "bakes in the install-default security posture when no :security opt given" do
      assert {:ok, argv} = Claude.default_argv("the prompt", [])
      # safe-by-default: bypass mode (headless-safe) + --settings deny document.
      assert "--dangerously-skip-permissions" in argv
      assert "--settings" in argv
      refute "--permission-mode" in argv

      json = settings_json(argv)
      deny = get_in(json, ["permissions", "deny"])
      assert is_list(deny) and deny != []
      assert Enum.any?(deny, &(&1 =~ "rm -rf"))
    end

    test "honors a threaded :security policy (strict + custom deny)" do
      policy =
        Arbiter.Agents.SecurityPolicy.merge(Arbiter.Agents.SecurityPolicy.base(), %{
          "permissions" => %{"mode" => "strict", "deny" => ["Bash(docker:*)"]}
        })

      assert {:ok, argv} = Claude.default_argv("the prompt", security: policy)
      assert "--permission-mode" in argv
      assert "default" in argv
      assert "Bash(docker:*)" in settings_json(argv)["permissions"]["deny"]
    end

    # bd-btcdrf: Claude has no jail wrap point yet, but a backend with no
    # implementation must refuse the spawn instead of running it unconfined.
    test "backend: podman refuses the spawn in every mode, never an unjailed argv" do
      for mode <- ["strict", "auto", "bypass"] do
        policy =
          Arbiter.Agents.SecurityPolicy.merge(Arbiter.Agents.SecurityPolicy.base(), %{
            "permissions" => %{"mode" => mode},
            "sandbox" => %{"backend" => "podman"}
          })

        assert {:error, {:sandbox_backend_unavailable, :podman, message}} =
                 Claude.default_argv("the prompt", security: policy)

        assert message =~ "podman"
      end
    end

    test "bypass mode emits --dangerously-skip-permissions with --settings deny list" do
      policy =
        Arbiter.Agents.SecurityPolicy.merge(Arbiter.Agents.SecurityPolicy.base(), %{
          "permissions" => %{"mode" => "bypass"}
        })

      assert {:ok, argv} = Claude.default_argv("the prompt", security: policy)
      assert "--dangerously-skip-permissions" in argv
      assert "--settings" in argv
      refute "--permission-mode" in argv
    end

    # -- bd-7e8ezw: the injected MCP config is passed explicitly ------------
    #
    # Claude Code applies the MAIN checkout's `.claude/settings.local.json` to
    # every git worktree of the repo, and a `disabledMcpjsonServers: ["arbiter"]`
    # there silently drops the worktree's `.mcp.json`. `--mcp-config` servers
    # are not subject to that list, so the spawn names the file explicitly.

    test ":mcp_config emits --mcp-config <path>" do
      assert {:ok, argv} = Claude.default_argv("the prompt", mcp_config: "/wt/.mcp.json")

      assert ["--mcp-config", "/wt/.mcp.json" | _] =
               Enum.drop_while(argv, &(&1 != "--mcp-config"))
    end

    test "no :mcp_config emits no --mcp-config, even with a worktree_path" do
      assert {:ok, argv} = Claude.default_argv("the prompt", worktree_path: "/wt")
      refute "--mcp-config" in argv
    end

    # -- bd-11abk2 regression: oversized prompt (MAX_ARG_STRLEN) fix ---------

    test "a prompt over 131_072 bytes is delivered via stdin, not argv", %{stub: stub} do
      big_prompt = String.duplicate("x", 131_073)

      assert {:ok, argv} = Claude.default_argv(big_prompt, [])

      # No argv element should carry the giant prompt.
      refute Enum.any?(argv, &(is_binary(&1) and &1 == big_prompt))

      assert ["sh", "-c", script, "sh", tmp, ^stub, "--print" | rest] = argv
      assert script =~ "exec \"$@\""
      assert File.exists?(tmp)
      assert File.read!(tmp) == big_prompt
      assert "--output-format" in rest

      File.rm(tmp)
    end

    test "a prompt at or under 131_072 bytes stays inline (mode A unchanged)", %{stub: stub} do
      exact_prompt = String.duplicate("x", 131_072)

      assert {:ok, argv} = Claude.default_argv(exact_prompt, [])
      assert ["sh", "-c", _exec, "sh", ^stub, "--print", ^exact_prompt | _rest] = argv
    end
  end

  describe "build_argv/3 and the tmp-file helpers directly" do
    test "prompt_tmpfile/1 extracts the temp path for stdin-mode argv" do
      big = String.duplicate("x", 200_000)
      assert {:ok, argv} = Claude.build_argv("/bin/claude", big, ["--verbose"])

      tmp = Claude.prompt_tmpfile(argv)
      assert is_binary(tmp)
      assert File.read!(tmp) == big

      File.rm(tmp)
    end

    test "prompt_tmpfile/1 returns nil for inline-mode argv" do
      assert {:ok, argv} = Claude.build_argv("/bin/claude", "small prompt", ["--verbose"])
      assert Claude.prompt_tmpfile(argv) == nil
    end
  end

  # Pull the JSON document out of the `--settings <json>` argv pair.
  defp settings_json(argv) do
    idx = Enum.find_index(argv, &(&1 == "--settings"))
    argv |> Enum.at(idx + 1) |> Jason.decode!()
  end

  describe "spawn_env/1 (key rotation)" do
    setup do
      # Isolate from any real CLAUDE_CODE_OAUTH_TOKEN set in the dev/CI shell
      # so the ANTHROPIC_API_KEY-focused assertions below stay exact-match.
      prev_oauth_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        Claude.Config.clear()

        case prev_oauth_token do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
        end
      end)

      :ok
    end

    test "returns just the explicit token unset when no api_key is configured (CLI uses ambient auth)" do
      assert Claude.spawn_env([]) == [{"CLAUDE_CODE_OAUTH_TOKEN", false}]
    end

    test "exports `ANTHROPIC_API_KEY` from `opts[:api_key]`" do
      assert Claude.spawn_env(api_key: "literal-token") ==
               [{"CLAUDE_CODE_OAUTH_TOKEN", false}, {"ANTHROPIC_API_KEY", "literal-token"}]
    end

    test "rotates through `api_keys` from active config" do
      System.put_env("ARB_TEST_KEY_A", "key-a")
      System.put_env("ARB_TEST_KEY_B", "key-b")

      on_exit(fn ->
        System.delete_env("ARB_TEST_KEY_A")
        System.delete_env("ARB_TEST_KEY_B")
      end)

      Claude.Config.put_active(%{
        "api_keys" => ["env:ARB_TEST_KEY_A", "env:ARB_TEST_KEY_B"]
      })

      assert Claude.spawn_env([]) == [
               {"CLAUDE_CODE_OAUTH_TOKEN", false},
               {"ANTHROPIC_API_KEY", "key-a"}
             ]

      assert Claude.spawn_env([]) == [
               {"CLAUDE_CODE_OAUTH_TOKEN", false},
               {"ANTHROPIC_API_KEY", "key-b"}
             ]

      # Wraps back to the first key on the next call.
      assert Claude.spawn_env([]) == [
               {"CLAUDE_CODE_OAUTH_TOKEN", false},
               {"ANTHROPIC_API_KEY", "key-a"}
             ]
    end

    test "prepends an isolated CLAUDE_CONFIG_DIR when config isolation is enabled" do
      target =
        Path.join(System.tmp_dir!(), "arbiter-spawnenv-iso-#{System.unique_integer([:positive])}")

      prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
      prev_dir = Application.get_env(:arbiter, :worker_config_dir)
      Application.put_env(:arbiter, :worker_isolate_config, true)
      Application.put_env(:arbiter, :worker_config_dir, target)

      on_exit(fn ->
        put_or_delete(:worker_isolate_config, prev_isolate)
        put_or_delete(:worker_config_dir, prev_dir)
        File.rm_rf!(target)
      end)

      # Config-dir isolation comes first; the API key composes on top.
      assert Claude.spawn_env(api_key: "literal-token") == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", false},
               {"ANTHROPIC_API_KEY", "literal-token"}
             ]
    end

    test "spawn_env ignores a stray `:anthropic_base_url` opt (proxy removed, bd-7cvh8z)" do
      assert Claude.spawn_env(anthropic_base_url: "http://localhost/whatever") == [
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
             ]

      assert Claude.spawn_env([]) == [{"CLAUDE_CODE_OAUTH_TOKEN", false}]
    end
  end

  # bd-2zigo1 exported a server-env `CLAUDE_CODE_OAUTH_TOKEN` to every spawn.
  # Since the P13 flip (bd-9gqj8e) the token comes from the provider account
  # alone (`arbiter/accounts/legacy_chain_removed_test.exs` covers that side
  # against a real database); the server env value is inert, and the pair is
  # an explicit unset so it cannot leak into the child either.
  describe "spawn_env/1 (CLAUDE_CODE_OAUTH_TOKEN, bd-2zigo1)" do
    setup do
      prev_oauth_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        Claude.Config.clear()

        case prev_oauth_token do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
        end
      end)

      :ok
    end

    test "emits an explicit unset when the OS env var is unset" do
      assert Claude.spawn_env([]) == [{"CLAUDE_CODE_OAUTH_TOKEN", false}]
    end

    test "a server env token is never exported: the pair stays an explicit unset" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")

      assert Claude.spawn_env([]) == [{"CLAUDE_CODE_OAUTH_TOKEN", false}]
      assert Claude.spawn_env(workspace: nil) == [{"CLAUDE_CODE_OAUTH_TOKEN", false}]
    end

    test "never remaps the OAuth token onto ANTHROPIC_API_KEY" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")

      env = Claude.spawn_env([])

      refute List.keyfind(env, "ANTHROPIC_API_KEY", 0)
    end

    test "composes alongside ANTHROPIC_API_KEY without disturbing it" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")

      assert Claude.spawn_env(api_key: "literal-token") == [
               {"CLAUDE_CODE_OAUTH_TOKEN", false},
               {"ANTHROPIC_API_KEY", "literal-token"}
             ]
    end
  end

  # bd-80ecol: the workspace-less CredentialWatchdog probe used to run on a
  # copy of the operator's `.credentials.json` whenever no install-wide token
  # resolved. With that copy gone it would 401 and mark the adapter expired —
  # refusing every Claude dispatch fleet-wide, including workspaces that do
  # have a token. So it declines to run instead; Preflight reports that as a
  # non-auth failure, which the watchdog leaves alone.
  describe "auth_probe_argv/1 with no credential (bd-80ecol)" do
    setup do
      prev =
        for var <- ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY), into: %{} do
          {var, System.get_env(var)}
        end

      Enum.each(prev, fn {var, _} -> System.delete_env(var) end)

      # No sandbox: the install-wide account read fails soft and reads as
      # "no install-wide credential".
      on_exit(fn ->
        Enum.each(prev, fn
          {var, nil} -> System.delete_env(var)
          {var, v} -> System.put_env(var, v)
        end)
      end)

      :ok
    end

    @tag :capture_log
    test "declines to probe when no setup token or API key resolves" do
      assert {:error, {:no_setup_token, summary}} = Claude.auth_probe_argv([])
      assert summary =~ "no Claude setup token"
    end

    @tag :capture_log
    test "a Preflight check of it is a non-auth failure, and spawns nothing" do
      assert {:error, %Arbiter.Worker.StopReason{category: category, summary: summary}} =
               Arbiter.Agents.Preflight.check(Claude, [])

      refute category == :auth_expired
      assert summary =~ "no Claude setup token"
    end

    @tag :capture_log
    test "a server-env setup token no longer makes it probe (P13)" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")

      assert {:error, {:no_setup_token, _}} = Claude.auth_probe_argv([])
    end

    @tag :capture_log
    test "probes as before once a credential resolves" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-server")

      refute match?({:error, {:no_setup_token, _}}, Claude.auth_probe_argv([]))
    end
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:arbiter, key)
  defp put_or_delete(key, val), do: Application.put_env(:arbiter, key, val)

  describe "usage_attrs/1" do
    test "returns an empty-ish map tagged with the provider when no usage was absorbed" do
      session = Claude.init_session([])
      attrs = Claude.usage_attrs(session)
      assert attrs.provider == "claude"
    end
  end
end
