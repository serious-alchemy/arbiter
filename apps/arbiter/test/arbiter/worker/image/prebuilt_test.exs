defmodule Arbiter.Worker.Image.PrebuiltTest do
  @moduledoc """
  KH14 (bd-3ojmcv, `docs/design/remote-workers.md` §20.9, OD10): a `prebuilt`
  image is trusted only after its tag is resolved to a digest, it carries the
  runtime-contract label, and its revision is an ancestor of the default branch
  tip. `skopeo` goes through `:runner`; git runs for real against a scratch repo.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Prebuilt
  alias Arbiter.Worker.Image.Registry

  @digest "sha256:" <> String.duplicate("a", 64)
  @moduletag :tmp_dir

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ++
          args,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  # main: c1 <- c2 (tip); feature: c1 <- f1 (never merged).
  defp repo!(tmp) do
    dir = Path.join(tmp, "repo")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "mix.lock"), "%{}\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "c1"])
    c1 = git!(dir, ["rev-parse", "HEAD"])
    git!(dir, ["checkout", "-q", "-b", "feature"])
    File.write!(Path.join(dir, "f.txt"), "f\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "f1"])
    f1 = git!(dir, ["rev-parse", "HEAD"])
    git!(dir, ["checkout", "-q", "main"])
    File.write!(Path.join(dir, "m.txt"), "m\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "c2"])
    c2 = git!(dir, ["rev-parse", "HEAD"])
    {dir, %{c1: c1, c2: c2, f1: f1}}
  end

  defp image(attrs \\ %{}) do
    Map.merge(
      %{
        source: :prebuilt,
        ref: "registry.example.com/vstim/ci:main",
        registry: nil,
        credentials_ref: nil,
        public_ok: false,
        seed: :primary
      },
      attrs
    )
  end

  defp labels(revision, extra \\ %{}) do
    Map.merge(
      %{"arbiter.runtime-contract" => "1", "org.opencontainers.image.revision" => revision},
      extra
    )
  end

  # A fake skopeo answering `inspect` with `labels` and recording each call.
  defp runner(test, labels, digest \\ @digest) do
    fn "skopeo", args, _opts ->
      send(test, {:skopeo, args})
      {Jason.encode!(%{"Digest" => digest, "Labels" => labels}), 0}
    end
  end

  defp opts(test, labels, extra \\ []) do
    Keyword.merge([image: image(), runner: runner(test, labels), cache_ttl_ms: 0], extra)
  end

  describe "plan/3" do
    test "resolves the tag to a digest and pins the plan on it", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)

      assert {:ok, plan} = Prebuilt.plan(repo, "main", opts(self(), labels(sha.c2)))
      assert plan.source == :prebuilt
      assert plan.tag == "registry.example.com/vstim/ci@" <> @digest
      assert plan.containerfile == "FROM registry.example.com/vstim/ci@#{@digest}\n"
      assert plan.prebuilt.digest == @digest
      assert plan.prebuilt.revision == sha.c2
      assert plan.prebuilt.seed == :primary
      assert_received {:skopeo, ["inspect" | rest]}
      assert "docker://registry.example.com/vstim/ci:main" in rest
    end

    test "the plan's pinned tag round-trips through RunSpec validation", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      {:ok, plan} = Prebuilt.plan(repo, "main", opts(self(), labels(sha.c2)))

      spec = %{
        "version" => 1,
        "run" => "run-1",
        "task" => "bd-abc",
        "name" => "arb-bd-abc-1234",
        "install" => "inst1",
        "image" => %{"tag" => plan.tag, "plan" => nil},
        "cwd" => "/work/tree",
        "mounts" => [%{"kind" => "worktree", "path" => "/work/tree"}],
        "command" => ["/bin/true"]
      }

      assert {:ok, %{image: %{tag: tag}}} = Arbiter.NodeAgent.RunSpec.validate(spec)
      assert tag == plan.tag
    end

    test "an older ancestor of the default tip is accepted", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      assert {:ok, plan} = Prebuilt.plan(repo, "main", opts(self(), labels(sha.c1)))
      assert plan.prebuilt.revision == sha.c1
    end

    test "the tag moving to another digest changes the plan's tag and hash", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      other = "sha256:" <> String.duplicate("b", 64)

      {:ok, a} = Prebuilt.plan(repo, "main", opts(self(), labels(sha.c2)))

      {:ok, b} =
        Prebuilt.plan(
          repo,
          "main",
          image: image(),
          runner: runner(self(), labels(sha.c2), other),
          cache_ttl_ms: 0
        )

      assert a.hash != b.hash
      assert b.tag == "registry.example.com/vstim/ci@" <> other
    end

    test "a revision that is not an ancestor of the default tip is refused", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)

      assert {:error, {:prebuilt_not_on_default, detail}} =
               Prebuilt.plan(repo, "main", opts(self(), labels(sha.f1)))

      assert detail.revision == sha.f1
      assert detail.branch == "main"
    end

    test "a revision the clone does not know is refused", %{tmp_dir: tmp} do
      {repo, _} = repo!(tmp)

      assert {:error, {:prebuilt_not_on_default, _}} =
               Prebuilt.plan(repo, "main", opts(self(), labels(String.duplicate("e", 40))))
    end

    test "a revision label that is not a commit id is refused, never passed to git", %{
      tmp_dir: tmp
    } do
      {repo, _} = repo!(tmp)

      assert {:error, {:contract_mismatch, missing}} =
               Prebuilt.plan(repo, "main", opts(self(), labels("--upload-pack=evil")))

      assert missing =~ "org.opencontainers.image.revision"
    end

    test "an image without the runtime-contract label is refused, naming it", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      no_contract = Map.delete(labels(sha.c2), "arbiter.runtime-contract")

      assert {:error, {:contract_mismatch, missing}} =
               Prebuilt.plan(repo, "main", opts(self(), no_contract))

      assert missing =~ "arbiter.runtime-contract=1"
    end

    test "a contract label of another version is refused", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      wrong = labels(sha.c2, %{"arbiter.runtime-contract" => "2"})
      assert {:error, {:contract_mismatch, _}} = Prebuilt.plan(repo, "main", opts(self(), wrong))
    end

    test "an image without a revision label is refused, naming it", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      bare = Map.delete(labels(sha.c2), "org.opencontainers.image.revision")

      assert {:error, {:contract_mismatch, missing}} =
               Prebuilt.plan(repo, "main", opts(self(), bare))

      assert missing =~ "org.opencontainers.image.revision"
    end

    test "an image with no labels at all is refused", %{tmp_dir: tmp} do
      {repo, _} = repo!(tmp)
      assert {:error, {:contract_mismatch, _}} = Prebuilt.plan(repo, "main", opts(self(), nil))
    end

    test "no ref is source_unavailable", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)

      assert {:error, {:source_unavailable, :prebuilt, _}} =
               Prebuilt.plan(
                 repo,
                 "main",
                 opts(self(), labels(sha.c2), image: image(%{ref: nil}))
               )
    end

    test "a registry failure is image_unavailable material, not a crash", %{tmp_dir: tmp} do
      {repo, _} = repo!(tmp)
      failing = fn "skopeo", _args, _ -> {"unauthorized: authentication required", 1} end

      assert {:error, {:prebuilt_unresolvable, ref, reason}} =
               Prebuilt.plan(repo, "main", image: image(), runner: failing, cache_ttl_ms: 0)

      assert ref == "registry.example.com/vstim/ci:main"
      assert reason =~ "unauthorized"
    end

    test "falls back to podman when skopeo is not installed", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      test = self()

      runner = fn
        "skopeo", _args, _ ->
          {"skopeo: not found", 127}

        "podman", ["pull" | _] = args, _ ->
          send(test, {:podman, args})
          {"", 0}

        "podman", ["image", "inspect" | _] = args, _ ->
          send(test, {:podman, args})
          {Jason.encode!([%{"Digest" => @digest, "Labels" => labels(sha.c2)}]), 0}
      end

      assert {:ok, plan} =
               Prebuilt.plan(repo, "main", image: image(), runner: runner, cache_ttl_ms: 0)

      assert plan.prebuilt.digest == @digest
      assert_received {:podman, ["pull" | _]}
    end

    test "a registry login travels as an auth file, never on argv", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      test = self()

      cfg = %Registry{
        registry: "registry.example.com/vstim",
        host: "registry.example.com",
        username: "bot",
        password: "hunter2-NEVER-ON-ARGV",
        origin: :config
      }

      runner = fn "skopeo", args, _ ->
        auth = Enum.at(args, Enum.find_index(args, &(&1 == "--authfile")) + 1)
        send(test, {:args, args, File.read!(auth)})
        {Jason.encode!(%{"Digest" => @digest, "Labels" => labels(sha.c2)}), 0}
      end

      assert {:ok, _} =
               Prebuilt.plan(
                 repo,
                 "main",
                 image: image(),
                 registry: cfg,
                 runner: runner,
                 scratch: Path.join(tmp, "scratch"),
                 cache_ttl_ms: 0
               )

      assert_received {:args, args, auth_json}
      refute Enum.any?(args, &String.contains?(&1, "hunter2"))
      assert auth_json =~ Base.encode64("bot:hunter2-NEVER-ON-ARGV")
    end

    test "the resolution is cached for a few minutes, the ancestry check is not", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      ref = "registry.example.com/vstim/cached-#{System.unique_integer([:positive])}:main"
      opts = [image: image(%{ref: ref}), runner: runner(self(), labels(sha.c2))]

      assert {:ok, _} = Prebuilt.plan(repo, "main", opts)
      assert {:ok, _} = Prebuilt.plan(repo, "main", opts)
      assert_received {:skopeo, _}
      refute_received {:skopeo, _}

      # The cached labels are re-judged against the clone every time: c2 is not on `feature`.
      assert {:error, {:prebuilt_not_on_default, _}} = Prebuilt.plan(repo, "feature", opts)
      refute_received {:skopeo, _}
    end
  end

  describe "seed modes" do
    defp lock_hash(dir),
      do:
        :crypto.hash(:sha256, File.read!(Path.join(dir, "mix.lock")))
        |> Base.encode16(case: :lower)

    test "seed: image keeps the image's seed when its arbiter.seed-lock matches mix.lock", %{
      tmp_dir: tmp
    } do
      {repo, sha} = repo!(tmp)
      l = labels(sha.c2, %{"arbiter.seed-lock" => lock_hash(repo)})

      assert {:ok, plan} =
               Prebuilt.plan(repo, "main", opts(self(), l, image: image(%{seed: :image})))

      assert plan.prebuilt.seed == :image
      assert plan.prebuilt.seed_note == nil
    end

    test "seed: image falls back to primary on a lock mismatch, and says so", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      l = labels(sha.c2, %{"arbiter.seed-lock" => String.duplicate("0", 64)})

      assert {:ok, plan} =
               Prebuilt.plan(repo, "main", opts(self(), l, image: image(%{seed: :image})))

      assert plan.prebuilt.seed == :primary
      assert plan.prebuilt.seed_note =~ "arbiter.seed-lock"
    end

    test "seed: image falls back to primary when the label is missing", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)

      assert {:ok, plan} =
               Prebuilt.plan(
                 repo,
                 "main",
                 opts(self(), labels(sha.c2), image: image(%{seed: :image}))
               )

      assert plan.prebuilt.seed == :primary
      assert plan.prebuilt.seed_note =~ "arbiter.seed-lock"
    end

    test "seed: none and seed: primary are taken as configured", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)

      for seed <- [:none, :primary] do
        assert {:ok, plan} =
                 Prebuilt.plan(
                   repo,
                   "main",
                   opts(self(), labels(sha.c2), image: image(%{seed: seed}))
                 )

        assert plan.prebuilt.seed == seed
      end
    end

    test "the seed mode is part of the plan's hash", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      {:ok, a} = Prebuilt.plan(repo, "main", opts(self(), labels(sha.c2)))

      {:ok, b} =
        Prebuilt.plan(repo, "main", opts(self(), labels(sha.c2), image: image(%{seed: :none})))

      assert a.hash != b.hash
    end
  end

  describe "Image.plan/3" do
    test "source: :prebuilt delegates to Prebuilt instead of refusing", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)

      assert {:ok, %{source: :prebuilt}} =
               Image.plan(repo, "main", [source: :prebuilt] ++ opts(self(), labels(sha.c2)))
    end
  end

  describe "check/4" do
    test "check/4 reports what the doctor shows, without a run", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)

      assert %{status: :ok, digest: @digest, revision: revision, seed: :primary} =
               Prebuilt.check(repo, "main", image(),
                 runner: runner(self(), labels(sha.c2)),
                 cache_ttl_ms: 0
               )

      assert revision == sha.c2

      assert %{status: :error, error: error} =
               Prebuilt.check(repo, "main", image(),
                 runner: runner(self(), labels(sha.f1)),
                 cache_ttl_ms: 0
               )

      assert error =~ "ancestor"
    end
  end

  describe "report/1" do
    defp workspace(name, repo, repo_path, image) do
      %Arbiter.Tasks.Workspace{
        name: name,
        config: %{
          "repo_paths" => %{repo => repo_path},
          "worker" => %{"repos" => %{repo => %{"image" => image}}}
        }
      }
    end

    test "one row per prebuilt repo; other sources are not listed", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      prebuilt = %{"source" => "prebuilt", "ref" => "registry.example.com/vstim/ci:main"}

      workspaces = [
        workspace("w1", "vstim", repo, prebuilt),
        workspace("w2", "other", repo, %{"source" => "generated"})
      ]

      assert [row] =
               Prebuilt.report(
                 workspaces: workspaces,
                 runner: runner(self(), labels(sha.c2)),
                 cache_ttl_ms: 0
               )

      assert %{
               workspace: "w1",
               repo: "vstim",
               status: "ok",
               digest: @digest,
               seed: "primary",
               error: nil
             } = row

      assert row.revision == sha.c2
      assert Jason.encode!(row)
    end

    test "a refused image is an error row naming why", %{tmp_dir: tmp} do
      {repo, sha} = repo!(tmp)
      prebuilt = %{"source" => "prebuilt", "ref" => "registry.example.com/vstim/ci:main"}

      assert [%{status: "error", error: error}] =
               Prebuilt.report(
                 workspaces: [workspace("w1", "vstim", repo, prebuilt)],
                 runner: runner(self(), labels(sha.f1)),
                 cache_ttl_ms: 0
               )

      assert error =~ "ancestor"
    end

    test "a repo with no checkout is an error row, not a crash" do
      prebuilt = %{"source" => "prebuilt", "ref" => "registry.example.com/vstim/ci:main"}

      ws = %Arbiter.Tasks.Workspace{
        name: "w1",
        config: %{"worker" => %{"repos" => %{"ghost" => %{"image" => prebuilt}}}}
      }

      assert [%{status: "error", error: error}] = Prebuilt.report(workspaces: [ws])
      assert error =~ "not registered"
    end
  end
end
