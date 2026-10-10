defmodule Arbiter.NodeAgent.K8s.PodLayoutContractTest do
  @moduledoc """
  K7 (bd-dzyclc): the layout contract between the two implementations of the
  shadow clone (`docs/design/remote-workers.md` §16 K§10.1). `PrivateClone`
  builds it in Elixir on a host; the `seed` script builds it in shell in a pod.
  One fixture goes through both and the results are compared: `git ls-files -s`,
  the work tree, `.git/config` (modulo the lines that name the host: the main
  repo, `origin`, the borrowed object store, the commit identity), the four
  guard files and `git fsck`. The pod builder's read-only mounts must be exactly
  the guard files `PrivateClone.mounts/1` hands a container.
  """
  use ExUnit.Case, async: false

  import Arbiter.Test.K8sPodFixtures, only: [build!: 0, container: 2]

  alias Arbiter.Test.GitFixture
  alias Arbiter.NodeAgent.PodRuntimeHarness, as: H
  alias Arbiter.Worker.PrivateClone

  @moduletag :capture_log
  @moduletag :tmp_dir

  @branch "feature/bd-k7-layout"
  # The one place the two layouts may differ in `.git/config`, and why: the
  # host clone points at its main repo and forge and borrows its objects; the
  # pod has neither (the clone owns its objects, nothing can be fetched, so no
  # `origin` and no upstream tracking), and a pod has no operator identity to copy.
  @host_only_config ~w(arbiter.mainrepo core.alternaterefsprefixes user.name user.email)

  setup %{tmp_dir: tmp} do
    ctx =
      GitFixture.forge_and_checkout(
        %{"README.md" => "readme\n", "lib/a.ex" => "a\n", "bin/run" => "#!/bin/sh\n"},
        parent: tmp
      )

    File.chmod!(Path.join(ctx.checkout, "bin/run"), 0o755)
    GitFixture.git!(ctx.checkout, ["update-index", "--chmod=+x", "bin/run"])
    GitFixture.git!(ctx.checkout, ["commit", "-q", "-m", "exec bit"])
    GitFixture.git!(ctx.checkout, ["push", "-q", "origin", "main"])

    {:ok, host} = PrivateClone.create(ctx.checkout, @branch, "main")
    File.write!(Path.join(host, "lib/b.ex"), "b\n")
    GitFixture.git!(host, ["add", "lib/b.ex"])
    GitFixture.git!(host, ["commit", "-q", "-m", "work"])

    bundle = Path.join(tmp, "contract.bundle")

    GitFixture.git!(host, [
      "bundle",
      "create",
      bundle,
      "refs/heads/#{@branch}",
      "refs/remotes/origin/main"
    ])

    channel =
      H.start!(tmp, %{bundle: bundle}, %{
        "checkout" => %{"branch" => @branch, "base" => "main", "interval_s" => 60}
      })

    work = Path.join(tmp, "work")
    run = Path.join(tmp, "run")
    File.mkdir_p!(work)
    File.mkdir_p!(run)

    env = [
      {"ARB_RUN_DIR", run},
      {"ARB_CA_FILE", channel.ca_file},
      {"ARB_WORK_ROOT", work},
      {"ARB_BRIDGE_ADDR", "localhost"},
      {"ARB_CHANNEL_PORT", Integer.to_string(channel.port)},
      {"ARB_BOOT_NONCE", channel.nonce},
      {"ARB_RUN", H.run_id()},
      {"ARB_SEED_LAYER", Path.join(tmp, "none")},
      {"HOME", tmp}
    ]

    {_, 0} = System.cmd(H.shell(), [H.script("seed")], env: env, stderr_to_stdout: true)
    %{host: host, pod: Path.join(work, "wt")}
  end

  defp git(dir, args), do: GitFixture.git!(dir, args)

  test "the same index and the same work tree", %{host: host, pod: pod} do
    assert git(pod, ["ls-files", "-s"]) == git(host, ["ls-files", "-s"])
    assert git(pod, ["status", "--porcelain"]) == ""
    assert git(host, ["status", "--porcelain"]) == ""
    assert git(pod, ["rev-parse", "HEAD"]) == git(host, ["rev-parse", "HEAD"])
    assert git(pod, ["rev-parse", "--abbrev-ref", "HEAD"]) == @branch

    for rel <- ["README.md", "lib/a.ex", "lib/b.ex", "bin/run"] do
      assert File.read!(Path.join(pod, rel)) == File.read!(Path.join(host, rel))
      assert File.stat!(Path.join(pod, rel)).mode == File.stat!(Path.join(host, rel)).mode
    end

    # the base resolves the same way in both
    for ref <- ["refs/remotes/origin/main", "refs/heads/main"] do
      assert git(pod, ["rev-parse", ref]) == git(host, ["rev-parse", ref])
    end
  end

  test ".git/config matches modulo the host-only lines", %{host: host, pod: pod} do
    assert config(pod) == config(host)
    # and the pod's carries nothing the template does not name
    refute Enum.any?(config(pod), &String.starts_with?(&1, "remote."))
    refute Enum.any?(config(pod), &String.starts_with?(&1, "core.hookspath"))
    refute Enum.any?(config(pod), &String.starts_with?(&1, "core.fsmonitor"))
  end

  test "the four guard files exist in both with the same type and content", %{
    host: host,
    pod: pod
  } do
    {:ok, mounts} = PrivateClone.mounts(host)
    guards = Enum.map(mounts[:readonly_paths], &Path.relative_to(&1, Path.join(host, ".git")))
    assert Enum.sort(guards) == Enum.sort(~w(config hooks commondir objects/info/alternates))

    for guard <- guards do
      h = File.lstat!(Path.join([host, ".git", guard]))
      p = File.lstat!(Path.join([pod, ".git", guard]))
      assert p.type == h.type, "#{guard}: #{p.type} in the pod, #{h.type} on the host"
    end

    assert File.read!(Path.join(pod, ".git/commondir")) ==
             File.read!(Path.join(host, ".git/commondir"))

    assert File.read!(Path.join(pod, ".git/commondir")) == ".\n"
    # hooks: no live hook in either (git's `*.sample` files are inert)
    assert live_hooks(pod) == []
    assert live_hooks(host) == []
    # the one deliberate difference: the clone owns its objects
    assert File.read!(Path.join(pod, ".git/objects/info/alternates")) == ""
    assert File.read!(Path.join(host, ".git/objects/info/alternates")) =~ "/objects\n"
  end

  test "git fsck is clean in both", %{host: host, pod: pod} do
    assert {_, 0} =
             System.cmd("git", ["-C", pod, "fsck", "--strict", "--no-dangling"],
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd("git", ["-C", host, "fsck", "--strict", "--no-dangling"],
               stderr_to_stdout: true
             )

    # the pod borrows nothing: its objects are its own
    assert git(pod, ["count-objects", "-v"]) =~ ~r/^count: [1-9]|^packs: [1-9]/m
  end

  test "the pod builder mounts exactly those guards read-only, for the worker and the snapshotter",
       %{host: host} do
    {:ok, mounts} = PrivateClone.mounts(host)
    expected = Enum.map(mounts[:readonly_paths], &Path.relative_to(&1, Path.join(host, ".git")))

    pod = build!()

    for name <- ["worker", "snapshotter"] do
      ro =
        for %{"subPath" => "wt/.git/" <> guard, "readOnly" => true} <-
              container(pod, name)["volumeMounts"],
            do: guard

      assert Enum.sort(ro) == Enum.sort(expected), "#{name}: #{inspect(ro)}"
    end

    # `.git` itself is a mount point of its own (K1-A8): the parent can be
    # renamed away, the mount point cannot
    worker = container(pod, "worker")["volumeMounts"]
    assert Enum.any?(worker, &(&1["subPath"] == "wt/.git" and not Map.has_key?(&1, "readOnly")))
  end

  defp config(dir) do
    dir
    |> git(["config", "--local", "--list"])
    |> String.split("\n", trim: true)
    |> Enum.reject(fn line ->
      key = line |> String.split("=", parts: 2) |> hd()
      key in @host_only_config or String.starts_with?(key, ["remote.", "branch."])
    end)
    |> Enum.sort()
  end

  defp live_hooks(dir) do
    dir
    |> Path.join(".git/hooks")
    |> File.ls!()
    |> Enum.reject(&String.ends_with?(&1, ".sample"))
  end
end
