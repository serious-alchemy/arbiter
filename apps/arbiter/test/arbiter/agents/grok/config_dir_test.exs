defmodule Arbiter.Agents.Grok.ConfigDirTest do
  # async: false — the home root is Application env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Grok.ConfigDir

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "grok-home-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    prev = Application.get_env(:arbiter, :worker_grok_home_root)
    Application.put_env(:arbiter, :worker_grok_home_root, Path.join(base, "homes"))

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :worker_grok_home_root, prev),
        else: Application.delete_env(:arbiter, :worker_grok_home_root)

      File.rm_rf!(base)
    end)

    {:ok, base: base, worktree: Path.join(base, "wt")}
  end

  test "path/1 is keyed on the worktree and stable", %{worktree: wt} do
    assert ConfigDir.path(worktree: wt) == ConfigDir.path(worktree: wt)
    assert ConfigDir.path(worktree: wt) != ConfigDir.path(worktree: wt <> "-2")
    assert Path.basename(ConfigDir.path([])) == "default"
  end

  test "grok_home/1 is $HOME/.grok", %{worktree: wt} do
    assert ConfigDir.grok_home(worktree: wt) == Path.join(ConfigDir.path(worktree: wt), ".grok")
  end

  test "ensure/1 creates the home and its .grok dir", %{worktree: wt} do
    assert {:ok, dir} = ConfigDir.ensure(worktree: wt)
    assert File.dir?(Path.join(dir, ".grok"))
  end

  test "env/1 sets HOME and GROK_HOME=$HOME/.grok and nothing of the operator's", %{worktree: wt} do
    assert {:ok, env} = ConfigDir.env(worktree: wt)
    home = ConfigDir.path(worktree: wt)
    assert {"HOME", home} in env
    assert {"GROK_HOME", Path.join(home, ".grok")} in env
    assert Enum.all?(env, fn {_, v} -> String.starts_with?(v, home) end)
  end

  test "a symlink planted at .grok by a previous (jailed) run is replaced, not followed", %{
    base: base,
    worktree: wt
  } do
    elsewhere = Path.join(base, "elsewhere")
    File.mkdir_p!(elsewhere)
    home = ConfigDir.path(worktree: wt)
    File.mkdir_p!(home)
    File.ln_s!(elsewhere, Path.join(home, ".grok"))

    assert {:ok, ^home} = ConfigDir.ensure(worktree: wt)
    assert {:ok, %{type: :directory}} = File.lstat(Path.join(home, ".grok"))
  end

  test "write_prompt_file/2 puts the prompt under the home, 0600", %{worktree: wt} do
    assert {:ok, path} = ConfigDir.write_prompt_file("a prompt", worktree: wt)
    assert String.starts_with?(path, ConfigDir.path(worktree: wt))
    assert File.read!(path) == "a prompt"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  describe "config.toml (bd-cwq8b0)" do
    setup do
      prev = Application.get_env(:arbiter, :grok_quota)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbiter, :grok_quota, prev),
          else: Application.delete_env(:arbiter, :grok_quota)
      end)
    end

    defp config_path(wt), do: Path.join(ConfigDir.grok_home(worktree: wt), "config.toml")

    test "ensure/1 writes a low [models] rate_limit_retry_threshold, 0600", %{worktree: wt} do
      Application.delete_env(:arbiter, :grok_quota)
      assert {:ok, _} = ConfigDir.ensure(worktree: wt)

      toml = File.read!(config_path(wt))
      assert toml =~ ~r/^\[models\]$/m
      assert toml =~ ~r/^rate_limit_retry_threshold = 2$/m
      assert {:ok, %{mode: mode}} = File.stat(config_path(wt))
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "the threshold is configurable and rewritten on every ensure", %{worktree: wt} do
      assert {:ok, _} = ConfigDir.ensure(worktree: wt)
      Application.put_env(:arbiter, :grok_quota, rate_limit_retry_threshold: 1)
      assert {:ok, _} = ConfigDir.ensure(worktree: wt)
      assert File.read!(config_path(wt)) =~ "rate_limit_retry_threshold = 1"
    end

    test "a non-positive threshold falls back to the default", %{worktree: wt} do
      Application.put_env(:arbiter, :grok_quota, rate_limit_retry_threshold: 0)
      assert ConfigDir.rate_limit_retry_threshold() == 2
      assert {:ok, _} = ConfigDir.ensure(worktree: wt)
      assert File.read!(config_path(wt)) =~ "rate_limit_retry_threshold = 2"
    end

    test "a config.toml a jailed run replaced with a symlink is not written through", %{
      base: base,
      worktree: wt
    } do
      target = Path.join(base, "victim.toml")
      File.mkdir_p!(base)
      File.write!(target, "untouched")
      assert {:ok, _} = ConfigDir.ensure(worktree: wt)
      File.rm!(config_path(wt))
      File.ln_s!(target, config_path(wt))

      assert {:ok, _} = ConfigDir.ensure(worktree: wt)
      assert File.read!(target) == "untouched"
      assert {:ok, %{type: :regular}} = File.lstat(config_path(wt))
      assert File.read!(config_path(wt)) =~ "rate_limit_retry_threshold"
    end
  end
end
