defmodule Arbiter.Worker.PrivateClonePodmanTest do
  @moduledoc """
  bd-4wy1w1 (P5): git layout B inside a REAL rootless podman container, with
  exactly the mount set `PrivateClone.mounts/1` hands `Container.wrap/2`.

    * The P1 spike's sibling-ref probe, inverted: in layout A (a registered
      worktree with the common dir mounted) `git update-ref
      refs/heads/<sibling>` rewrote a sibling worktree's branch. Here the
      worker commits in its clone and cannot change a single ref, config,
      hook or object of the main repo, nor plant anything (config, hook,
      alternates, `commondir`, a `gitdir:` file) that host-side git would
      later run.
    * `git gc --prune=now` in the main repo while a container is reading the
      history it borrows: the pins hold it (and, as a control, without them
      the same gc breaks the running container).

  Opt-in (`@moduletag :podman`): needs a ready rootless podman, the local
  `docker.io/library/debian:12` image, and network for one `apt-get install
  git` into a throwaway image it removes again by exact tag:

      cd apps/arbiter && mix test --include podman test/arbiter/worker/private_clone_podman_test.exs

  Every container is named `arb-test-…` and removed by that exact name.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.PrivateClone

  import GitFixture, only: [git!: 2]

  @moduletag :podman
  @moduletag timeout: 600_000

  @base_image "docker.io/library/debian:12"
  @branch "feature/bd-p5-podman"

  setup_all do
    {_, 0} = System.cmd("podman", ["image", "exists", @base_image])
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) |> String.downcase()
    tag = "localhost/arb-test-git:p5-#{suffix}"
    dir = Path.join(System.tmp_dir!(), "arb-p5-img-#{suffix}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "Containerfile"), """
    FROM #{@base_image}
    RUN apt-get update && apt-get install -y --no-install-recommends git \\
     && rm -rf /var/lib/apt/lists/*
    """)

    {out, status} =
      System.cmd("podman", ["build", "--pull=never", "-q", "-t", tag, dir],
        stderr_to_stdout: true
      )

    File.rm_rf!(dir)
    if status != 0, do: raise("could not build the git test image: #{out}")

    on_exit(fn -> System.cmd("podman", ["rmi", "--force", tag], stderr_to_stdout: true) end)
    %{image: tag}
  end

  setup ctx do
    fixture = GitFixture.forge_and_checkout(%{"README.md" => "readme\n", "lib/a.ex" => "a\n"})
    git!(fixture.checkout, ["branch", "feature/sibling"])
    {:ok, path} = PrivateClone.create(fixture.checkout, @branch, "main")
    name = Container.name_for("test-p5-#{System.unique_integer([:positive])}")
    on_exit(fn -> Container.stop(name) end)
    Map.merge(fixture, %{path: path, name: name, image: ctx.image})
  end

  defp run_in_clone(ctx, script, extra \\ []) do
    {:ok, mounts} = PrivateClone.mounts(ctx.path)

    Container.run(
      ["bash", "-c", script],
      Keyword.merge(mounts, [name: ctx.name, image: ctx.image, timeout: 120_000] ++ extra)
    )
  end

  defp refs(repo), do: git!(repo, ["for-each-ref", "--format=%(objectname) %(refname)"])

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path))

  test "the worker commits in its clone and can change nothing of the main repo", ctx do
    main_git = Path.join(ctx.checkout, ".git")
    dot_git = Path.join(ctx.path, ".git")
    refs_before = refs(ctx.checkout)
    config_before = sha256(Path.join(dot_git, "config"))
    main_config_before = sha256(Path.join(main_git, "config"))
    {:ok, mounts} = PrivateClone.mounts(ctx.path)
    objects = mounts[:objects]

    script = """
    cd #{ctx.path}
    echo work > work.txt && git add work.txt && git commit -qm "container commit" && echo COMMIT_OK
    git update-ref refs/heads/feature/sibling HEAD && echo CLONE_REF_OK
    git --git-dir=#{main_git} update-ref refs/heads/feature/sibling HEAD 2>/dev/null; echo "main_update_ref=$?"
    git -C #{ctx.checkout} branch -f feature/sibling HEAD 2>/dev/null; echo "main_branch_f=$?"
    printf x > #{main_git}/refs/heads/feature/sibling 2>/dev/null; echo "main_ref_write=$?"
    printf x > #{main_git}/packed-refs 2>/dev/null; echo "main_packed_refs=$?"
    touch #{objects}/planted 2>/dev/null; echo "objects_write=$?"
    git config core.fsmonitor "touch /tmp/pwned" 2>/dev/null; echo "config_write=$?"
    printf '#!/bin/sh\\n' > .git/hooks/post-merge 2>/dev/null; echo "hook_write=$?"
    printf '/etc\\n' > .git/objects/info/alternates 2>/dev/null; echo "alternates_write=$?"
    printf '/tmp/fake\\n' > .git/commondir 2>/dev/null; echo "commondir_write=$?"
    mv .git .git-moved 2>/dev/null; echo "gitdir_move=$?"
    """

    assert {:ok, {out, 0}} = run_in_clone(ctx, script)

    assert out =~ "COMMIT_OK"
    # The probe that succeeded against layout A succeeds here too, but only
    # writes the clone's own ref.
    assert out =~ "CLONE_REF_OK"

    for probe <-
          ~w(main_update_ref main_branch_f main_ref_write main_packed_refs config_write hook_write alternates_write commondir_write gitdir_move) do
      refute out =~ "#{probe}=0", "#{probe} succeeded inside the container:\n#{out}"
    end

    # Writes into the borrowed objects land in the overlay's throwaway layer.
    refute File.exists?(Path.join(objects, "planted"))

    # Nothing of the main repo moved.
    assert refs(ctx.checkout) == refs_before
    assert sha256(Path.join(main_git, "config")) == main_config_before

    # Nothing host-side git would run was planted in the clone.
    assert sha256(Path.join(dot_git, "config")) == config_before
    assert File.read!(Path.join(dot_git, "commondir")) == ".\n"
    assert File.read!(Path.join(dot_git, "objects/info/alternates")) == objects <> "\n"
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(dot_git)

    assert File.ls!(Path.join(dot_git, "hooks")) |> Enum.reject(&String.ends_with?(&1, ".sample")) ==
             []

    # The container's commit reaches the main repo only through sync-back.
    head = git!(ctx.path, ["rev-parse", "HEAD"])
    assert git!(ctx.path, ["log", "-1", "--format=%s"]) == "container commit"
    assert {:ok, ^head} = PrivateClone.sync_back(ctx.path)
    assert git!(ctx.checkout, ["rev-parse", "refs/heads/" <> @branch]) == head
    # Sync-back carries the task branch only, not the clone's sibling ref.
    refute git!(ctx.checkout, ["rev-parse", "refs/heads/feature/sibling"]) == head
  end

  # bd-6t7u81 (#390): the K1 spike's probe. With only the four guard files
  # bound read-only (no mount of `.git` itself), `mv .git .git2` succeeds and
  # the worker can recreate `.git` with its own config and hooks. The mount set
  # `PrivateClone.mounts/1` returns binds `.git` too, so the rename fails
  # `EBUSY`; whatever the worker then manages to write, nothing host-side runs.
  test "mv .git .git2 and a recreated .git with fsmonitor and hooks never run host-side", ctx do
    dot_git = Path.join(ctx.path, ".git")
    marker = Path.join(System.tmp_dir!(), "arb-6t7u81-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(marker) end)

    script = """
    cd #{ctx.path}
    mv .git .git2 2>/dev/null; echo "gitdir_move=$?"
    mkdir .git 2>/dev/null; echo "gitdir_mkdir=$?"
    git config core.fsmonitor "touch #{marker}" 2>/dev/null; echo "config_write=$?"
    printf '#!/bin/sh\\ntouch #{marker}\\n' > .git/hooks/reference-transaction 2>/dev/null
    echo "hook_write=$?"
    ls -a . | tr '\\n' ' '
    """

    assert {:ok, {out, 0}} = run_in_clone(ctx, script)
    assert out =~ "gitdir_move=1"
    refute out =~ "config_write=0"
    refute out =~ "hook_write=0"
    refute File.exists?(Path.join(ctx.path, ".git2"))

    # Host side, the clone is what it was: verified, and git in it runs nothing.
    assert :ok = PrivateClone.verify(ctx.path)
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(dot_git)
    git!(ctx.path, ["status", "--porcelain"])
    git!(ctx.path, ["update-ref", "refs/heads/#{@branch}", "HEAD"])
    assert {:ok, _} = PrivateClone.sync_back(ctx.path)
    refute File.exists?(marker)
  end

  # The same probe without the `.git` mount, as the spike ran it (and as a
  # shadow clone mounted by something else than `mounts/1` would be): the
  # rename succeeds, and `reclaim/1` is what keeps the host from trusting it.
  test "without the .git mount the rename succeeds, and the host reclaims the real .git", ctx do
    marker = Path.join(System.tmp_dir!(), "arb-6t7u81-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(marker) end)
    {:ok, mounts} = PrivateClone.mounts(ctx.path)

    script = """
    cd #{ctx.path}
    mv .git .git2 && echo MOVED
    mkdir -p .git/hooks .git/objects/info .git/refs
    cp .git2/HEAD .git2/commondir .git/ && cp .git2/objects/info/alternates .git/objects/info/
    cp .git2/config .git/config
    printf '[core]\\n\\tfsmonitor = touch #{marker}; echo\\n' >> .git/config
    printf '#!/bin/sh\\ntouch #{marker}\\n' > .git/hooks/reference-transaction
    chmod +x .git/hooks/reference-transaction
    echo SWAPPED
    """

    assert {:ok, {out, 0}} =
             run_in_clone(ctx, script, git_dir: nil)

    assert out =~ "MOVED"
    assert out =~ "SWAPPED"
    assert mounts[:git_dir] == Path.join(ctx.path, ".git")
    assert {:error, {:tampered, _}} = PrivateClone.verify(ctx.path)
    assert {:error, {:tampered, _}} = PrivateClone.sync_back(ctx.path)
    refute File.exists?(marker)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:tampered, _}} = PrivateClone.reclaim(ctx.path)
    end)

    assert :ok = PrivateClone.verify(ctx.path)
    git!(ctx.path, ["status", "--porcelain"])
    git!(ctx.path, ["update-ref", "refs/heads/#{@branch}", "HEAD"])
    refute File.exists?(marker)
  end

  # The container reads its borrowed history, signals, waits for the host to
  # rewrite main and gc it with no grace period, then reads again.
  defp gc_during_run(ctx) do
    ready = Path.join(ctx.path, ".probe-ready")
    gc_done = Path.join(ctx.path, ".probe-gc-done")

    script = """
    cd #{ctx.path}
    git log --format=%s | grep -q init && echo BEFORE_OK
    touch #{ready}
    for i in $(seq 1 600); do [ -e #{gc_done} ] && break; sleep 0.1; done
    if git log --format=%s 2>&1 | grep -q init; then echo AFTER_OK; else echo AFTER_BROKEN; fi
    git fsck --connectivity-only --no-dangling >/dev/null 2>&1 && echo FSCK_OK
    exit 0
    """

    task = Task.async(fn -> run_in_clone(ctx, script) end)
    await_file(ready)

    git!(ctx.checkout, ["checkout", "-q", "--orphan", "rewritten"])
    git!(ctx.checkout, ["rm", "-rq", "--cached", "."])
    git!(ctx.checkout, ["commit", "-q", "--allow-empty", "-m", "orphan"])
    git!(ctx.checkout, ["branch", "-q", "-D", "main", "feature/sibling"])
    git!(ctx.checkout, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    System.cmd("git", ["-C", ctx.checkout, "update-ref", "-d", "refs/remotes/origin/HEAD"])
    git!(ctx.checkout, ["reflog", "expire", "--expire=now", "--all"])
    git!(ctx.checkout, ["gc", "-q", "--prune=now"])
    File.write!(gc_done, "")

    assert {:ok, {out, 0}} = Task.await(task, 150_000)
    assert out =~ "BEFORE_OK"
    out
  end

  defp await_file(path, tries \\ 600) do
    cond do
      File.exists?(path) ->
        :ok

      tries == 0 ->
        flunk("#{path} never appeared")

      true ->
        receive do
        after
          100 -> await_file(path, tries - 1)
        end
    end
  end

  test "gc --prune=now in main mid-run cannot pull borrowed history from under the worker",
       ctx do
    out = gc_during_run(ctx)
    assert out =~ "AFTER_OK", out
    assert out =~ "FSCK_OK", out
  end

  # What the container sees after the prune is not deterministic: the `:O`
  # overlay may keep serving a pack the host already deleted from a cached
  # dentry (observed: `git log` still worked while `git fsck` failed), and
  # changing an overlay's lower layer underneath it is undefined behaviour in
  # the kernel's own terms. Borrowed time, not safety. What is deterministic is
  # the host side: the history is gone from the main repo's store, so the
  # clone is broken for every later reader, container or not.
  test "control: the same gc without the pins deletes the history the worker borrows", ctx do
    leaf = Path.basename(ctx.path)
    start = git!(ctx.path, ["rev-parse", "HEAD"])

    for ref <-
          String.split(
            git!(ctx.checkout, [
              "for-each-ref",
              "--format=%(refname)",
              PrivateClone.pin_prefix(leaf)
            ]),
            "\n",
            trim: true
          ),
        do: git!(ctx.checkout, ["update-ref", "-d", ref])

    _out = gc_during_run(ctx)

    assert {_, code} =
             System.cmd("git", ["-C", ctx.checkout, "cat-file", "-e", start <> "^{commit}"],
               stderr_to_stdout: true
             )

    assert code != 0

    assert {_, code} =
             System.cmd("git", ["-C", ctx.path, "log", "--format=%s"], stderr_to_stdout: true)

    assert code != 0
  end
end
