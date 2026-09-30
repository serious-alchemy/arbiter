defmodule Arbiter.Worker.SpawnEnvTest do
  # async: false — mutates the process-global OS environment to simulate the
  # server's own env (bd-7r0qrj).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Worker.SpawnEnv

  @server_secrets %{
    "ARBITER_CLOAK_KEY" => "cloak-secret",
    "ARBITER_CLOAK_KEY_OLD" => "cloak-old",
    "SECRET_KEY_BASE" => "skb-secret",
    "DATABASE_PATH" => "/srv/arbiter/live.sqlite3",
    "DATABASE_URL" => "ecto://live",
    "RELEASE_COOKIE" => "cookie-secret",
    "SSH_AUTH_SOCK" => "/run/user/1000/ssh-agent.sock",
    "DBUS_SESSION_BUS_ADDRESS" => "unix:path=/nonexistent/bus",
    "CLAUDE_CODE_OAUTH_TOKEN" => "claude-server-token",
    "OPENAI_API_KEY" => "openai-server-key",
    "GEMINI_API_KEY" => "gemini-server-key",
    "SOME_RANDOM_OPERATOR_VAR" => "x"
  }

  setup do
    previous = Map.new(@server_secrets, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(@server_secrets)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  # Apply a Port-style pair list on top of the current OS env, the way Erlang's
  # `{:env, pairs}` does, and return the resulting child environment.
  defp child_env(pairs) do
    Enum.reduce(pairs, System.get_env(), fn
      {name, false}, acc -> Map.delete(acc, name)
      {name, value}, acc -> Map.put(acc, name, value)
    end)
  end

  describe "port_env/2" do
    test "no server secret or unlisted var reaches the child" do
      env = "claude" |> then(&SpawnEnv.port_env([], &1)) |> child_env()

      for name <- ~w(ARBITER_CLOAK_KEY ARBITER_CLOAK_KEY_OLD SECRET_KEY_BASE DATABASE_PATH
                     DATABASE_URL RELEASE_COOKIE SSH_AUTH_SOCK DBUS_SESSION_BUS_ADDRESS
                     SOME_RANDOM_OPERATOR_VAR) do
        refute Map.has_key?(env, name), "#{name} leaked into the worker env"
      end
    end

    test "no ARBITER_* or RELEASE_* var survives" do
      System.put_env("ARBITER_SOMETHING_NEW", "1")
      on_exit(fn -> System.delete_env("ARBITER_SOMETHING_NEW") end)

      env = "codex" |> then(&SpawnEnv.port_env([], &1)) |> child_env()

      refute Enum.any?(Map.keys(env), &String.starts_with?(&1, "ARBITER_"))
      refute Enum.any?(Map.keys(env), &String.starts_with?(&1, "RELEASE_"))
    end

    test "the allowlisted basics are inherited untouched" do
      System.put_env("LC_TEST_MARKER", "C")
      on_exit(fn -> System.delete_env("LC_TEST_MARKER") end)

      env = "claude" |> then(&SpawnEnv.port_env([], &1)) |> child_env()

      assert env["PATH"] == System.get_env("PATH")
      assert env["HOME"] == System.get_env("HOME")
      assert env["LC_TEST_MARKER"] == "C"
    end

    test "inherited provider credentials never reach the child" do
      for provider <- ~w(claude codex gemini) do
        env = provider |> then(&SpawnEnv.port_env([], &1)) |> child_env()
        refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")
        refute Map.has_key?(env, "OPENAI_API_KEY")
        refute Map.has_key?(env, "GEMINI_API_KEY")
      end
    end

    test "explicit extras carry the worker's own credential" do
      env =
        "claude"
        |> then(&SpawnEnv.port_env([{"CLAUDE_CODE_OAUTH_TOKEN", "own"}], &1))
        |> child_env()

      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "own"
    end

    test "another provider's credential in the extras is dropped" do
      extras = [
        {"CLAUDE_CODE_OAUTH_TOKEN", "claude-tok"},
        {"OPENAI_API_KEY", "openai-key"},
        {"GEMINI_API_KEY", "gemini-key"},
        {"GH_TOKEN", "gh-tok"}
      ]

      agy = "gemini" |> then(&SpawnEnv.port_env(extras, &1)) |> child_env()
      refute Map.has_key?(agy, "CLAUDE_CODE_OAUTH_TOKEN")
      refute Map.has_key?(agy, "OPENAI_API_KEY")
      assert agy["GEMINI_API_KEY"] == "gemini-key"
      assert agy["GH_TOKEN"] == "gh-tok"

      claude = "claude" |> then(&SpawnEnv.port_env(extras, &1)) |> child_env()
      assert claude["CLAUDE_CODE_OAUTH_TOKEN"] == "claude-tok"
      refute Map.has_key?(claude, "OPENAI_API_KEY")
      refute Map.has_key?(claude, "GEMINI_API_KEY")

      codex = "codex" |> then(&SpawnEnv.port_env(extras, &1)) |> child_env()
      assert codex["OPENAI_API_KEY"] == "openai-key"
      refute Map.has_key?(codex, "CLAUDE_CODE_OAUTH_TOKEN")
      refute Map.has_key?(codex, "GEMINI_API_KEY")
    end

    test "a nil provider is treated as claude" do
      extras = [{"CLAUDE_CODE_OAUTH_TOKEN", "t"}, {"OPENAI_API_KEY", "k"}]
      env = nil |> then(&SpawnEnv.port_env(extras, &1)) |> child_env()
      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "t"
      refute Map.has_key?(env, "OPENAI_API_KEY")
    end

    test "a false (explicit unset) extra stays unset" do
      env =
        "claude"
        |> then(&SpawnEnv.port_env([{"CLAUDE_CODE_OAUTH_TOKEN", false}], &1))
        |> child_env()

      refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")
    end

    test "the operator's D-Bus address is forwarded only to agy, and only when the bus exists" do
      bus = Path.join(System.tmp_dir!(), "arb_spawn_env_bus_#{System.unique_integer([:positive])}")
      File.write!(bus, "")
      on_exit(fn -> File.rm(bus) end)
      System.put_env("DBUS_SESSION_BUS_ADDRESS", "unix:path=" <> bus)

      agy = "gemini" |> then(&SpawnEnv.port_env([], &1)) |> child_env()
      assert agy["DBUS_SESSION_BUS_ADDRESS"] == "unix:path=" <> bus

      for provider <- ~w(claude codex) do
        env = provider |> then(&SpawnEnv.port_env([], &1)) |> child_env()
        refute Map.has_key?(env, "DBUS_SESSION_BUS_ADDRESS")
      end
    end
  end

  describe "cmd_env/2" do
    test "unsets everything off the allowlist with nil" do
      pairs = SpawnEnv.cmd_env([{"GH_TOKEN", "t"}], "claude")

      assert {"ARBITER_CLOAK_KEY", nil} in pairs
      assert {"SECRET_KEY_BASE", nil} in pairs
      assert {"GH_TOKEN", "t"} in pairs
      refute Enum.any?(pairs, fn {_, v} -> v == false end)
    end
  end

  describe "allowed?/1" do
    test "covers the documented basics and rejects secrets" do
      for name <- ~w(PATH HOME LANG LC_ALL TERM TMPDIR MIX_HOME HEX_HOME ARB_HOST) do
        assert SpawnEnv.allowed?(name), name
      end

      for name <- ~w(ARBITER_CLOAK_KEY SECRET_KEY_BASE DATABASE_PATH RELEASE_COOKIE
                     SSH_AUTH_SOCK DBUS_SESSION_BUS_ADDRESS CLAUDE_CODE_OAUTH_TOKEN MIX_ENV) do
        refute SpawnEnv.allowed?(name), name
      end
    end
  end

  describe "spawn-site inventory" do
    @repo_root Path.expand("../../../../..", __DIR__)

    # Every site that launches an agent CLI (claude / agy / codex) — a worker,
    # reviewer, fix/conflict pass or probe — must build its env through
    # SpawnEnv. A new agent spawn that skips it would re-open bd-7r0qrj.
    @agent_spawn_sites ~w(
      apps/arbiter/lib/arbiter/worker/claude_session.ex
      apps/arbiter/lib/arbiter/agents/preflight.ex
      apps/arbiter/lib/arbiter/workflows/code_review/checks.ex
      apps/arbiter/lib/arbiter/workflows/review_reply.ex
      apps/arbiter/lib/arbiter/quota/cloud_code.ex
      apps/arbiter/lib/arbiter/quota/grant_refresher.ex
      apps/arbiter/lib/arbiter/loop/discovery/claude_invoker.ex
    )

    test "every agent-CLI spawn site routes its env through SpawnEnv" do
      for rel <- @agent_spawn_sites do
        body = File.read!(Path.join(@repo_root, rel))

        assert body =~ "SpawnEnv.port_env(" or body =~ "SpawnEnv.cmd_env(",
               "#{rel} spawns an agent CLI without SpawnEnv — it would inherit the server env"
      end
    end
  end
end
