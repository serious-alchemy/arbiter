defmodule Arbiter.Agents.Claude.ConfigDirTest do
  # async: false — toggles Application/System env (isolation switch, config dir,
  # CLAUDE_CONFIG_DIR source) that other tests read.
  use ExUnit.Case, async: false

  # No Ecto sandbox here, so ConfigDir's workspace-less read of the
  # install-wide account credential can't reach the database; it degrades to
  # "no credential" rather than raising. Capture any log so the run stays
  # readable (logs still surface on failure).
  @moduletag :capture_log

  alias Arbiter.Agents.Claude.ConfigDir

  # bd-24qzhd regression guard: every Arbiter worker spawn injects
  # CLAUDE_CODE_OAUTH_TOKEN, so it is routinely present in the ambient shell
  # `mix test` runs in (a reviewer hit this on `main` itself). Simulate that
  # ambient leak for the whole file — if the per-test `setup` below ever
  # stops clearing the var, the tests in this file fail exactly as they did
  # before this fix, regardless of which host or branch runs them.
  setup_all do
    prev = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "leaked-ambient-token")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
        v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
      end
    end)

    :ok
  end

  setup do
    # A fake operator config dir (the "source") with the seed files, and a
    # separate target the isolated worker dir is built in. Both under tmp.
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arbiter-configdir-test-#{uniq}")
    source = Path.join(base, "source")
    target = Path.join(base, "worker")
    File.mkdir_p!(source)

    File.write!(Path.join(source, ".credentials.json"), ~s({"token":"fake"}))
    File.write!(Path.join(source, "settings.json"), ~s({"permissions":{"defaultMode":"auto"}}))
    # The persona file we must NOT carry over.
    File.write!(Path.join(source, "CLAUDE.md"), "# Darth Persona\nAlways roleplay.\n")

    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_dir = Application.get_env(:arbiter, :worker_config_dir)
    prev_src = System.get_env("CLAUDE_CONFIG_DIR")
    prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_config_dir, target)
    System.put_env("CLAUDE_CONFIG_DIR", source)
    # bd-24qzhd: most tests in this file assert on the no-token seeding path.
    # Arbiter itself injects CLAUDE_CODE_OAUTH_TOKEN into every worker spawn
    # env, so it is routinely present in the ambient shell these tests run
    # in; without clearing it here those tests fail on any host/branch. The
    # describe blocks below that specifically test the token's presence
    # re-set it in their own nested setup, which runs after this one.
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

    on_exit(fn ->
      restore_env(:worker_isolate_config, prev_isolate)
      restore_env(:worker_config_dir, prev_dir)

      case prev_src do
        nil -> System.delete_env("CLAUDE_CONFIG_DIR")
        v -> System.put_env("CLAUDE_CONFIG_DIR", v)
      end

      case prev_token do
        nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
        v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
      end

      File.rm_rf!(base)
    end)

    {:ok, source: source, target: target}
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_env(key, val), do: Application.put_env(:arbiter, key, val)

  # A `.credentials.json` left behind by a build that still had mode B.
  defp seed_stale_copy!(target) do
    File.mkdir_p!(target)
    File.write!(Path.join(target, ".credentials.json"), ~s({"token":"stale-copy"}))
  end

  # bd-6umoh9 read the worker token from the server's own environment; the
  # P13 flip (bd-9gqj8e) removed that source with the rest of the legacy
  # chain, so a server-env token is now inert — never seeded, never injected.
  describe "ensure/0 + env/0 with a server-env CLAUDE_CODE_OAUTH_TOKEN (ignored since P13)" do
    setup do
      prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        case prev_token do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
        end
      end)

      :ok
    end

    test "does not seed .credentials.json when a worker OAuth token is configured", %{
      target: target
    } do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")

      assert {:ok, ^target} = ConfigDir.ensure()

      # No operator credential should exist for the worker to refresh.
      refute File.exists?(Path.join(target, ".credentials.json"))
      # Everything else still seeds/generates normally.
      assert File.read!(Path.join(target, "CLAUDE.md")) =~ "Arbiter Worker"
      assert File.exists?(Path.join(target, "settings.json"))
    end

    test "removes a stale seeded .credentials.json once a worker OAuth token appears", %{
      target: target
    } do
      # Simulate a pre-existing install that seeded before the token was adopted.
      seed_stale_copy!(target)

      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")
      assert {:ok, ^target} = ConfigDir.ensure()

      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "env/0 never passes the server env token on: it explicitly unsets it", %{
      target: target
    } do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")

      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
             ]
    end

    # bd-80ecol: this used to be "seeding still happens" — the silent mode-B
    # fallback that brought the refresh-token lockout back whenever no token
    # resolved. No token now means no credential at all: the dispatch guard
    # (`Arbiter.Agents.Claude.CredentialCheck`) refuses before a spawn.
    test "never seeds when the OS env var is unset, and removes a stale copy", %{
      target: target
    } do
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
      seed_stale_copy!(target)

      assert {:ok, ^target} = ConfigDir.ensure()

      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "env/0 explicitly unsets the token when nothing configures one", %{
      target: target
    } do
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
             ]
    end
  end

  describe "ensure/0 when disabled" do
    test "returns :disabled and env/0 carries only the explicit token unset", %{target: target} do
      Application.put_env(:arbiter, :worker_isolate_config, false)

      assert ConfigDir.ensure() == :disabled
      # Isolation being off only drops the CLAUDE_CONFIG_DIR pair — the token
      # unset still applies, since no token is configured in this setup.
      assert ConfigDir.env() == [{"CLAUDE_CODE_OAUTH_TOKEN", false}]
      refute File.exists?(target)
    end
  end

  describe "ensure/0 legacy dir migration (bd-5szsrw)" do
    # These exercise the *default* path (no :worker_config_dir override), since
    # migration only applies there — an operator override opts out.
    setup %{source: source} do
      uniq = System.unique_integer([:positive])
      cache_home = Path.join(System.tmp_dir!(), "arbiter-configdir-migrate-#{uniq}")
      legacy = Path.join([cache_home, "arbiter", "acolyte-claude"])
      fresh = Path.join([cache_home, "arbiter", "worker-claude"])

      prev_dir = Application.get_env(:arbiter, :worker_config_dir)
      prev_xdg = System.get_env("XDG_CACHE_HOME")

      Application.delete_env(:arbiter, :worker_config_dir)
      System.put_env("XDG_CACHE_HOME", cache_home)
      System.put_env("CLAUDE_CONFIG_DIR", source)

      on_exit(fn ->
        restore_env(:worker_config_dir, prev_dir)

        case prev_xdg do
          nil -> System.delete_env("XDG_CACHE_HOME")
          v -> System.put_env("XDG_CACHE_HOME", v)
        end

        File.rm_rf!(cache_home)
      end)

      {:ok, legacy: legacy, fresh: fresh}
    end

    test "renames an existing legacy acolyte-claude dir to worker-claude", %{
      legacy: legacy,
      fresh: fresh
    } do
      File.mkdir_p!(legacy)
      File.write!(Path.join(legacy, "CLAUDE.md"), "stale worker memory")
      File.mkdir_p!(Path.join(legacy, "projects"))
      File.write!(Path.join([legacy, "projects", "session.jsonl"]), "{}")

      assert {:ok, ^fresh} = ConfigDir.ensure()

      refute File.exists?(legacy)
      assert File.dir?(fresh)
      # Accumulated session history survives the rename...
      assert File.exists?(Path.join([fresh, "projects", "session.jsonl"]))
      # ...and ensure/0 still refreshes the memory file on top of it.
      assert File.read!(Path.join(fresh, "CLAUDE.md")) =~ "Arbiter Worker"
    end

    test "does nothing when there is no legacy dir", %{fresh: fresh} do
      assert {:ok, ^fresh} = ConfigDir.ensure()
      assert File.dir?(fresh)
    end

    test "does not touch the legacy dir once the fresh dir already exists", %{
      legacy: legacy,
      fresh: fresh
    } do
      File.mkdir_p!(legacy)
      File.write!(Path.join(legacy, "marker"), "legacy")
      File.mkdir_p!(fresh)

      assert {:ok, ^fresh} = ConfigDir.ensure()

      assert File.exists?(legacy)
      refute File.exists?(Path.join(fresh, "marker"))
    end
  end
end
