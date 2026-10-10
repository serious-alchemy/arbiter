defmodule Arbiter.NodeAgent.K8s.PodRuntimeTest do
  @moduledoc """
  K7 (bd-dzyclc): the pod's shell runtime against the controller's real `:9444`
  listener, run with the host's `sh` (the image's `/bin/sh` is dash as well):
  `seed` redeems the nonce and builds the tree, the entry wrapper sources and
  deletes the secrets, the `snapshotter` uploads a checkpoint and, on SIGTERM,
  the final snapshot. The same flow inside the real image is
  `pod_runtime_podman_test.exs` (opt-in).
  """
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.NodeAgent.PodChannel.Runs
  alias Arbiter.NodeAgent.PodRuntimeHarness, as: H

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp} = ctx do
    fixture = H.fixture!(tmp)
    channel = H.start!(tmp, fixture, ctx[:spec] || %{})

    dirs = %{
      run: Path.join(tmp, "run"),
      work: Path.join(tmp, "work"),
      tmp: Path.join(tmp, "scratch")
    }

    Enum.each(Map.values(dirs), &File.mkdir_p!/1)

    env = [
      {"ARB_RUN_DIR", dirs.run},
      {"ARB_CA_FILE", channel.ca_file},
      {"ARB_WORK_ROOT", dirs.work},
      {"ARB_BRIDGE_ADDR", "localhost"},
      {"ARB_CHANNEL_PORT", Integer.to_string(channel.port)},
      {"ARB_BOOT_NONCE", channel.nonce},
      {"ARB_RUN", H.run_id()},
      {"ARB_SEED_LAYER", Path.join(tmp, "no-seed-layer")},
      {"TMPDIR", dirs.tmp},
      {"HOME", dirs.tmp}
    ]

    %{fixture: fixture, channel: channel, dirs: dirs, env: env, wt: Path.join(dirs.work, "wt")}
  end

  defp sh(script, env),
    do: System.cmd(H.shell(), [H.script(script)], env: env, stderr_to_stdout: true)

  test "seed redeems the nonce and builds the private-clone layout", ctx do
    assert {out, 0} = sh("seed", ctx.env)
    assert out =~ "seeded"
    assert_received {:primary, :seed, "run-1"}

    wt = ctx.wt
    assert H.git!(wt, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature/x\n"
    assert String.trim(H.git!(wt, ["rev-parse", "HEAD"])) == ctx.fixture.head
    assert File.read!(Path.join(wt, "lib/b.ex")) =~ "defmodule B"
    assert H.git!(wt, ["status", "--porcelain"]) == ""

    # the four guard files, as PrivateClone builds them
    assert File.read!(Path.join(wt, ".git/commondir")) == ".\n"
    assert File.read!(Path.join(wt, ".git/objects/info/alternates")) == ""
    assert File.dir?(Path.join(wt, ".git/hooks"))
    assert File.ls!(Path.join(wt, ".git/hooks")) == []
    assert File.regular?(Path.join(wt, ".git/config"))

    # secrets and certificates are in the memory volume, the tree holds neither
    assert File.read!(Path.join(ctx.dirs.run, "env")) =~ "export TOKEN='s3cret'"
    assert File.regular?(Path.join(ctx.dirs.run, "tls/control.key"))
    assert File.regular?(Path.join(ctx.dirs.run, "tls/proxy.crt"))
    refute File.exists?(Path.join(ctx.dirs.run, "boot"))
    refute File.exists?(Path.join(ctx.dirs.run, "boot.tar"))
    refute File.exists?(Path.join(ctx.dirs.work, "seed.bundle"))
    refute File.read!(Path.join(wt, ".git/config")) =~ "s3cret"

    # the base is where PrivateClone puts it
    assert String.trim(H.git!(wt, ["rev-parse", "refs/remotes/origin/main"])) == ctx.fixture.base
    assert String.trim(H.git!(wt, ["rev-parse", "refs/heads/main"])) == ctx.fixture.base

    assert File.read!(Path.join(ctx.dirs.run, "checkout")) ==
             "branch=feature/x\nbase=main\nknown=#{ctx.fixture.head}\nknown=#{ctx.fixture.base}\n"

    assert PodScripts.env_file() == "/run/arb/env"
  end

  test "a replayed nonce is refused and seeds nothing", ctx do
    assert {_, 0} = sh("seed", ctx.env)
    File.rm_rf!(ctx.dirs.work)
    File.mkdir_p!(ctx.dirs.work)

    assert {out, code} = sh("seed", ctx.env)
    assert code == 78
    assert out =~ "refused the boot nonce"
    refute File.exists?(Path.join(ctx.dirs.work, "wt/.git"))
  end

  describe "seed files" do
    @describetag spec: %{
                   "mounts" => [
                     %{
                       "kind" => "worktree",
                       "path" => "/work/tree",
                       "files" => %{".mcp.json" => Base.encode64(~s({"mcpServers":{}}))}
                     },
                     %{
                       "kind" => "config_dir",
                       "path" => "/cfg",
                       "files" => %{"settings.json" => Base.encode64("{}")}
                     },
                     %{
                       "kind" => "prompt",
                       "path" => "/p/prompt.md",
                       "content" => Base.encode64("do the thing")
                     }
                   ]
                 }

    test "land in the tree, the config dir and the run volume; the seed layer is copied in",
         ctx do
      layer = Path.join(ctx.tmp_dir, "layer")
      File.mkdir_p!(Path.join(layer, "deps/foo"))
      File.write!(Path.join(layer, "deps/foo/mix.exs"), "# dep\n")
      env = put_env(ctx.env, "ARB_SEED_LAYER", layer)

      assert {_, 0} = sh("seed", env)
      assert File.read!(Path.join(ctx.wt, ".mcp.json")) == ~s({"mcpServers":{}})
      assert File.read!(Path.join(ctx.wt, "deps/foo/mix.exs")) == "# dep\n"
      assert File.read!(Path.join(ctx.dirs.work, "claude-config/settings.json")) == "{}"
      assert File.read!(Path.join(ctx.dirs.run, "prompt-0")) == "do the thing"
      assert File.dir?(Path.join(ctx.dirs.work, "home"))
    end
  end

  describe "the entry wrapper after seed" do
    test "sources the secrets the seed unpacked, then deletes them", ctx do
      assert {_, 0} = sh("seed", ctx.env)
      env_file = Path.join(ctx.dirs.run, "env")
      assert File.exists?(env_file)

      script = Path.join(ctx.tmp_dir, "entry.sh")
      File.write!(script, String.replace(PodScripts.entry(), PodScripts.env_file(), env_file))

      assert {"s3cret\n", 0} =
               System.cmd(H.shell(), [script, "sh", "-c", ~S(echo "$TOKEN")],
                 stderr_to_stdout: true
               )

      refute File.exists?(env_file)
    end
  end

  describe "the snapshotter" do
    setup ctx do
      assert {_, 0} = sh("seed", ctx.env)

      # the worker's work: a commit, an untracked file, a transcript
      File.write!(Path.join(ctx.wt, "lib/c.ex"), "defmodule C do\nend\n")
      H.git!(ctx.wt, ["add", "lib/c.ex"])
      H.git!(ctx.wt, ["commit", "-q", "-m", "worker commit"])
      File.write!(Path.join(ctx.wt, "notes.txt"), "uncommitted\n")
      cfg = Path.join(ctx.dirs.work, "claude-config")
      File.mkdir_p!(Path.join(cfg, "projects/p"))
      File.write!(Path.join(cfg, "projects/p/s.jsonl"), ~s({"type":"user"}\n))

      snap_env =
        ctx.env ++
          [
            {"ARB_WORKTREE", ctx.wt},
            {"ARB_CONFIG_DIR", cfg},
            {"ARB_SNAPSHOT_INTERVAL_S", "3600"},
            {"ARB_COMMAND_POLL_S", "1"}
          ]

      %{snap_env: snap_env, worker_tip: String.trim(H.git!(ctx.wt, ["rev-parse", "HEAD"]))}
    end

    test "on SIGTERM takes the final snapshot, uploads it and exits 0", ctx do
      snap = start_snapshotter(ctx.snap_env)
      refute_received {:pod_channel_upload, _, _, _}

      assert {0, _log} = terminate(snap)
      assert_received {:pod_channel_upload, "run-1", :checkpoint, {:ok, 200}}
      assert_received {:pod_channel_upload, "run-1", :transcripts, {:ok, 200}}
      assert_received {:primary, "checkout", "run-1", bundle}
      assert_received {:primary, "transcripts", "run-1", transcripts}

      s = snapshot_of(ctx, bundle)
      # the snapshot is a commit on the worker's tip carrying the untracked file
      assert s.parent == ctx.worker_tip
      assert s.show["notes.txt"] == "uncommitted\n"
      assert s.show["lib/c.ex"] =~ "defmodule C"
      assert s.heads =~ "refs/heads/feature/x"
      assert s.heads =~ "refs/arbiter/snapshot/run-1"

      assert {:ok, [{~c"projects/p/s.jsonl", _}]} =
               :erl_tar.extract({:binary, transcripts}, [:memory, :compressed])
    end

    test "uploads on the interval without being told to", ctx do
      snap = start_snapshotter(put_env(ctx.snap_env, "ARB_SNAPSHOT_INTERVAL_S", "1"))
      assert_receive {:primary, "checkout", "run-1", bundle}, 20_000
      assert snapshot_of(ctx, bundle).parent == ctx.worker_tip
      assert {0, _} = terminate(snap)
    end

    test "uploads when the controller queues a checkpoint command", ctx do
      snap = start_snapshotter(ctx.snap_env)
      :ok = Runs.push_command(ctx.channel.runs, "run-1", %{"op" => "checkpoint"})
      assert_receive {:primary, "checkout", "run-1", _bundle}, 20_000
      assert {0, _} = terminate(snap)
    end

    test "takes an early snapshot when the work volume passes 80 % of its limit", ctx do
      snap = start_snapshotter(put_env(ctx.snap_env, "ARB_WORK_LIMIT_BYTES", "1000"))
      assert_receive {:primary, "checkout", "run-1", _bundle}, 20_000
      assert {0, _} = terminate(snap)
    end

    test "vetoes a tree with too much untracked payload and exits 1", ctx do
      File.write!(Path.join(ctx.wt, "big.bin"), :binary.copy("x", 5_000))
      snap = start_snapshotter(put_env(ctx.snap_env, "ARB_MAX_UNTRACKED_BYTES", "1000"))
      assert {1, log} = terminate(snap)
      assert log =~ "veto"
      refute_received {:primary, "checkout", _, _}
    end

    test "exits 1 when the controller refuses the final upload", ctx do
      :ok = Runs.release(ctx.channel.runs, "run-1")
      snap = start_snapshotter(ctx.snap_env)
      assert {1, log} = terminate(snap)
      assert log =~ "FAILED"
    end
  end

  defp put_env(env, key, value), do: List.keystore(env, key, 0, {key, value})

  # -- helpers -------------------------------------------------------------------------

  defp start_snapshotter(env) do
    port =
      Port.open({:spawn_executable, H.shell()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [H.script("snapshotter")],
        env: for({k, v} <- env, do: {String.to_charlist(k), String.to_charlist(v)})
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    log = await_log(port, "checkpoint every", "")
    %{port: port, os_pid: os_pid, log: log}
  end

  defp await_log(port, needle, acc) do
    if String.contains?(acc, needle) do
      acc
    else
      receive do
        {^port, {:data, data}} -> await_log(port, needle, acc <> data)
        {^port, {:exit_status, status}} -> flunk("snapshotter exited #{status}: #{acc}")
      after
        10_000 -> flunk("snapshotter never started: #{acc}")
      end
    end
  end

  # SIGTERM to the exact pid (never a pattern), then the exit status and the log.
  defp terminate(%{port: port, os_pid: os_pid, log: log}) do
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    collect(port, log)
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, status}} -> {status, acc}
    after
      60_000 -> flunk("snapshotter did not exit after SIGTERM: #{acc}")
    end
  end

  # Unpack an uploaded bundle on top of the seeded tree's objects: the snapshot
  # commit's parent, the files in its tree, the heads the bundle carries.
  defp snapshot_of(ctx, bundle) do
    path = Path.join(ctx.tmp_dir, "up-#{System.unique_integer([:positive])}.bundle")
    File.write!(path, bundle)
    copy = Path.join(ctx.tmp_dir, "copy-#{System.unique_integer([:positive])}")
    H.git!(ctx.tmp_dir, ["clone", "-q", "--no-hardlinks", ctx.wt, copy])
    H.git!(copy, ["fetch", "-q", path, "refs/arbiter/snapshot/run-1:refs/s/snap"])

    show =
      for file <- ["notes.txt", "lib/c.ex"], into: %{} do
        {file, H.git!(copy, ["show", "refs/s/snap:" <> file])}
      end

    %{
      parent: String.trim(H.git!(copy, ["rev-parse", "refs/s/snap^"])),
      show: show,
      heads: H.git!(copy, ["bundle", "list-heads", path])
    }
  end
end
