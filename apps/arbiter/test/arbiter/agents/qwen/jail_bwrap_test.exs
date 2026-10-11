defmodule Arbiter.Agents.Qwen.JailBwrapTest do
  # async: false — PATH and the jail / home Application env are global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Qwen
  alias Arbiter.Agents.Qwen.ConfigDir
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.Jail

  @moduletag :capture_log
  @moduletag :bwrap

  @probe Jail.probe()

  if @probe != :ok do
    @moduletag skip: "bwrap write jail unavailable on this host: #{inspect(@probe)}"
  end

  # The real `Qwen.default_argv/2` under a real bwrap, with a stub `qwen` that
  # tries the writes the policy forbids. The filesystem jail only: the network
  # namespace and its bridges are exercised by `jail_network_test.exs`.
  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "qwen-jail-bwrap-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    wt = Path.join(base, "wt")
    # The stub lives in the (bound) worktree: the jail's `--tmpfs /tmp` hides
    # anything else under a /tmp TMPDIR, as it does in CI.
    bin = Path.join(wt, ".stub-bin")
    File.mkdir_p!(bin)

    sys = ConfigDir.system_settings_path(worktree: wt)

    File.write!(Path.join(bin, "qwen"), """
    #!/bin/sh
    { echo changed > "#{wt}/review-write.txt"; } 2>&1 | grep -qi 'read-only file system' && echo WORKTREE_EROFS
    echo ok > "$HOME/home-write.txt" && echo HOME_WRITE_OK
    { echo '{}' > "#{sys}"; } 2>&1 | grep -qi 'read-only file system' && echo SETTINGS_EROFS
    { rm -f "#{sys}"; } 2>&1 | grep -qi 'read-only file system' && echo SETTINGS_RM_EROFS
    exit 0
    """)

    File.chmod!(Path.join(bin, "qwen"), 0o755)

    keys = ~w(worker_qwen_home_root worker_jail_available worker_jail_bwrap worker_jail_network
              worker_jail_ssh_shadow_root)a

    prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})
    old_path = System.get_env("PATH")

    Application.put_env(:arbiter, :worker_qwen_home_root, Path.join(base, "homes"))
    Application.put_env(:arbiter, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))
    Application.put_env(:arbiter, :worker_jail_network, false)
    Application.delete_env(:arbiter, :worker_jail_available)
    Application.delete_env(:arbiter, :worker_jail_bwrap)
    System.put_env("PATH", bin <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:arbiter, k)
        {k, v} -> Application.put_env(:arbiter, k, v)
      end)

      File.rm_rf!(base)
    end)

    {:ok, wt: wt}
  end

  defp run(argv) do
    [cmd | args] = argv
    System.cmd(cmd, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
  end

  test "a reviewer's qwen cannot write the worktree, keeps its home writable and cannot touch its own settings",
       %{wt: wt} do
    policy =
      SecurityPolicy.merge(SecurityPolicy.default(), %{
        "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]}
      })

    assert {:ok, argv} =
             Qwen.default_argv("review", worktree: wt, security: policy, owner: self())

    {out, status} = run(argv)

    assert status == 0, out
    assert out =~ "WORKTREE_EROFS"
    assert out =~ "HOME_WRITE_OK"
    assert out =~ "SETTINGS_EROFS"
    assert out =~ "SETTINGS_RM_EROFS"
    refute File.exists?(Path.join(wt, "review-write.txt"))
  end

  test "an implementer's qwen can write the worktree (the control for the test above)", %{wt: wt} do
    assert {:ok, argv} =
             Qwen.default_argv("implement",
               worktree: wt,
               security: SecurityPolicy.default(),
               owner: self()
             )

    {out, status} = run(argv)

    assert status == 0, out
    refute out =~ "WORKTREE_EROFS"
    assert File.read!(Path.join(wt, "review-write.txt")) == "changed\n"
    # the settings stay read-only for an implementer too
    assert out =~ "SETTINGS_EROFS"
  end
end
