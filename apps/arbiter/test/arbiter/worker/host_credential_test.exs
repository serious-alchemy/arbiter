defmodule Arbiter.Worker.HostCredentialTest do
  @moduledoc """
  The host-side git/forge credential for a repo with a scoped `git_credentials`
  entry (bd-bsmkfu): what the host pushes and opens PRs with when a podman run
  holds no credential of its own.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential.Material
  alias Arbiter.Worker.HostCredential

  @moduletag :tmp_dir

  @http Arbiter.Worker.GitCredential.HTTP

  defp workspace(git_credentials, secrets) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "hc-#{System.unique_integer([:positive])}",
        prefix: "hc",
        config: %{"git_credentials" => git_credentials},
        secrets: secrets
      })

    ws
  end

  defp rsa_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  defp app_ws do
    workspace(
      %{
        "repos" => %{
          "tonic" => %{
            "kind" => "github_app",
            "app_id" => "42",
            "installation_id" => "7",
            "private_key_secret" => "APP_KEY"
          }
        }
      },
      %{"APP_KEY" => rsa_pem()}
    )
  end

  defp stub_mint(token \\ "ghs_host") do
    test_pid = self()

    Req.Test.stub(@http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:mint, conn.request_path, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => token, "expires_at" => "2099-01-01T00:00:00Z"})
    end)
  end

  defp opts(extra \\ []),
    do: [remote: "acme/tonic", req_options: [plug: {Req.Test, @http}]] ++ extra

  setup do
    HostCredential.Cache.clear()
    :ok
  end

  describe "for_repo/3 without a scoped plan" do
    test "a workspace with no git_credentials is the operator's credential" do
      ws = workspace(%{}, %{})
      assert {:ok, nil} = HostCredential.for_repo(ws, "tonic", opts())
    end

    test "a legacy_operator repo is unchanged" do
      ws = workspace(%{"repos" => %{"tonic" => %{"legacy_operator" => true}}}, %{})
      assert {:ok, nil} = HostCredential.for_repo(ws, "tonic", opts())
    end

    test "a repo the block does not name is unchanged" do
      assert {:ok, nil} = HostCredential.for_repo(app_ws(), "other", opts())
    end

    test "no workspace, no repo" do
      assert {:ok, nil} = HostCredential.for_repo(nil, "tonic", opts())
      assert {:ok, nil} = HostCredential.for_repo(app_ws(), nil, opts())
    end
  end

  describe "for_repo/3 with a github_app" do
    test "mints a repo-restricted installation token the host can push and open PRs with" do
      stub_mint()

      assert {:ok, %{material: %Material{kind: :github_app, token: "ghs_host"}} = cred} =
               HostCredential.for_repo(app_ws(), "tonic", opts())

      assert_receive {:mint, "/app/installations/7/access_tokens", body}
      assert body["repositories"] == ["tonic"]
      assert body["permissions"]["contents"] == "write"
      assert body["permissions"]["pull_requests"] == "write"
      refute Map.has_key?(body["permissions"], "administration")

      assert HostCredential.token(cred) == "ghs_host"
    end

    test "the env resets inherited credential helpers and offers no ssh identity" do
      stub_mint()
      {:ok, cred} = HostCredential.for_repo(app_ws(), "tonic", opts())
      env = cred.env

      assert {"ARB_GIT_TOKEN", "ghs_host"} in env
      assert {"GIT_TERMINAL_PROMPT", "0"} in env
      assert {"SSH_AUTH_SOCK", nil} in env
      assert {"GIT_ASKPASS", nil} in env

      {_, params} = List.keyfind(env, "GIT_CONFIG_PARAMETERS", 0)
      assert params =~ "'credential.helper='"
      assert params =~ "credential.useHttpPath=true"
      assert params =~ "acme/tonic"

      {_, ssh} = List.keyfind(env, "GIT_SSH_COMMAND", 0)
      assert ssh =~ "IdentityAgent=none"
      assert ssh =~ "IdentitiesOnly=yes"
      assert ssh =~ "-F /dev/null"
      assert ssh =~ "-i /dev/null"

      names = Enum.map(env, &elem(&1, 0))
      assert names == Enum.uniq(names)
    end

    test "the token is cached, so repeated host operations mint once" do
      stub_mint()
      ws = app_ws()
      assert {:ok, _} = HostCredential.for_repo(ws, "tonic", opts())
      assert {:ok, _} = HostCredential.for_repo(ws, "tonic", opts())
      assert_receive {:mint, _, _}
      refute_receive {:mint, _, _}, 50
    end

    test "a failed mint is an error, never the operator's credential" do
      Req.Test.stub(@http, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, {:git_credential_mint_failed, 404, "Not Found"}} =
               HostCredential.for_repo(app_ws(), "tonic", opts())
    end

    test "a missing private key secret is an error" do
      ws =
        workspace(
          %{
            "repos" => %{
              "tonic" => %{
                "kind" => "github_app",
                "app_id" => "1",
                "installation_id" => "2",
                "private_key_secret" => "GONE"
              }
            }
          },
          %{}
        )

      assert {:error, {:git_credential_secret_missing, "GONE"}} =
               HostCredential.for_repo(ws, "tonic", opts())
    end
  end

  # bd-3llb3y: the worker that held the run's GitLab token is gone by the time the host
  # pushes after `arb done` (its token was revoked at exit), so the host mints its own,
  # for the push, and revokes it again.
  describe "for_repo/3 with a gitlab_project_token" do
    defp gitlab_ws do
      workspace(
        %{
          "repos" => %{
            "tonic" => %{"kind" => "gitlab_project_token", "parent_token_secret" => "GL_PARENT"}
          }
        },
        %{"GL_PARENT" => "glpat-parent-host"}
      )
    end

    defp stub_gitlab do
      test_pid = self()

      Req.Test.stub(@http, fn conn ->
        send(test_pid, {:gitlab, conn.method, URI.decode(conn.request_path)})

        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "id" => 9,
              "token" => "glpat-host-run",
              "scopes" => ["read_api", "write_repository"],
              "access_level" => 30
            })

          "DELETE" ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)
    end

    test "mints a project token for the push, served by the path-pinned helper" do
      stub_gitlab()
      # Not self(): the revoke Task fires when its owner exits, and a test pid's own
      # exit would run it after the stub is gone ("cannot find mock/stub").
      owner = spawn(fn -> receive do: (:stop -> :ok) end)

      assert {:ok,
              %{material: %Material{kind: :gitlab_project_token} = material, env: env} = cred} =
               HostCredential.for_repo(gitlab_ws(), "tonic", opts(owner: owner))

      assert_receive {:gitlab, "POST", "/api/v4/projects/acme/tonic/access_tokens"}
      assert {"ARB_GIT_TOKEN", "glpat-host-run"} in env
      assert {"SSH_AUTH_SOCK", nil} in env
      assert HostCredential.token(cred) == "glpat-host-run"
      assert material.parent_token == "glpat-parent-host"

      Process.exit(owner, :kill)
      assert_receive {:gitlab, "DELETE", _}
    end

    test "the token is revoked when the host's owner exits" do
      stub_gitlab()
      owner = spawn(fn -> receive do: (:stop -> :ok) end)

      assert {:ok, %{}} = HostCredential.for_repo(gitlab_ws(), "tonic", opts(owner: owner))
      assert_receive {:gitlab, "POST", _}
      refute_received {:gitlab, "DELETE", _}

      Process.exit(owner, :kill)
      assert_receive {:gitlab, "DELETE", "/api/v4/projects/acme/tonic/access_tokens/9"}
    end

    test "the token is revoked after the push window even while the owner lives" do
      stub_gitlab()

      assert {:ok, %{}} =
               HostCredential.for_repo(
                 gitlab_ws(),
                 "tonic",
                 opts(owner: self(), revoke_after_ms: 20)
               )

      assert_receive {:gitlab, "DELETE", "/api/v4/projects/acme/tonic/access_tokens/9"}, 2_000
    end
  end

  describe "for_repo/3 with a deploy key" do
    test "stages the key and pins ssh to it with no agent, and resets credential helpers",
         %{tmp_dir: tmp} do
      ws =
        workspace(%{"repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "K"}}}, %{
          "K" => "PEMDATA"
        })

      assert {:ok, cred} = HostCredential.for_repo(ws, "tonic", opts(root: tmp))
      env = cred.env

      {_, ssh} = List.keyfind(env, "GIT_SSH_COMMAND", 0)
      assert ssh =~ "IdentityAgent=none"
      assert ssh =~ Path.join(tmp, "git-key-")
      assert {"SSH_AUTH_SOCK", nil} in env

      {_, params} = List.keyfind(env, "GIT_CONFIG_PARAMETERS", 0)
      assert params =~ "'credential.helper='"
      assert HostCredential.token(cred) == nil
    end
  end
end
