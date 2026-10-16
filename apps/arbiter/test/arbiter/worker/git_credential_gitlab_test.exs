defmodule Arbiter.Worker.GitCredentialGitlabTest do
  @moduledoc """
  bd-3llb3y: the `gitlab_project_token` kind. Arbiter mints a per-run GitLab
  project access token from a primary-only parent credential, restricted to the
  one project (`read_api` + `write_repository`, Developer), delivers it like the
  `github_app` token (local helper, podman secrets, a node's tmpfs secrets file)
  and revokes it when the worker exits. GitLab is stubbed with `Req.Test`; the
  real forge is not exercised here.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.GitCredential.Material

  @http Arbiter.Worker.GitCredential.HTTP
  @parent "glpat-parent-0123456789abcdef"

  defp workspace(entry_extra \\ %{}, secrets \\ %{"GL_PARENT" => @parent}) do
    entry =
      Map.merge(
        %{
          "kind" => "gitlab_project_token",
          "parent_token_secret" => "GL_PARENT",
          "host" => "gitlab.com"
        },
        entry_extra
      )

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gl-#{System.unique_integer([:positive])}",
        prefix: "gl",
        config: %{"git_credentials" => %{"repos" => %{"tonic" => entry}}},
        secrets: secrets
      })

    ws
  end

  defp plan(ws, opts \\ []) do
    {:ok, %GitCredential{mode: :scoped} = plan} =
      GitCredential.plan(ws, "tonic", [role: :implementer, guarded?: true] ++ opts)

    plan
  end

  defp req_options, do: [req_options: [plug: {Req.Test, @http}]]

  # Records every request as `{:gitlab, method, path, private_token, body}` and
  # answers a mint with `mint` and a revoke with `revoke_status`.
  defp stub_gitlab(opts \\ []) do
    test_pid = self()
    mint = Keyword.get(opts, :mint, %{})
    mint_status = Keyword.get(opts, :mint_status, 201)
    revoke_status = Keyword.get(opts, :revoke_status, 204)

    Req.Test.stub(@http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = if body == "", do: nil, else: Jason.decode!(body)

      send(
        test_pid,
        {:gitlab, conn.method, URI.decode(conn.request_path),
         Plug.Conn.get_req_header(conn, "private-token"), decoded}
      )

      case conn.method do
        "POST" ->
          conn
          |> Plug.Conn.put_status(mint_status)
          |> Req.Test.json(
            Map.merge(
              %{
                "id" => 77,
                "token" => "glpat-run-token",
                "scopes" => ["read_api", "write_repository"],
                "access_level" => 30
              },
              mint
            )
          )

        "DELETE" ->
          Plug.Conn.send_resp(conn, revoke_status, "")
      end
    end)
  end

  defp gitlab_material(extra \\ []) do
    struct!(
      Material,
      [
        kind: :gitlab_project_token,
        token: "glpat-run-token",
        token_id: 77,
        parent_token: @parent,
        host: "gitlab.com",
        username: "oauth2",
        remote: "acme/tonic"
      ] ++ extra
    )
  end

  describe "config" do
    test "validates: the parent secret is required" do
      assert :ok =
               GitCredential.validate(%{
                 "repos" => %{
                   "a" => %{"kind" => "gitlab_project_token", "parent_token_secret" => "P"}
                 }
               })

      assert {:error, message} =
               GitCredential.validate(%{"repos" => %{"a" => %{"kind" => "gitlab_project_token"}}})

      assert message =~ "parent_token_secret"
    end

    test "expires_in_days must be a small positive integer" do
      base = %{"kind" => "gitlab_project_token", "parent_token_secret" => "P"}

      for ok <- [1, 2, 7],
          do:
            assert(
              :ok =
                GitCredential.validate(%{
                  "repos" => %{"a" => Map.put(base, "expires_in_days", ok)}
                })
            )

      for bad <- [0, -1, 8, "2", 1.5],
          do:
            assert(
              {:error, _} =
                GitCredential.validate(%{
                  "repos" => %{"a" => Map.put(base, "expires_in_days", bad)}
                })
            )
    end

    test "the GitLab default username is oauth2" do
      assert %GitCredential{entry: %{kind: :gitlab_project_token, username: "oauth2"}} =
               plan(workspace())
    end

    test "a podman run still gets this kind's credential (API access); a static token does not" do
      assert {:ok, %GitCredential{mode: :scoped}} =
               GitCredential.plan(workspace(), "tonic", role: :implementer, host_pushes?: true)

      assert {:ok, %GitCredential{mode: :not_needed}} =
               GitCredential.plan(workspace(), "tonic", role: :reviewer)

      token_ws =
        workspace(%{"kind" => "token", "token_secret" => "GL_PARENT"})

      assert {:ok, %GitCredential{mode: :not_needed}} =
               GitCredential.plan(token_ws, "tonic", role: :implementer, host_pushes?: true)
    end
  end

  describe "materialize/3" do
    test "mints a project access token for the one project, read_api + write_repository only" do
      stub_gitlab()

      assert {:ok,
              %Material{
                kind: :gitlab_project_token,
                token: "glpat-run-token",
                token_id: 77,
                parent_token: @parent,
                host: "gitlab.com",
                username: "oauth2",
                remote: "acme/tonic"
              }} =
               GitCredential.materialize(
                 plan(workspace()),
                 workspace(),
                 [remote: "acme/tonic"] ++ req_options()
               )

      assert_receive {:gitlab, "POST", "/api/v4/projects/acme/tonic/access_tokens", [@parent],
                      body}

      assert body["scopes"] == ["read_api", "write_repository"]
      # Developer: pushes to non-protected branches; never Maintainer/Owner.
      assert body["access_level"] == 30
      assert body["name"] =~ "arbiter"

      today = Date.utc_today()

      assert body["expires_at"] in [
               Date.to_iso8601(Date.add(today, 2)),
               Date.to_iso8601(Date.add(Date.utc_today(), 2))
             ]
    end

    test "the project id is the URL-encoded path (nested groups included)" do
      test_pid = self()

      Req.Test.stub(@http, fn conn ->
        send(test_pid, {:raw_path, conn.request_path})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "id" => 1,
          "token" => "t",
          "scopes" => ["read_api", "write_repository"],
          "access_level" => 30
        })
      end)

      ws = workspace()

      assert {:ok, _} =
               GitCredential.materialize(
                 plan(ws),
                 ws,
                 [remote: "acme/sub/tonic"] ++ req_options()
               )

      assert_receive {:raw_path, "/api/v4/projects/acme%2Fsub%2Ftonic/access_tokens"}
    end

    test "a self-managed api_url is used for the mint and kept on the material" do
      stub_gitlab()

      ws =
        workspace(%{"host" => "git.example.com", "api_url" => "https://git.example.com/api/v4"})

      assert {:ok, %Material{host: "git.example.com", api_url: "https://git.example.com/api/v4"}} =
               GitCredential.materialize(plan(ws), ws, [remote: "acme/tonic"] ++ req_options())

      assert_receive {:gitlab, "POST", "/api/v4/projects/acme/tonic/access_tokens", _, _}
    end

    test "a response that grants more than was asked is revoked and refused" do
      stub_gitlab(mint: %{"scopes" => ["api", "read_api", "write_repository"]})
      ws = workspace()

      assert {:error, {:git_credential_mint_failed, :too_broad, _}} =
               GitCredential.materialize(plan(ws), ws, [remote: "acme/tonic"] ++ req_options())

      assert_receive {:gitlab, "DELETE", "/api/v4/projects/acme/tonic/access_tokens/77",
                      [@parent], nil}
    end

    test "a higher role than Developer is revoked and refused" do
      stub_gitlab(mint: %{"access_level" => 40})
      ws = workspace()

      assert {:error, {:git_credential_mint_failed, :too_broad, _}} =
               GitCredential.materialize(plan(ws), ws, [remote: "acme/tonic"] ++ req_options())

      assert_receive {:gitlab, "DELETE", _, _, _}
    end

    test "a mint failure refuses the spawn and never names a token" do
      stub_gitlab(mint_status: 403, mint: %{"message" => "403 Forbidden"})
      ws = workspace()

      assert {:error, {:git_credential_mint_failed, 403, "403 Forbidden"} = error} =
               GitCredential.materialize(plan(ws), ws, [remote: "acme/tonic"] ++ req_options())

      refute inspect(error) =~ "glpat"
      assert GitCredential.format_error(error) =~ "403"
    end

    test "a missing parent secret is a refusal, never a fallback" do
      ws = workspace(%{}, %{})

      assert {:error, {:git_credential_secret_missing, "GL_PARENT"}} =
               GitCredential.materialize(plan(ws), ws, [remote: "acme/tonic"] ++ req_options())
    end

    test "without a pinned project it refuses rather than mint" do
      ws = workspace()

      assert {:error, :git_credential_remote_unknown} =
               GitCredential.materialize(plan(ws), ws, req_options())
    end
  end

  describe "delivery" do
    test "env: the helper (ARB_GIT_TOKEN) plus GITLAB_TOKEN and GITLAB_HOST for the API" do
      env = Material.env(gitlab_material(), nil)

      assert {"ARB_GIT_TOKEN", "glpat-run-token"} in env
      assert {"GITLAB_TOKEN", "glpat-run-token"} in env
      assert {"GITLAB_HOST", "gitlab.com"} in env
      assert {"GIT_TERMINAL_PROMPT", "0"} in env
      assert {"GIT_CONFIG_PARAMETERS", config} = List.keyfind(env, "GIT_CONFIG_PARAMETERS", 0)
      assert config =~ ~s([ "$p" = "acme/tonic" ])
      assert config =~ "username=oauth2"
      refute inspect(env) =~ "parent"
    end

    test "podman gets the token as two env secrets; neither value is in the container env" do
      secrets = GitCredential.podman_secrets(gitlab_material(), "arb-run")

      assert Enum.sort(Enum.map(secrets, & &1.target)) == ["ARB_GIT_TOKEN", "GITLAB_TOKEN"]
      assert Enum.all?(secrets, &(&1.type == :env and &1.value == "glpat-run-token"))
      assert length(Enum.uniq(Enum.map(secrets, & &1.name))) == 2

      env = GitCredential.container_env(gitlab_material())
      refute inspect(env) =~ "glpat"
      assert {"GITLAB_HOST", "gitlab.com"} in env
    end

    test "a node gets the token only as secrets; the parent credential never leaves" do
      assert {:ok, %{env: env, secrets: secrets}} =
               GitCredential.remote_delivery(gitlab_material())

      assert secrets == %{
               "ARB_GIT_TOKEN" => "glpat-run-token",
               "GITLAB_TOKEN" => "glpat-run-token"
             }

      refute inspect({env, secrets}) =~ "parent"
      refute inspect({env, secrets}) =~ "0123456789abcdef"
      refute List.keymember?(env, "GITLAB_TOKEN", 0)
      assert {"GITLAB_HOST", "gitlab.com"} in env
    end

    test "withheld_values/1 lists the parent credential" do
      assert @parent in GitCredential.withheld_values(workspace())
    end

    test "the output scrubber masks the run token and the parent" do
      redact = GitCredential.redact_values(gitlab_material())
      assert "glpat-run-token" in redact
      assert @parent in redact
    end

    test "inspecting a material never prints a secret" do
      refute inspect(gitlab_material()) =~ "glpat"
    end
  end

  describe "revoking" do
    test "revoke/2 deletes the project access token with the parent credential" do
      stub_gitlab()

      assert :ok = GitCredential.revoke(gitlab_material(), req_options())

      assert_receive {:gitlab, "DELETE", "/api/v4/projects/acme/tonic/access_tokens/77",
                      [@parent], nil}
    end

    test "a token that is already gone (404) counts as revoked" do
      stub_gitlab(revoke_status: 404)
      assert :ok = GitCredential.revoke(gitlab_material(), req_options())
    end

    test "any other answer is an error that names the status, never a token" do
      stub_gitlab(revoke_status: 500)

      assert {:error, {:git_credential_revoke_failed, 500}} =
               result = GitCredential.revoke(gitlab_material(), req_options())

      refute inspect(result) =~ "glpat"
    end

    test "revoke_when_down/3 revokes once the owner exits, however it exits" do
      stub_gitlab()

      for reason <- [:normal, :shutdown, :kill] do
        owner = spawn(fn -> receive do: (:stop -> :ok) end)
        :ok = GitCredential.revoke_when_down(owner, gitlab_material(), req_options())
        refute_received {:gitlab, _, _, _, _}

        if reason == :normal, do: send(owner, :stop), else: Process.exit(owner, reason)

        assert_receive {:gitlab, "DELETE", "/api/v4/projects/acme/tonic/access_tokens/77",
                        [@parent], nil}
      end
    end

    test "revoke_when_down/3 with :max_ms revokes at the deadline even if the owner lives" do
      stub_gitlab()
      owner = spawn(fn -> receive do: (:stop -> :ok) end)

      :ok =
        GitCredential.revoke_when_down(owner, gitlab_material(), [max_ms: 20] ++ req_options())

      assert_receive {:gitlab, "DELETE", _, [@parent], nil}, 2_000
      send(owner, :stop)
    end

    # The production path of a local (non-container) spawn: dispatch's plan, then
    # ClaudeSession's prepare and spawn_env. The worker gets the git helper and the
    # API token, and no operator ssh or glab credential is added.
    test "plan -> prepare -> spawn_env hands a local worker its push and API env" do
      stub_gitlab()
      ws = workspace()
      {:ok, plan} = GitCredential.plan(ws, "tonic", role: :implementer, host_pushes?: false)

      assert {:ok, git} =
               GitCredential.prepare(plan, ws, self(), [remote: "acme/tonic"] ++ req_options())

      assert {:ok, env} = GitCredential.spawn_env(git, %{}, [{"PATH", "/usr/bin"}], [])

      assert {"GITLAB_TOKEN", "glpat-run-token"} in env
      assert {"ARB_GIT_TOKEN", "glpat-run-token"} in env
      assert {"GITLAB_HOST", "gitlab.com"} in env
      refute List.keymember?(env, "SSH_AUTH_SOCK", 0)
      refute inspect(env) =~ @parent
      assert "glpat-run-token" in git.redact
      assert @parent in git.redact
    end

    test "prepare/4 arms the revoke for every spawn, not only a remote one" do
      stub_gitlab()
      ws = workspace()
      owner = spawn(fn -> receive do: (:stop -> :ok) end)

      assert {:ok, %{material: %Material{token: "glpat-run-token"}}} =
               GitCredential.prepare(
                 plan(ws),
                 ws,
                 owner,
                 [remote: "acme/tonic", container?: true] ++ req_options()
               )

      assert_receive {:gitlab, "POST", _, _, _}
      refute_received {:gitlab, "DELETE", _, _, _}

      Process.exit(owner, :kill)
      assert_receive {:gitlab, "DELETE", "/api/v4/projects/acme/tonic/access_tokens/77", _, _}
    end
  end
end
