defmodule Arbiter.Worker.Image.PullCredentialTest do
  @moduledoc """
  SI4 (`docs/design/remote-workers.md` §21.4): the read credential a machine node is
  handed for one pull, and the reach rule. A node gets a credential only when every
  repository it can read holds runs that node may take: a repo-level one always, a
  workspace-level one when the node's pin (and the workspace's node allowlist) admits
  that workspace, the install-wide pair only for an unpinned node no workspace's
  allowlist excludes, and only for `nodes.registry`'s own host. The push credential is
  never the answer, whatever is or is not configured.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PullAuth
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Image.PullCredential

  @push_install "PUSH-install-NEVER-ON-A-NODE"
  @pull_install "PULL-install-read-only"
  @install %{
    registry: "install.example.com/arb",
    username: "pusher",
    password: @push_install,
    pull_username: "reader",
    pull_password: @pull_install
  }
  @push_repo "PUSH-repo-gitlab-NEVER-ON-A-NODE"

  defp workspace(worker, secrets \\ %{}, id \\ "ws-1") do
    %Workspace{
      id: id,
      config: %{"worker" => worker},
      encrypted_secrets:
        secrets |> :erlang.term_to_binary() |> Arbiter.Vault.encrypt!() |> Base.encode64()
    }
  end

  defp row(pins \\ [], extra \\ %{}),
    do:
      Map.merge(
        %{id: "n1", name: "oryx", kind: :machine, labels: ["gpu=no"], workspace_ids: pins},
        extra
      )

  defp opts(extra \\ []), do: Keyword.merge([config: @install, workspaces: []], extra)

  # A workspace whose repo vstim has its own registry, push and pull credentials.
  defp gitlab_ws(pull_value \\ "deploy-read:gl-PULL-only", extra_image \\ %{}) do
    workspace(
      %{
        "repos" => %{
          "vstim" => %{
            "image" =>
              Map.merge(
                %{
                  "registry" => "registry.gitlab.com/vstim",
                  "credentials_ref" => "secret:GL_PUSH",
                  "pull_credentials_ref" => "secret:GL_PULL"
                },
                extra_image
              )
          }
        }
      },
      %{"GL_PUSH" => "deploy-push:" <> @push_repo, "GL_PULL" => pull_value}
    )
  end

  defp refute_leaks(result) do
    text = inspect(result, limit: :infinity, printable_limit: :infinity)
    for secret <- [@push_install, @push_repo], do: refute(text =~ secret)
  end

  describe "a repo-level credential" do
    test "goes to any node, for that repo's registry host" do
      for pins <- [[], ["ws-1"], ["some-other-workspace"]] do
        assert {:ok, %{auth: auth, level: :repo, insecure?: false}} =
                 PullCredential.for_node(gitlab_ws(), "vstim", row(pins), opts())

        assert auth == %PullAuth{
                 registry: "registry.gitlab.com",
                 username: "deploy-read",
                 password: "gl-PULL-only"
               }
      end
    end

    test "is refused when its secret is missing or not user:password" do
      ws =
        workspace(%{
          "repos" => %{"vstim" => %{"image" => %{"pull_credentials_ref" => "secret:NOPE"}}}
        })

      assert {:error, {:pull_credentials, "secret:NOPE", :secret_not_found}} =
               PullCredential.for_node(ws, "vstim", row(), opts())

      assert {:error, {:pull_credentials, "secret:GL_PULL", :malformed}} =
               PullCredential.for_node(gitlab_ws("no-colon"), "vstim", row(), opts())
    end
  end

  describe "a workspace-level credential" do
    defp ws_level(extra_worker \\ %{}) do
      workspace(
        Map.merge(
          %{
            "image" => %{
              "registry" => "registry.gitlab.com/group",
              "pull_credentials_ref" => "secret:WS_PULL"
            }
          },
          extra_worker
        ),
        %{"WS_PULL" => "group-read:ws-PULL"}
      )
    end

    test "goes to an unpinned node and to one pinned to the workspace" do
      for pins <- [[], ["ws-1"], ["ws-0", "ws-1"]] do
        assert {:ok, %{level: :workspace, auth: %PullAuth{password: "ws-PULL"}}} =
                 PullCredential.for_node(ws_level(), "vstim", row(pins), opts())
      end
    end

    test "never to a node pinned elsewhere, or one the workspace's allowlist leaves out" do
      assert {:error, {:out_of_reach, :workspace}} =
               PullCredential.for_node(ws_level(), "vstim", row(["ws-2"]), opts())

      allowlisted = ws_level(%{"placement_nodes" => ["name:mesaana"]})

      assert {:error, {:out_of_reach, :workspace}} =
               PullCredential.for_node(allowlisted, "vstim", row(), opts())

      assert {:ok, %{level: :workspace}} =
               PullCredential.for_node(
                 allowlisted,
                 "vstim",
                 row([], %{name: "mesaana"}),
                 opts()
               )
    end
  end

  describe "the install-wide pair (nodes.registry_pull_*)" do
    test "reads nodes.registry for an unpinned node" do
      assert {:ok, %{level: :install, auth: auth}} =
               PullCredential.for_node(workspace(%{}), "vstim", row(), opts())

      assert auth == %PullAuth{
               registry: "install.example.com",
               username: "reader",
               password: @pull_install
             }
    end

    test "never goes to a pinned node: it reads every workspace's images" do
      for pins <- [["ws-1"], ["ws-9"]] do
        assert {:error, {:out_of_reach, :install}} =
                 PullCredential.for_node(workspace(%{}), "vstim", row(pins), opts())
      end
    end

    test "never to a node some workspace's allowlist keeps its runs off" do
      fenced = workspace(%{"placement_nodes" => ["label:secure=yes"]}, %{}, "ws-fenced")

      assert {:error, {:out_of_reach, :install}} =
               PullCredential.for_node(
                 workspace(%{}),
                 "vstim",
                 row(),
                 opts(workspaces: [fenced])
               )

      assert {:ok, %{level: :install}} =
               PullCredential.for_node(
                 workspace(%{}),
                 "vstim",
                 row([], %{labels: ["secure=yes"]}),
                 opts(workspaces: [fenced])
               )
    end

    test "when the workspaces cannot be read, it is not handed out" do
      assert {:error, {:out_of_reach, :install}} =
               PullCredential.for_node(
                 workspace(%{}),
                 "vstim",
                 row(),
                 opts(workspaces: fn -> raise "db down" end)
               )
    end

    test "serves a repo registry on nodes.registry's own host, never another host" do
      same_host = workspace(%{"image" => %{"registry" => "install.example.com/team"}})

      assert {:ok, %{level: :install, auth: %PullAuth{registry: "install.example.com"}}} =
               PullCredential.for_node(same_host, "vstim", row(), opts())

      other_host = workspace(%{"image" => %{"registry" => "registry.gitlab.com/team"}})

      assert {:error, :no_pull_credential} =
               PullCredential.for_node(other_host, "vstim", row(), opts())
    end
  end

  describe "no pull credential" do
    test "is no_pull_credential: the push credential is never handed out instead" do
      no_pull = Map.drop(@install, [:pull_username, :pull_password])

      result = PullCredential.for_node(workspace(%{}), "vstim", row(), opts(config: no_pull))
      assert result == {:error, :no_pull_credential}
      refute_leaks(result)

      push_only =
        workspace(
          %{
            "image" => %{
              "registry" => "registry.gitlab.com/vstim",
              "credentials_ref" => "secret:GL_PUSH"
            }
          },
          %{"GL_PUSH" => "deploy-push:" <> @push_repo}
        )

      result = PullCredential.for_node(push_only, "vstim", row(), opts())
      assert result == {:error, :no_pull_credential}
      refute_leaks(result)
    end

    test "a registry marked public_ok is pulled anonymously" do
      public = workspace(%{"image" => %{"registry" => "ghcr.io/acme", "public_ok" => true}})

      assert {:ok, %{level: :anonymous, auth: nil}} =
               PullCredential.for_node(public, "vstim", row(["ws-7"]), opts())
    end

    test "no registry at all is no_registry" do
      assert {:error, :no_registry} =
               PullCredential.for_node(workspace(%{}), "vstim", row(), opts(config: %{}))
    end
  end

  describe "never the push credential" do
    test "a pull secret whose token is the repo's push token is refused" do
      result =
        PullCredential.for_node(gitlab_ws("deploy-read:" <> @push_repo), "vstim", row(), opts())

      assert result == {:error, :pull_credential_is_push_credential}
      refute_leaks(result)
    end

    test "a pull token that is the install-wide push token is refused" do
      install = Map.put(@install, :pull_password, @push_install)
      result = PullCredential.for_node(workspace(%{}), "vstim", row(), opts(config: install))
      assert result == {:error, :pull_credential_is_push_credential}
      refute_leaks(result)

      ws_token = gitlab_ws("deploy-read:" <> @push_install)
      result = PullCredential.for_node(ws_token, "vstim", row(), opts())
      assert result == {:error, :pull_credential_is_push_credential}
    end

    test "what is handed out holds no push credential, and never prints its password" do
      assert {:ok, result} = PullCredential.for_node(gitlab_ws(), "vstim", row(), opts())
      refute_leaks(result)
      refute inspect(result) =~ "gl-PULL-only"
      refute Jason.encode!(result.auth) =~ @push_repo
    end
  end

  test "an insecure registry says so, for the node's --tls-verify=false" do
    install = Map.put(@install, :insecure?, true)

    assert {:ok, %{insecure?: true}} =
             PullCredential.for_node(workspace(%{}), "vstim", row(), opts(config: install))
  end

  test "a node row with no pins is looked up; an unknown node gets no shared credential" do
    bare = Map.delete(row(), :workspace_ids)

    assert {:ok, %{level: :install}} =
             PullCredential.for_node(
               workspace(%{}),
               "vstim",
               bare,
               opts(node_lookup: fn "n1" -> %{workspace_ids: []} end)
             )

    assert {:error, {:out_of_reach, :install}} =
             PullCredential.for_node(
               workspace(%{}),
               "vstim",
               bare,
               opts(node_lookup: fn "n1" -> nil end)
             )

    # a repo-level credential needs no pins
    assert {:ok, %{level: :repo}} =
             PullCredential.for_node(
               gitlab_ws(),
               "vstim",
               bare,
               opts(node_lookup: fn _ -> nil end)
             )
  end
end
