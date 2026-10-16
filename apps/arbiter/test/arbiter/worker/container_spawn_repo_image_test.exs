defmodule Arbiter.Worker.ContainerSpawnRepoImageTest do
  @moduledoc """
  KH11 (bd-cexq4j): the dispatch-time image preflight hands the publisher the repo
  it is building for (so the image lands in `<registry>/<repo>/worker`), and plans
  with the repo's configured `image.source`.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.ContainerSpawn

  @digest String.duplicate("a", 64)
  @containerfile "FROM docker.io/library/alpine:3\nRUN echo from-repo\n"

  @moduletag :tmp_dir

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ++
          args,
        stderr_to_stdout: true
      )

    out
  end

  defp repo!(tmp, files) do
    dir = Path.join(tmp, "repo")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])

    for {path, body} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), body)
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  defp registry_node, do: %{id: "n1", caps: %{"image" => "registry"}}

  defp opts(workspace, repo) do
    test = self()

    [
      workspace: workspace,
      repo: repo,
      plan: [
        resolver: fn ref ->
          send(test, {:resolved, ref})
          {:ok, "sha256:" <> @digest}
        end,
        arb_otp: "27.0"
      ],
      publish: [
        stub: fn ctx ->
          send(test, {:published, ctx})
          {:ok, %{ref: "registry.example.com/x/worker@sha256:" <> @digest}}
        end
      ]
    ]
  end

  defp ws(worker), do: %Arbiter.Tasks.Workspace{config: %{"worker" => worker}}

  test "the publish context names the repo", %{tmp_dir: tmp} do
    repo_path = repo!(tmp, %{"README.md" => "hi\n"})

    assert :ok = ContainerSpawn.preflight_image(repo_path, registry_node(), opts(nil, "vstim"))
    assert_received {:published, %{repo: "vstim", repo_path: ^repo_path}}
  end

  test "the repo's image.source decides what is planned", %{tmp_dir: tmp} do
    repo_path = repo!(tmp, %{".arbiter/Containerfile" => @containerfile})
    workspace = ws(%{"repos" => %{"vstim" => %{"image" => %{"source" => "generated"}}}})

    assert :ok =
             ContainerSpawn.preflight_image(repo_path, registry_node(), opts(workspace, "vstim"))

    assert_received {:published, _}
    refute_received {:resolved, "docker.io/library/alpine:3"}

    assert :ok =
             ContainerSpawn.preflight_image(repo_path, registry_node(), opts(workspace, "other"))

    assert_received {:published, _}
    assert_received {:resolved, "docker.io/library/alpine:3"}
  end

  test "a source the repo cannot satisfy is image_unavailable, nothing published", %{tmp_dir: tmp} do
    repo_path = repo!(tmp, %{"README.md" => "hi\n"})
    workspace = ws(%{"repos" => %{"vstim" => %{"image" => %{"source" => "containerfile"}}}})

    assert {:error, {:image_unavailable, {:source_unavailable, :containerfile, _}}} =
             ContainerSpawn.preflight_image(repo_path, registry_node(), opts(workspace, "vstim"))

    refute_received {:published, _}
  end

  test "a node that builds its own image never touches any of this", %{tmp_dir: tmp} do
    repo_path = repo!(tmp, %{"README.md" => "hi\n"})
    build_node = %{id: "n2", caps: %{"image" => "build"}}

    assert :ok = ContainerSpawn.preflight_image(repo_path, build_node, opts(nil, "vstim"))
    refute_received {:published, _}
  end

  describe "source: prebuilt (KH14)" do
    @ci_digest "sha256:" <> String.duplicate("c", 64)

    defp prebuilt_ws do
      ws(%{
        "repos" => %{
          "vstim" => %{
            "image" => %{
              "source" => "prebuilt",
              "ref" => "registry.example.com/ci/app:main",
              "registry" => "registry.example.com/arbiter"
            }
          }
        }
      })
    end

    # A fake skopeo whose image claims `revision` as its build commit.
    defp prebuilt_opts(revision) do
      test = self()

      runner = fn "skopeo", args, _ ->
        send(test, {:skopeo, args})

        labels = %{
          "arbiter.runtime-contract" => "1",
          "org.opencontainers.image.revision" => revision
        }

        {Jason.encode!(%{"Digest" => @ci_digest, "Labels" => labels}), 0}
      end

      opts(prebuilt_ws(), "vstim")
      |> Keyword.update!(:plan, &(&1 ++ [runner: runner, cache_ttl_ms: 0]))
    end

    test "plans the CI image, trusted by digest, and publishes the overlay", %{tmp_dir: tmp} do
      repo_path = repo!(tmp, %{"README.md" => "hi\n"})
      tip = git!(repo_path, ["rev-parse", "HEAD"]) |> String.trim()

      assert :ok = ContainerSpawn.preflight_image(repo_path, registry_node(), prebuilt_opts(tip))

      assert_received {:skopeo, ["inspect" | _] = args}
      assert "docker://registry.example.com/ci/app:main" in args
      assert_received {:published, %{repo: "vstim", repo_path: ^repo_path}}
    end

    test "an image built from an unmerged commit is image_unavailable, nothing published", %{
      tmp_dir: tmp
    } do
      repo_path = repo!(tmp, %{"README.md" => "hi\n"})
      git!(repo_path, ["checkout", "-q", "-b", "feature"])
      File.write!(Path.join(repo_path, "f.txt"), "f\n")
      git!(repo_path, ["add", "-A"])
      git!(repo_path, ["commit", "-q", "-m", "feature work"])
      unmerged = git!(repo_path, ["rev-parse", "HEAD"]) |> String.trim()
      git!(repo_path, ["checkout", "-q", "main"])

      assert {:error, {:image_unavailable, {:prebuilt_not_on_default, %{revision: ^unmerged}}}} =
               ContainerSpawn.preflight_image(
                 repo_path,
                 registry_node(),
                 prebuilt_opts(unmerged)
               )

      refute_received {:published, _}
    end

    test "a node that builds its own image cannot run a prebuilt repo", %{tmp_dir: tmp} do
      repo_path = repo!(tmp, %{"README.md" => "hi\n"})
      build_node = %{id: "n2", caps: %{"image" => "build"}}

      assert {:error, {:image_unavailable, {:prebuilt_needs_registry, "vstim"}}} =
               ContainerSpawn.preflight_image(repo_path, build_node, prebuilt_opts("x"))

      refute_received {:skopeo, _}
      refute_received {:published, _}
    end
  end
end
