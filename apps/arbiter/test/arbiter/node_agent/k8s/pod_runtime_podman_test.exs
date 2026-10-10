defmodule Arbiter.NodeAgent.K8s.PodRuntimePodmanTest do
  @moduledoc """
  K7 (bd-dzyclc): the pod runtime inside the REAL base image under a REAL
  rootless podman, as uid 10001 with a read-only root file system and the mount
  set `PodSpec` gives the containers: the harness behind
  `pod_runtime_test.exs` (which runs the same scripts under the host's `dash`).

    * the base image has `tini`, `arbiter` (uid/gid 10001, passwd entry, home)
      and `/opt/arbiter/bin/{seed,snapshotter}` owned by root;
    * `seed` (behind the netpol gate, as `PodScripts.seed/0` renders it) redeems
      the nonce against the real `:9444` listener and builds the tree;
    * the worker, through the entry wrapper, sees its secrets and not the file;
      it can commit but cannot write, rename or delete any of the four guard files;
    * the snapshotter, stopped with `podman stop` (SIGTERM to `tini`, which
      forwards it), uploads the final snapshot and exits 0.

  Opt-in (`@moduletag :podman`): needs rootless podman with `--userns=keep-id:uid=,gid=`
  (podman 4.3+), network for the base image build, and builds
  `localhost/arb-test-k7:<suffix>`, removed by that exact tag. Containers are named
  `arb-test-k7-…` and removed by exact name. They use `--network=host` to reach the
  test's loopback listener.

      cd apps/arbiter && mix test --include podman test/arbiter/node_agent/k8s/pod_runtime_podman_test.exs
  """
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.NodeAgent.PodRuntimeHarness, as: H
  alias Arbiter.Worker.Image

  @moduletag :podman
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  @wt "/work/tree"
  @guards ~w(config hooks commondir objects/info/alternates)

  setup_all do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) |> String.downcase()
    tag = "localhost/arb-test-k7:#{suffix}"
    dir = Path.join(System.tmp_dir!(), "arb-k7-img-#{suffix}")
    File.mkdir_p!(Path.join(dir, "context"))

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    H.git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    H.git!(repo, ["add", "-A"])
    H.git!(repo, ["commit", "-q", "-m", "init"])
    {:ok, plan} = Image.plan(repo, "main")

    File.write!(Path.join(dir, "Containerfile"), plan.base.containerfile)

    {out, status} =
      System.cmd(
        "podman",
        [
          "build",
          "-q",
          "-f",
          Path.join(dir, "Containerfile"),
          "-t",
          tag,
          Path.join(dir, "context")
        ],
        stderr_to_stdout: true
      )

    File.rm_rf!(dir)
    if status != 0, do: raise("could not build the base image: #{out}")
    on_exit(fn -> System.cmd("podman", ["rmi", "--force", tag], stderr_to_stdout: true) end)
    %{image: tag}
  end

  setup %{tmp_dir: tmp, image: image} do
    fixture = H.fixture!(tmp)
    channel = H.start!(tmp, fixture)

    dirs =
      for name <- ~w(work run ca scratch), into: %{} do
        path = Path.join(tmp, name)
        File.mkdir_p!(path)
        File.chmod!(path, 0o777)
        {name, path}
      end

    File.cp!(channel.ca_file, Path.join(dirs["ca"], "ca.crt"))
    File.chmod!(Path.join(dirs["ca"], "ca.crt"), 0o644)
    %{image: image, dirs: dirs, channel: channel, fixture: fixture}
  end

  defp podman(args), do: System.cmd("podman", args, stderr_to_stdout: true)

  # The common flags: uid 10001 as the pod runs it, hardened like `PodSpec`.
  defp base_flags(name) do
    [
      "run",
      "--rm",
      "--name",
      name,
      "--network=host",
      "--pull=never",
      "--userns=keep-id:uid=10001,gid=10001",
      # the production backend runs unlabelled too; an enforcing host would otherwise
      # deny the bind-mounted test dirs (user_home_t / tmp_t) to container_t
      "--security-opt=label=disable",
      "--user",
      "10001:10001",
      "--read-only",
      "--cap-drop=all",
      "--security-opt=no-new-privileges",
      "--tmpfs",
      "/tmp:rw,size=64m"
    ]
  end

  defp seed_mounts(d) do
    [
      "-v",
      "#{d["work"]}:/arb/work",
      "-v",
      "#{d["run"]}:/run/arb",
      "-v",
      "#{d["ca"]}:/etc/arb/ca:ro"
    ]
  end

  # `PodSpec.work_mounts/2`: the tree, `.git` as a mount of its own, the guards read-only.
  defp worker_mounts(d) do
    guards =
      Enum.flat_map(@guards, fn g ->
        ["-v", "#{d["work"]}/wt/.git/#{g}:#{@wt}/.git/#{g}:ro"]
      end)

    ["-v", "#{d["work"]}/wt:#{@wt}", "-v", "#{d["work"]}/wt/.git:#{@wt}/.git"] ++
      guards ++ ["-v", "#{d["run"]}:/run/arb", "-v", "#{d["ca"]}:/etc/arb/ca:ro"]
  end

  defp env(pairs), do: Enum.flat_map(pairs, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

  defp name, do: "arb-test-k7-#{System.unique_integer([:positive])}"

  test "the base image has tini, the arbiter user and root-owned programs", %{image: image} do
    {out, 0} =
      podman(
        base_flags(name()) ++
          [
            image,
            "sh",
            "-c",
            "tini --version; getent passwd 10001; getent group 10001; stat -c '%U %a %n' /opt/arbiter/bin/seed /opt/arbiter/bin/snapshotter; git --version; socat -V | grep -i openssl"
          ]
      )

    assert out =~ "tini version"
    assert out =~ "arbiter:x:10001:10001:"
    assert out =~ "root 755 /opt/arbiter/bin/seed"
    assert out =~ "root 755 /opt/arbiter/bin/snapshotter"
  end

  test "seed → work → snapshot upload, including on SIGTERM", ctx do
    d = ctx.dirs
    port = Integer.to_string(ctx.channel.port)

    # 1. seed, behind the netpol gate (127.0.0.1:9 refuses at once)
    seed_env =
      env([
        {"ARB_BOOT_NONCE", ctx.channel.nonce},
        {"ARB_BRIDGE_ADDR", "localhost"},
        {"ARB_CHANNEL_PORT", port},
        {"ARB_GATE_ADDR", "127.0.0.1:9"},
        {"ARB_GATE_TIMEOUT_S", "10"},
        {"ARB_RUN", H.run_id()},
        {"ARB_WORKTREE", @wt},
        {"ARB_WORK_ROOT", "/arb/work"},
        {"HOME", "/tmp"}
      ])

    assert {out, 0} =
             podman(
               base_flags(name()) ++
                 seed_mounts(d) ++ seed_env ++ [ctx.image, "sh", "-c", PodScripts.seed()]
             )

    assert out =~ "seeded"
    assert_received {:primary, :seed, "run-1"}

    # 2. the worker, through the entry wrapper and tini
    probe = """
    set -u
    echo "token=$TOKEN"
    test ! -e /run/arb/env && echo "env-file-deleted"
    for g in config commondir objects/info/alternates; do
      (echo x >> .git/$g) 2>/dev/null && echo "WROTE $g"
      (rm -f .git/$g) 2>/dev/null; test -e .git/$g || echo "DELETED $g"
      (mv .git/$g .git/$g.x) 2>/dev/null && echo "MOVED $g"
    done
    (touch .git/hooks/pre-commit) 2>/dev/null && echo "WROTE hooks"
    (mv .git/hooks .git/hooks.x) 2>/dev/null && echo "MOVED hooks"
    echo work > worker.txt
    git add -A && git commit -q -m worker && echo "committed"
    echo untracked > notes.txt
    """

    {wout, 0} =
      podman(
        base_flags(name()) ++
          worker_mounts(d) ++
          env([{"HOME", "/tmp"}]) ++
          [
            "-w",
            @wt,
            ctx.image,
            "tini",
            "--",
            "sh",
            "-c",
            PodScripts.entry(),
            "sh",
            "sh",
            "-c",
            probe
          ]
      )

    assert wout =~ "token=s3cret"
    assert wout =~ "env-file-deleted"
    assert wout =~ "committed"
    refute wout =~ ~r/WROTE|DELETED|MOVED/
    refute File.exists?(Path.join(d["run"], "env"))

    # 3. the snapshotter: SIGTERM through `podman stop`
    snap = name()

    snap_args =
      ["-d"] ++
        worker_mounts(d) ++
        env([
          {"ARB_BRIDGE_ADDR", "localhost"},
          {"ARB_CHANNEL_PORT", port},
          {"ARB_RUN", H.run_id()},
          {"ARB_WORKTREE", @wt},
          {"ARB_SNAPSHOT_INTERVAL_S", "3600"},
          {"HOME", "/tmp"}
        ]) ++ [ctx.image, "tini", "--", "/opt/arbiter/bin/snapshotter"]

    # `--rm` would lose the exit code; the container is removed by exact name below
    flags = base_flags(snap) |> Enum.reject(&(&1 == "--rm"))
    assert {_, 0} = podman(flags ++ snap_args)
    on_exit(fn -> podman(["rm", "-f", snap]) end)

    assert {_, 0} = podman(["stop", "-t", "60", snap])
    assert {"0\n", 0} = podman(["inspect", "--format", "{{.State.ExitCode}}", snap])

    assert_receive {:primary, "checkout", "run-1", bundle}, 10_000
    assert byte_size(bundle) > 0
    assert_received {:pod_channel_upload, "run-1", :checkpoint, {:ok, 200}}
  end
end
