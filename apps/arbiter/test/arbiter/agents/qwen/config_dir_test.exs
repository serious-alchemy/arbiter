defmodule Arbiter.Agents.Qwen.ConfigDirTest do
  # async: false — the home root is Application env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Qwen.ConfigDir

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "qwen-home-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    prev = Application.get_env(:arbiter, :worker_qwen_home_root)
    Application.put_env(:arbiter, :worker_qwen_home_root, Path.join(base, "homes"))

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :worker_qwen_home_root, prev),
        else: Application.delete_env(:arbiter, :worker_qwen_home_root)

      File.rm_rf!(base)
    end)

    {:ok, base: base, worktree: Path.join(base, "wt")}
  end

  test "path/1 is keyed on the worktree and stable", %{worktree: wt} do
    assert ConfigDir.path(worktree: wt) == ConfigDir.path(worktree: wt)
    assert ConfigDir.path(worktree: wt) != ConfigDir.path(worktree: wt <> "-2")
    assert Path.basename(ConfigDir.path([])) == "default"
  end

  test "qwen_home/1 is $HOME/.qwen", %{worktree: wt} do
    assert ConfigDir.qwen_home(worktree: wt) == Path.join(ConfigDir.path(worktree: wt), ".qwen")
  end

  test "env/1 sets HOME, QWEN_HOME, the settings path and the phone-home switches", %{
    worktree: wt
  } do
    assert {:ok, env} = ConfigDir.env(worktree: wt)
    home = ConfigDir.path(worktree: wt)
    assert {"HOME", home} in env
    assert {"QWEN_HOME", Path.join(home, ".qwen")} in env
    assert {"QWEN_CODE_SYSTEM_SETTINGS_PATH", ConfigDir.system_settings_path(worktree: wt)} in env
    assert {"QWEN_CODE_MODELS_DEV", "off"} in env
    assert {"QWEN_USAGE_STATISTICS_ENABLED", "false"} in env
    assert {"DISABLE_AUTOUPDATER", "1"} in env
  end

  test "env/1 scrubs operator-inherited qwen and provider variables" do
    {:ok, env} = ConfigDir.env([])

    for var <-
          ~w(DASHSCOPE_API_KEY QWEN_CODE_USER_SETTINGS_PATH XDG_CONFIG_HOME QWEN_TELEMETRY_ENABLED) do
      assert {var, false} in env
    end
  end

  test "operator's ~/.qwen and ~/.agents/skills are neither read nor written", %{
    base: base,
    worktree: wt
  } do
    operator = Path.join(base, "operator")
    File.mkdir_p!(Path.join(operator, ".qwen"))
    File.mkdir_p!(Path.join(operator, ".agents/skills/s"))
    File.write!(Path.join(operator, ".qwen/settings.json"), "{}")
    File.write!(Path.join(operator, ".agents/skills/s/SKILL.md"), "skill")
    before = tree(operator)

    assert {:ok, env} = ConfigDir.env(worktree: wt)

    # Nothing the spawn is told about lives under the operator's home ...
    assert Enum.all?(env, fn
             {_, v} when is_binary(v) and v != "" -> not String.starts_with?(v, operator)
             _ -> true
           end)

    home = ConfigDir.path(worktree: wt)
    assert String.starts_with?(home, base <> "/homes")
    refute File.exists?(Path.join(home, ".agents"))
    refute File.exists?(Path.join([home, ".qwen", "settings.json"]))
    # ... and preparing the home did not touch it.
    assert tree(operator) == before
  end

  describe "system settings" do
    test "carry the deny baseline with memory, telemetry and updates off", %{worktree: wt} do
      {:ok, _} = ConfigDir.ensure(worktree: wt)
      settings = wt |> then(&ConfigDir.system_settings_path(worktree: &1)) |> File.read!()
      settings = Jason.decode!(settings)

      deny = settings["permissions"]["deny"]
      assert "Read(~/.ssh/**)" in deny
      assert "Read(~/.aws/**)" in deny
      assert Enum.any?(deny, &String.contains?(&1, ".qwen"))
      assert settings["telemetry"]["enabled"] == false
      assert settings["privacy"]["usageStatisticsEnabled"] == false
      assert settings["general"]["enableAutoUpdate"] == false
      assert settings["general"]["disableAutoUpdate"] == true
      assert settings["general"]["disableUpdateNag"] == true
      assert settings["memory"]["enableManagedAutoMemory"] == false
      assert settings["memory"]["enableManagedAutoDream"] == false
    end

    test "the file is read-only and lives outside the worker-writable QWEN_HOME", %{
      worktree: wt
    } do
      {:ok, _} = ConfigDir.ensure(worktree: wt)
      path = ConfigDir.system_settings_path(worktree: wt)
      assert %{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o222) == 0
      refute String.starts_with?(path, ConfigDir.qwen_home(worktree: wt) <> "/")
    end

    test "a re-ensure rewrites a read-only file and replaces a planted symlink", %{
      base: base,
      worktree: wt
    } do
      {:ok, _} = ConfigDir.ensure(worktree: wt)
      path = ConfigDir.system_settings_path(worktree: wt)
      target = Path.join(base, "elsewhere.json")
      File.write!(target, "untouched")
      File.rm!(path)
      File.ln_s!(target, path)

      assert {:ok, _} = ConfigDir.ensure(worktree: wt)
      assert {:ok, %{type: :regular}} = File.lstat(path)
      assert File.read!(target) == "untouched"
      assert Jason.decode!(File.read!(path))["telemetry"]["enabled"] == false
    end
  end

  describe "system settings with a security policy" do
    alias Arbiter.Agents.SecurityPolicy

    defp read_settings(wt) do
      [worktree: wt]
      |> ConfigDir.system_settings_path()
      |> File.read!()
      |> Jason.decode!()
    end

    test "the policy's deny rules and tool removal are merged over the baseline", %{worktree: wt} do
      base = SecurityPolicy.default()
      policy = %{base | permissions: %{base.permissions | deny: ["Edit", "Write"]}}

      {:ok, _} = ConfigDir.ensure(worktree: wt, security: policy)
      settings = read_settings(wt)

      deny = settings["permissions"]["deny"]
      # the baseline survives ...
      assert "Read(~/.ssh/**)" in deny
      # ... next to the policy's categories
      assert "Bash(gh pr create *)" in deny
      assert "Bash(rm -rf *)" in deny
      assert deny == Enum.uniq(deny)
      assert Enum.sort(settings["tools"]["exclude"]) == ["edit", "write_file"]
      # the QWEN_HOME of this very spawn is denied by its absolute path
      assert "Edit(#{ConfigDir.qwen_home(worktree: wt)}/**)" in deny
    end

    test "a re-ensure under a different policy replaces the rules", %{worktree: wt} do
      base = SecurityPolicy.default()
      strict = %{base | permissions: %{base.permissions | deny: ["Write"]}}

      {:ok, _} = ConfigDir.ensure(worktree: wt, security: strict)
      {:ok, _} = ConfigDir.ensure(worktree: wt, security: base)

      refute Map.has_key?(read_settings(wt), "tools")
    end

    test "system_settings_dir/1 is the directory the jail binds read-only", %{worktree: wt} do
      assert Path.dirname(ConfigDir.system_settings_path(worktree: wt)) ==
               ConfigDir.system_settings_dir(worktree: wt)
    end
  end

  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(fn p -> {p, File.stat!(p).mtime, File.regular?(p) && File.read!(p)} end)
  end
end
