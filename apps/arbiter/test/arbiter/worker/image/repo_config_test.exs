defmodule Arbiter.Worker.Image.RepoConfigTest do
  @moduledoc """
  KH11 (bd-cexq4j, `docs/design/remote-workers.md` §20.9): `worker.repos.<repo>.image`
  deep-merged over a workspace-level `worker.image`, per-repo wins.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image.RepoConfig

  defp ws(worker), do: %{config: %{"worker" => worker}}

  @defaults %{
    source: :auto,
    ref: nil,
    registry: nil,
    credentials_ref: nil,
    pull_credentials_ref: nil,
    pull_credentials_level: nil,
    public_ok: false,
    seed: :primary,
    seed_env: %{}
  }

  describe "resolve/2" do
    test "nothing configured is today's behaviour: source auto, seed primary" do
      for workspace <- [nil, %{config: %{}}, %{config: nil}, ws(%{})] do
        assert RepoConfig.resolve(workspace, "vstim") == @defaults
      end
    end

    test "image.seed_env keeps string pairs and drops the rest" do
      workspace =
        ws(%{
          "repos" => %{
            "vstim" => %{
              "image" => %{"seed_env" => %{"DATABASE_URL" => "ecto://x", "N" => 5, "bad" => [1]}}
            }
          }
        })

      assert RepoConfig.resolve(workspace, "vstim").seed_env == %{
               "DATABASE_URL" => "ecto://x",
               "N" => "5"
             }
    end

    test "a per-repo block is read, with the atoms the pipeline matches on" do
      workspace =
        ws(%{
          "repos" => %{
            "vstim" => %{
              "image" => %{
                "source" => "prebuilt",
                "ref" => "registry.gitlab.com/vstim/app/w:main",
                "registry" => "registry.gitlab.com/vstim/app",
                "credentials_ref" => "secret:GITLAB",
                "seed" => "image"
              }
            }
          }
        })

      assert RepoConfig.resolve(workspace, "vstim") == %{
               source: :prebuilt,
               ref: "registry.gitlab.com/vstim/app/w:main",
               registry: "registry.gitlab.com/vstim/app",
               credentials_ref: "secret:GITLAB",
               pull_credentials_ref: nil,
               pull_credentials_level: nil,
               public_ok: false,
               seed: :image,
               seed_env: %{}
             }

      assert RepoConfig.resolve(workspace, "other") == @defaults
    end

    test "the repo block wins key by key over the workspace-level block" do
      workspace =
        ws(%{
          "image" => %{"registry" => "ghcr.io/ryan/w", "seed" => "none"},
          "repos" => %{"vstim" => %{"image" => %{"seed" => "primary", "source" => "generated"}}}
        })

      assert %{registry: "ghcr.io/ryan/w", seed: :primary, source: :generated} =
               RepoConfig.resolve(workspace, "vstim")

      assert %{registry: "ghcr.io/ryan/w", seed: :none, source: :auto} =
               RepoConfig.resolve(workspace, "other")
    end

    test "matches the repo key the way repo_paths keys match (owner/name -> name)" do
      workspace = ws(%{"repos" => %{"vstim" => %{"image" => %{"source" => "generated"}}}})
      assert %{source: :generated} = RepoConfig.resolve(workspace, "acme/vstim")
    end

    test "a hand-edited malformed value reads as the default" do
      workspace = ws(%{"image" => %{"source" => "bogus", "seed" => 3, "registry" => 4}})
      assert RepoConfig.resolve(workspace, "vstim") == @defaults
      assert RepoConfig.resolve(ws(%{"image" => "x"}), "vstim") == @defaults

      assert RepoConfig.resolve(ws(%{"image" => %{"pull_credentials_ref" => 5}}), "vstim") ==
               @defaults
    end
  end

  # SI4 (§21.4): which level wrote the pull credential decides which nodes may hold it.
  describe "resolve/2: the pull credential and the level it was written at (SI4)" do
    test "a repo's own pull_credentials_ref is :repo" do
      workspace =
        ws(%{"repos" => %{"vstim" => %{"image" => %{"pull_credentials_ref" => "secret:P"}}}})

      assert %{pull_credentials_ref: "secret:P", pull_credentials_level: :repo} =
               RepoConfig.resolve(workspace, "vstim")

      assert %{pull_credentials_ref: nil, pull_credentials_level: nil} =
               RepoConfig.resolve(workspace, "other")
    end

    test "the workspace's is :workspace for every repo that names none, and a repo's wins" do
      workspace =
        ws(%{
          "image" => %{"pull_credentials_ref" => "secret:WS"},
          "repos" => %{"vstim" => %{"image" => %{"pull_credentials_ref" => "secret:OWN"}}}
        })

      assert %{pull_credentials_ref: "secret:WS", pull_credentials_level: :workspace} =
               RepoConfig.resolve(workspace, "other")

      assert %{pull_credentials_ref: "secret:OWN", pull_credentials_level: :repo} =
               RepoConfig.resolve(workspace, "vstim")
    end

    test "a repo with a registry of its own does not inherit the workspace's pull credential" do
      workspace =
        ws(%{
          "image" => %{
            "registry" => "registry.gitlab.com/ws",
            "pull_credentials_ref" => "secret:WS"
          },
          "repos" => %{
            "vstim" => %{"image" => %{"registry" => "ghcr.io/vstim"}},
            "own" => %{
              "image" => %{"registry" => "ghcr.io/own", "pull_credentials_ref" => "secret:OWN"}
            }
          }
        })

      assert %{registry: "ghcr.io/vstim", pull_credentials_ref: nil, pull_credentials_level: nil} =
               RepoConfig.resolve(workspace, "vstim")

      assert %{pull_credentials_ref: "secret:OWN", pull_credentials_level: :repo} =
               RepoConfig.resolve(workspace, "own")
    end
  end

  describe "repository_name/1" do
    test "<repo-slug>/worker" do
      assert RepoConfig.repository_name("vstim") == "vstim/worker"
      assert RepoConfig.repository_name("Acme/My_App") == "acme-my-app/worker"
    end

    test "an unnamed repo is still a repository of its own, never a bare worker" do
      assert RepoConfig.repository_name(nil) == "custom/worker"
      assert RepoConfig.repository_name("") == "custom/worker"
    end
  end
end
