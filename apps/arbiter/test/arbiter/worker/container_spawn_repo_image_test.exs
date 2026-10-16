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
end
