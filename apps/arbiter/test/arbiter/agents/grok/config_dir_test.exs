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
end
