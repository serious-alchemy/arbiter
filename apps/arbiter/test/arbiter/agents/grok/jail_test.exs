defmodule Arbiter.Agents.Grok.JailTest do
  # async: false — PATH and the jail / home Application env are global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Grok
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.Jail

  @moduletag :capture_log
  @moduletag :bwrap

  @probe Jail.probe()

  if @probe != :ok do
    @moduletag skip: "bwrap write jail unavailable on this host: #{inspect(@probe)}"
  end

  # AC2 of bd-761q6h: a reviewer grok run cannot write the worktree. The
  # `grok` here is a stub that tries the write; everything else (argv, jail
  # wrapping, `--ro-bind`) is the real `Grok.default_argv/2` under a real bwrap.
  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "grok-jail-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    wt = Path.join(base, "wt")
    # The stub lives in the (bound) worktree: the jail's `--tmpfs /tmp` hides
    # anything else under a /tmp TMPDIR, as it does in CI.
    bin = Path.join(wt, ".stub-bin")
    File.mkdir_p!(wt)
    File.mkdir_p!(bin)

    script = Path.join(bin, "grok")

    File.write!(script, """
    #!/bin/sh
    { echo changed > "#{wt}/review-write.txt"; } 2>&1 | grep -qi 'read-only file system' && echo WORKTREE_EROFS
    { echo changed > "#{wt}/.hidden"; } 2>&1 | grep -qi 'read-only file system' && echo WORKTREE_EROFS_DOTFILE
    echo ok > "$HOME/home-write.txt" && echo HOME_WRITE_OK
    printf 'ARGS:%s\\n' "$*"
    exit 0
    """)

    File.chmod!(script, 0o755)

    keys = ~w(worker_grok_home_root worker_jail_available worker_jail_bwrap
              worker_jail_ssh_shadow_root grok_credential_env)a

    prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})
    old_path = System.get_env("PATH")

    Application.put_env(:arbiter, :worker_grok_home_root, Path.join(base, "homes"))
    Application.put_env(:arbiter, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))
    Application.delete_env(:arbiter, :worker_jail_available)
    Application.delete_env(:arbiter, :worker_jail_bwrap)
    Application.delete_env(:arbiter, :grok_credential_env)
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

  test "a reviewer's grok cannot write the worktree but keeps its own home writable", %{wt: wt} do
    policy =
      SecurityPolicy.merge(SecurityPolicy.default(), %{
        "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]}
      })

    assert {:ok, argv} = Grok.default_argv("review", worktree: wt, security: policy)
    {out, status} = run(argv)

    assert status == 0, out
    assert out =~ "WORKTREE_EROFS\n"
    assert out =~ "WORKTREE_EROFS_DOTFILE"
    assert out =~ "HOME_WRITE_OK"
    refute File.exists?(Path.join(wt, "review-write.txt"))
    refute File.exists?(Path.join(wt, ".hidden"))
    # The deny flags reached the (stub) grok's argv inside the jail.
    assert out =~ "--deny Edit"
    assert out =~ "--disallowed-tools"
  end

  test "an implementer's grok can write the worktree (the control for the test above)", %{wt: wt} do
    assert {:ok, argv} =
             Grok.default_argv("implement", worktree: wt, security: SecurityPolicy.default())

    {out, status} = run(argv)

    assert status == 0, out
    refute out =~ "WORKTREE_EROFS"
    assert File.read!(Path.join(wt, "review-write.txt")) == "changed\n"
  end
end
