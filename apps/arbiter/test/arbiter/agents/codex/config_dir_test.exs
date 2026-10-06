defmodule Arbiter.Agents.Codex.ConfigDirTest do
  # async: false — toggles Application env (the isolation switch, the home
  # root and the source home) that other tests read.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Codex.ConfigDir

  @operator_config """
  model = "gpt-5.6-luna"
  model_reasoning_effort = "medium"
  model_provider = "ollama"
  cli_auth_credentials_store = "file"
  personality = "pirate"

  [projects."/home/op/dev/repo"]
  trust_level = "trusted"

  [model_providers.ollama]
  name = "Ollama"
  base_url = "http://localhost:11434/v1"
  wire_api = "responses"

  [model_providers.ollama.query_params]
  api-version = "1"

  [mcp_servers.personal]
  url = "https://personal.example/mcp"

  [profiles.fast]
  model = "gpt-5.6-luna"
  """

  setup do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arb-codex-home-#{uniq}")
    source = Path.join(base, "operator-codex")
    root = Path.join(base, "worker-codex")
    worktree = Path.join(base, "wt/feature-1")

    File.mkdir_p!(source)
    File.mkdir_p!(worktree)
    File.write!(Path.join(source, "config.toml"), @operator_config)
    File.write!(Path.join(source, "AGENTS.md"), "# Darth Persona\nAlways roleplay.\n")
    File.write!(Path.join(source, "auth.json"), ~s({"tokens":{"refresh_token":"r1"}}))
    File.write!(Path.join(source, "state_5.sqlite"), "operator-state")

    keys = [:worker_isolate_config, :worker_codex_home_root, :worker_codex_source_home]
    prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})

    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_codex_home_root, root)
    Application.put_env(:arbiter, :worker_codex_source_home, source)

    on_exit(fn ->
      Enum.each(prev, fn
        {key, nil} -> Application.delete_env(:arbiter, key)
        {key, val} -> Application.put_env(:arbiter, key, val)
      end)

      File.rm_rf!(base)
    end)

    {:ok, base: base, source: source, root: root, worktree: worktree}
  end

  describe "env/1" do
    test "points CODEX_HOME at a per-worktree directory under the root", ctx do
      assert [{"CODEX_HOME", dir}] = ConfigDir.env(worktree_path: ctx.worktree)
      assert Path.dirname(dir) == ctx.root
      assert File.dir?(dir)
      assert dir == ConfigDir.path(worktree_path: ctx.worktree)
    end

    test "accepts :worktree as well as :worktree_path", ctx do
      assert ConfigDir.env(worktree: ctx.worktree) == ConfigDir.env(worktree_path: ctx.worktree)
    end

    test "is deterministic per worktree and distinct across worktrees", ctx do
      other = Path.join(ctx.base, "other/feature-1")
      File.mkdir_p!(other)

      assert ConfigDir.env(worktree_path: ctx.worktree) ==
               ConfigDir.env(worktree_path: ctx.worktree)

      refute ConfigDir.env(worktree_path: ctx.worktree) == ConfigDir.env(worktree_path: other)
    end

    test "is [] without a worktree (a probe inherits the host home)" do
      assert ConfigDir.env([]) == []
      assert ConfigDir.path([]) == nil
    end

    test "is [] when isolation is switched off", ctx do
      Application.put_env(:arbiter, :worker_isolate_config, false)

      assert ConfigDir.env(worktree_path: ctx.worktree) == []
      assert ConfigDir.ensure(worktree_path: ctx.worktree) == :disabled
      refute ConfigDir.isolated?(worktree_path: ctx.worktree)
    end

    test "is [] (and never raises) when the directory cannot be prepared", ctx do
      blocker = Path.join(ctx.base, "blocker")
      File.write!(blocker, "a file, not a dir")
      Application.put_env(:arbiter, :worker_codex_home_root, Path.join(blocker, "root"))

      assert ConfigDir.env(worktree_path: ctx.worktree) == []
      assert ConfigDir.ensure(worktree_path: ctx.worktree) == :error
      refute ConfigDir.isolated?(worktree_path: ctx.worktree)
    end
  end

  describe "execpolicy rules (bd-99emmd)" do
    alias Arbiter.Agents.SecurityPolicy

    defp rules_path(dir), do: Path.join([dir, "rules", "arbiter.rules"])

    test "writes the policy's deny categories to $CODEX_HOME/rules/arbiter.rules", ctx do
      {:ok, dir} =
        ConfigDir.ensure(worktree_path: ctx.worktree, security: SecurityPolicy.base())

      text = File.read!(rules_path(dir))
      assert text =~ ~s|decision="forbidden"|
      assert text =~ ~s|["git", "push", ["--force", "-f"]]|
      assert text =~ ~s|["gh", "pr", "create"]|
    end

    test "defaults to the install-wide policy when the spawn names none", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      assert File.read!(rules_path(dir)) =~ "no_force_push"
    end

    test "the file is regenerated each spawn, so a tampered or stale one is overwritten", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      File.write!(rules_path(dir), "prefix_rule(pattern=[\"git\"], decision=\"allow\")\n")

      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      refute File.read!(rules_path(dir)) =~ "allow"
    end

    test "a policy that denies nothing leaves no rules file behind", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      assert File.exists?(rules_path(dir))

      base = SecurityPolicy.base()
      none = %{base | permissions: %{base.permissions | safe_defaults: []}}

      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree, security: none)
      refute File.exists?(rules_path(dir))
    end

    test "a rules dir replaced by a symlink is not written through", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      elsewhere = Path.join(ctx.base, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.rm_rf!(Path.join(dir, "rules"))
      File.ln_s!(elsewhere, Path.join(dir, "rules"))

      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      refute File.exists?(Path.join(elsewhere, "arbiter.rules"))
      assert File.exists?(rules_path(dir))
    end

    test "the operator's own rules are not carried into the worker's home", ctx do
      File.mkdir_p!(Path.join(ctx.source, "rules"))
      File.write!(Path.join([ctx.source, "rules", "default.rules"]), "# operator allows\n")

      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      assert File.ls!(Path.join(dir, "rules")) == ["arbiter.rules"]
    end
  end

  describe "ensure/1 seeding" do
    test "symlinks auth.json to the source (a copy would rotate the refresh token)", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      auth = Path.join(dir, "auth.json")

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(auth)
      assert File.read_link!(auth) == Path.join(ctx.source, "auth.json")
      assert File.read!(auth) =~ "r1"
    end

    test "a write through the link reaches the operator's auth.json", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      File.write!(Path.join(dir, "auth.json"), ~s({"tokens":{"refresh_token":"r2"}}))

      assert File.read!(Path.join(ctx.source, "auth.json")) =~ "r2"
    end

    test "writes no auth.json link when the source has none (keyless backend)", ctx do
      File.rm!(Path.join(ctx.source, "auth.json"))
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert {:error, :enoent} = File.lstat(Path.join(dir, "auth.json"))
    end

    test "drops a dangling auth.json link when the source login goes away", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      File.rm!(Path.join(ctx.source, "auth.json"))
      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert {:error, :enoent} = File.lstat(Path.join(dir, "auth.json"))
    end

    test "adopts a newer regular auth.json (codex replaced the link) instead of losing it",
         ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      auth = Path.join(dir, "auth.json")
      File.rm!(auth)
      File.write!(auth, ~s({"tokens":{"refresh_token":"rotated"}}))
      future = System.os_time(:second) + 60
      File.touch!(auth, future)

      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(auth)
      assert File.read!(Path.join(ctx.source, "auth.json")) =~ "rotated"
    end

    test "re-points a stale link and replaces an older regular auth.json", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      auth = Path.join(dir, "auth.json")
      File.rm!(auth)
      File.write!(auth, ~s({"tokens":{"refresh_token":"stale"}}))
      File.touch!(auth, System.os_time(:second) - 3600)

      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(auth)
      assert File.read!(Path.join(ctx.source, "auth.json")) =~ "r1"
    end

    test "generated config.toml carries the backend, not the operator's personal config",
         ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      config = File.read!(Path.join(dir, "config.toml"))

      assert config =~ ~s(model_provider = "ollama")
      assert config =~ ~s(cli_auth_credentials_store = "file")
      assert config =~ "[model_providers.ollama]"
      assert config =~ ~s(base_url = "http://localhost:11434/v1")
      assert config =~ "[model_providers.ollama.query_params]"

      refute config =~ "gpt-5.6-luna"
      refute config =~ "model_reasoning_effort"
      refute config =~ "personality"
      refute config =~ "projects"
      refute config =~ "personal.example"
      refute config =~ "profiles"
    end

    test "config.toml is mode 0600 (a provider table can carry a token)", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      {:ok, stat} = File.stat(Path.join(dir, "config.toml"))

      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "is valid even when the source has no config.toml", ctx do
      File.rm!(Path.join(ctx.source, "config.toml"))
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      refute File.read!(Path.join(dir, "config.toml")) =~ "model_provider"
    end

    test "AGENTS.md is the worker doctrine, not the operator's persona", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      memory = File.read!(Path.join(dir, "AGENTS.md"))

      refute memory =~ "Darth"
      assert memory == ConfigDir.worker_memory()
      assert memory =~ "Do NOT adopt a roleplay"
      assert memory =~ "arb done"
    end

    test "does not pass operator state through (sqlite memories, rollouts)", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert {:error, :enoent} = File.lstat(Path.join(dir, "state_5.sqlite"))
      assert {:error, :enoent} = File.lstat(Path.join(dir, "sessions"))
    end

    test "is idempotent and leaves a worker's rollouts alone (resume needs them)", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      rollout = Path.join([dir, "sessions", "2026", "10", "04", "rollout-x.jsonl"])
      File.mkdir_p!(Path.dirname(rollout))
      File.write!(rollout, "{}\n")

      assert {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      assert File.read!(rollout) == "{}\n"
    end

    test "rewrites config.toml and AGENTS.md every spawn (no stale doctrine)", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      File.write!(Path.join(dir, "AGENTS.md"), "tampered")
      File.write!(Path.join(dir, "config.toml"), "model = \"tampered\"")

      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert File.read!(Path.join(dir, "AGENTS.md")) == ConfigDir.worker_memory()
      refute File.read!(Path.join(dir, "config.toml")) =~ "tampered"
    end

    test "does not write through a symlink planted over config.toml or AGENTS.md", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)
      victim = Path.join(ctx.base, "victim")
      File.write!(victim, "precious")

      for name <- ["config.toml", "AGENTS.md"] do
        File.rm!(Path.join(dir, name))
        File.ln_s!(victim, Path.join(dir, name))
      end

      {:ok, ^dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert File.read!(victim) == "precious"
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(dir, "config.toml"))
    end
  end

  describe "seed_run_home/2 (podman backend, bd-50d5j6)" do
    alias Arbiter.Agents.SecurityPolicy

    setup ctx do
      %{run_home: Path.join(ctx.base, "run/codex-home")}
    end

    test "seeds a home of generated files and a COPY of auth.json", ctx do
      assert {:ok, %{dir: dir, auth: {src, run}}} = ConfigDir.seed_run_home(ctx.run_home, [])

      assert dir == ctx.run_home
      assert src == Path.join(ctx.source, "auth.json")
      assert run == Path.join(ctx.run_home, "auth.json")

      # A regular file with the source's content: never a link to the real one.
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(run)
      assert File.read!(run) == File.read!(src)

      config = File.read!(Path.join(dir, "config.toml"))
      assert config =~ ~s(model_provider = "ollama")
      assert config =~ "[model_providers.ollama]"
      refute config =~ "personality"
      refute config =~ "mcp_servers"

      agents = File.read!(Path.join(dir, "AGENTS.md"))
      assert agents =~ "Arbiter Worker"
      refute agents =~ "Darth"

      # None of the operator's state or history.
      refute File.exists?(Path.join(dir, "state_5.sqlite"))
    end

    test "the copy is independent of the source", ctx do
      {:ok, %{auth: {src, run}}} = ConfigDir.seed_run_home(ctx.run_home, [])
      File.write!(run, ~s({"tokens":{"refresh_token":"rotated"}}))
      assert File.read!(src) == ~s({"tokens":{"refresh_token":"r1"}})
    end

    test "writes the deny baseline as execpolicy rules", ctx do
      policy = SecurityPolicy.base()
      assert {:ok, _} = ConfigDir.seed_run_home(ctx.run_home, security: policy)
      assert File.regular?(Path.join(ctx.run_home, "rules/arbiter.rules"))
    end

    test "does not touch the per-worktree host home", ctx do
      assert {:ok, _} = ConfigDir.seed_run_home(ctx.run_home, worktree_path: ctx.worktree)
      refute File.exists?(ctx.root)
    end

    test "is not gated on the worker_isolate_config switch", ctx do
      Application.put_env(:arbiter, :worker_isolate_config, false)
      assert {:ok, %{auth: {_, _}}} = ConfigDir.seed_run_home(ctx.run_home, [])
    end

    test "a source with no login (keyless backend) seeds no auth.json", ctx do
      File.rm!(Path.join(ctx.source, "auth.json"))
      assert {:ok, %{auth: nil}} = ConfigDir.seed_run_home(ctx.run_home, [])
      refute File.exists?(Path.join(ctx.run_home, "auth.json"))
    end

    test "honours an explicit :source_home", ctx do
      other = Path.join(ctx.base, "other")
      File.mkdir_p!(other)
      File.write!(Path.join(other, "auth.json"), ~s({"tokens":{"refresh_token":"other"}}))

      assert {:ok, %{auth: {src, run}}} =
               ConfigDir.seed_run_home(ctx.run_home, source_home: other)

      assert src == Path.join(other, "auth.json")
      assert File.read!(run) =~ "other"
    end
  end

  describe "writable_paths/1" do
    test "binds the worker home and the real auth.json the link resolves to", ctx do
      {:ok, dir} = ConfigDir.ensure(worktree_path: ctx.worktree)

      assert ConfigDir.writable_paths(worktree_path: ctx.worktree) ==
               [dir, Path.join(ctx.source, "auth.json")]
    end

    test "is [] when not isolated", ctx do
      Application.put_env(:arbiter, :worker_isolate_config, false)

      assert ConfigDir.writable_paths(worktree_path: ctx.worktree) == []
    end
  end

  describe "backend_config/1" do
    test "keeps only backend keys and model_providers tables" do
      out = ConfigDir.backend_config(@operator_config)

      assert out =~ ~s(model_provider = "ollama")
      assert out =~ "[model_providers.ollama]"
      refute out =~ "[mcp_servers"
    end

    test "keeps backend keys that sit after a table header out of the root scope" do
      out =
        ConfigDir.backend_config("""
        [tui]
        model_provider = "not-top-level"

        [model_providers.x]
        name = "X"
        """)

      refute out =~ "not-top-level"
      assert out =~ "[model_providers.x]"
    end

    test "is empty for blank input" do
      assert ConfigDir.backend_config("") == ""
    end
  end
end
