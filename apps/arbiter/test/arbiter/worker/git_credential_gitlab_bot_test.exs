defmodule Arbiter.Worker.GitCredentialGitlabBotTest do
  @moduledoc """
  bd-8ufzng: the `gitlab_bot_token` kind, for a GitLab Free group that cannot mint
  project access tokens. The operator's bot user holds a long-lived PAT limited to
  its projects by membership; Arbiter delivers it like the minted kinds (local
  helper, podman secrets, a node's tmpfs secrets file) and, because it is static,
  checks it at every dispatch: `GET /personal_access_tokens/self` for scopes and
  expiry, `GET /projects?membership=true` for reach. GitLab is stubbed with
  `Req.Test`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.GitCredential.Material

  @http Arbiter.Worker.GitCredential.HTTP
  @bot "glpat-bot-0123456789abcdef"

  defp workspace(entry_extra \\ %{}, secrets \\ %{"GL_BOT" => @bot}, more_repos \\ %{}) do
    entry =
      Map.merge(
        %{"kind" => "gitlab_bot_token", "secret" => "GL_BOT", "host" => "gitlab.com"},
        entry_extra
      )

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "glb-#{System.unique_integer([:positive])}",
        prefix: "gb",
        config: %{
          "git_credentials" => %{"repos" => Map.merge(%{"tonic" => entry}, more_repos)}
        },
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

  defp in_days(n), do: Date.utc_today() |> Date.add(n) |> Date.to_iso8601()

  # Records every request as `{:gitlab, method, path, query, private_token}`.
  # `self_pat` is the `personal_access_tokens/self` answer (a merge over a clean
  # one); `projects` the project paths the bot is a member of, served `per_page`
  # at a time so pagination is exercised.
  defp stub_gitlab(opts \\ []) do
    test_pid = self()
    pat = Keyword.get(opts, :pat, %{})
    pat_status = Keyword.get(opts, :pat_status, 200)
    projects = Keyword.get(opts, :projects, ["acme/tonic"])
    per_page = Keyword.get(opts, :per_page, 100)

    Req.Test.stub(@http, fn conn ->
      send(
        test_pid,
        {:gitlab, conn.method, conn.request_path, conn.query_string,
         Plug.Conn.get_req_header(conn, "private-token")}
      )

      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/api/v4/personal_access_tokens/self" ->
          conn
          |> Plug.Conn.put_status(pat_status)
          |> Req.Test.json(
            Map.merge(
              %{
                "id" => 5,
                "active" => true,
                "revoked" => false,
                "scopes" => ["read_api", "read_repository", "write_repository"],
                "expires_at" => in_days(60)
              },
              pat
            )
          )

        "/api/v4/projects" ->
          page = String.to_integer(conn.params["page"] || "1")
          slice = projects |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)
          more? = length(projects) > page * per_page

          conn
          |> Plug.Conn.put_resp_header("x-next-page", if(more?, do: "#{page + 1}", else: ""))
          |> Req.Test.json(Enum.map(slice, &%{"path_with_namespace" => &1}))
      end
    end)
  end

  defp materialize(ws, extra \\ []) do
    GitCredential.materialize(plan(ws), ws, [remote: "acme/tonic"] ++ extra ++ req_options())
  end

  defp bot_material(extra \\ []) do
    struct!(
      Material,
      [
        kind: :gitlab_bot_token,
        token: @bot,
        host: "gitlab.com",
        username: "oauth2",
        remote: "acme/tonic"
      ] ++ extra
    )
  end

  describe "config" do
    test "validates: the secret is required, expires_at and projects are shaped" do
      assert :ok =
               GitCredential.validate(%{
                 "repos" => %{
                   "a" => %{
                     "kind" => "gitlab_bot_token",
                     "secret" => "S",
                     "expires_at" => "2027-01-31",
                     "projects" => ["acme/tonic", "acme/tonic_device"]
                   }
                 }
               })

      assert {:error, message} =
               GitCredential.validate(%{"repos" => %{"a" => %{"kind" => "gitlab_bot_token"}}})

      assert message =~ "secret"

      for bad <- [
            %{"expires_at" => "soon"},
            %{"projects" => "acme/tonic"},
            %{"projects" => ["x"]}
          ] do
        entry = Map.merge(%{"kind" => "gitlab_bot_token", "secret" => "S"}, bad)
        assert {:error, _} = GitCredential.validate(%{"repos" => %{"a" => entry}})
      end
    end

    test "the GitLab defaults: host gitlab.com, username oauth2" do
      assert %GitCredential{
               entry: %{kind: :gitlab_bot_token, host: "gitlab.com", username: "oauth2"}
             } =
               plan(workspace(%{"host" => nil}))
    end

    test "a podman run still gets this kind's credential; a reviewer none" do
      ws = workspace()

      assert {:ok, %GitCredential{mode: :scoped, read_only: false}} =
               GitCredential.plan(ws, "tonic", role: :implementer, host_pushes?: true)

      assert {:ok, %GitCredential{mode: :scoped}} =
               GitCredential.plan(ws, "tonic",
                 role: :implementer,
                 host_pushes?: true,
                 remote_node?: true
               )

      assert {:ok, %GitCredential{mode: :not_needed}} =
               GitCredential.plan(ws, "tonic", role: :reviewer, host_pushes?: true)
    end

    test "kind/2 names it" do
      assert GitCredential.kind(workspace(), "tonic") == :gitlab_bot_token
    end
  end

  describe "the dispatch guard" do
    test "a clean token and exact membership materialize, after both API calls" do
      stub_gitlab()

      assert {:ok,
              %Material{
                kind: :gitlab_bot_token,
                token: @bot,
                host: "gitlab.com",
                username: "oauth2",
                remote: "acme/tonic"
              }} = materialize(workspace())

      assert_receive {:gitlab, "GET", "/api/v4/personal_access_tokens/self", _, [@bot]}
      assert_receive {:gitlab, "GET", "/api/v4/projects", query, [@bot]}
      assert query =~ "membership=true"
    end

    test "a self-managed api_url is used for the checks" do
      stub_gitlab()

      ws =
        workspace(%{"host" => "git.example.com", "api_url" => "https://git.example.com/api/v4"})

      assert {:ok, %Material{host: "git.example.com"}} = materialize(ws)
      assert_receive {:gitlab, "GET", "/api/v4/personal_access_tokens/self", _, _}
    end

    test "the api scope is refused" do
      stub_gitlab(pat: %{"scopes" => ["api", "read_repository", "write_repository"]})

      assert {:error, {:git_credential_bot_token_refused, {:scopes, ["api"]}} = error} =
               materialize(workspace())

      message = GitCredential.format_error(error)
      assert message =~ "api"
      assert message =~ "scope"
      refute message =~ @bot
    end

    test "sudo and any other scope beyond the allowed three is refused" do
      stub_gitlab(pat: %{"scopes" => ["read_api", "write_repository", "sudo", "read_user"]})

      assert {:error, {:git_credential_bot_token_refused, {:scopes, extra}}} =
               materialize(workspace())

      assert Enum.sort(extra) == ["read_user", "sudo"]
    end

    test "read_api, read_repository and write_repository alone are allowed" do
      stub_gitlab(pat: %{"scopes" => ["read_api", "read_repository", "write_repository"]})
      assert {:ok, _} = materialize(workspace())
    end

    test "a token with no expiry is refused" do
      stub_gitlab(pat: %{"expires_at" => nil})

      assert {:error, {:git_credential_bot_token_refused, :no_expiry} = error} =
               materialize(workspace())

      assert GitCredential.format_error(error) =~ "expir"
    end

    test "an expired, revoked or inactive token is refused" do
      stub_gitlab(pat: %{"expires_at" => in_days(-1)})
      assert {:error, {:git_credential_bot_token_refused, :expired}} = materialize(workspace())

      stub_gitlab(pat: %{"revoked" => true})
      assert {:error, {:git_credential_bot_token_refused, :inactive}} = materialize(workspace())

      stub_gitlab(pat: %{"active" => false})
      assert {:error, {:git_credential_bot_token_refused, :inactive}} = materialize(workspace())
    end

    test "membership beyond the configured projects is refused, naming the extras" do
      stub_gitlab(projects: ["acme/tonic", "acme/secret-infra", "acme/other"])

      assert {:error, {:git_credential_bot_token_refused, {:membership, extra}} = error} =
               materialize(workspace())

      assert Enum.sort(extra) == ["acme/other", "acme/secret-infra"]
      message = GitCredential.format_error(error)
      assert message =~ "acme/secret-infra"
      assert message =~ "membership"
    end

    test "projects listed on the entry, or on sibling entries sharing the secret, are allowed" do
      stub_gitlab(projects: ["acme/tonic", "acme/tonic_device", "acme/vstim"])

      ws =
        workspace(
          %{"projects" => ["acme/tonic_device"]},
          %{"GL_BOT" => @bot},
          %{
            "vstim" => %{
              "kind" => "gitlab_bot_token",
              "secret" => "GL_BOT",
              "remote" => "acme/vstim"
            }
          }
        )

      assert {:ok, _} = materialize(ws)
    end

    test "a sibling entry with a different secret does not widen the allowed set" do
      stub_gitlab(projects: ["acme/tonic", "acme/vstim"])

      ws =
        workspace(%{}, %{"GL_BOT" => @bot, "OTHER" => "x"}, %{
          "vstim" => %{
            "kind" => "gitlab_bot_token",
            "secret" => "OTHER",
            "remote" => "acme/vstim"
          }
        })

      assert {:error, {:git_credential_bot_token_refused, {:membership, ["acme/vstim"]}}} =
               materialize(ws)
    end

    test "project paths compare case-insensitively" do
      stub_gitlab(projects: ["Acme/Tonic"])
      assert {:ok, _} = materialize(workspace())
    end

    test "a bot that is not a member of the spawn's project is refused" do
      stub_gitlab(projects: ["acme/other"], pat: %{})

      ws = workspace(%{"projects" => ["acme/other"]})

      assert {:error, {:git_credential_bot_token_refused, :not_a_member}} = materialize(ws)
    end

    test "membership is read across pages" do
      stub_gitlab(projects: ["acme/a", "acme/b", "acme/tonic"], per_page: 1)

      ws = workspace(%{"projects" => ["acme/a", "acme/b"]})
      assert {:ok, _} = materialize(ws)

      assert_receive {:gitlab, "GET", "/api/v4/projects", q1, _}
      assert_receive {:gitlab, "GET", "/api/v4/projects", q2, _}
      assert_receive {:gitlab, "GET", "/api/v4/projects", q3, _}
      assert q1 =~ "page=1"
      assert q2 =~ "page=2"
      assert q3 =~ "page=3"
    end

    test "a hidden extra project on a later page is still refused" do
      stub_gitlab(projects: ["acme/tonic", "acme/b", "acme/leak"], per_page: 1)

      assert {:error, {:git_credential_bot_token_refused, {:membership, extra}}} =
               materialize(workspace(%{"projects" => ["acme/b"]}))

      assert extra == ["acme/leak"]
    end

    test "a configured expires_at in the past refuses without asking GitLab" do
      stub_gitlab()

      assert {:error, {:git_credential_bot_token_refused, :expired}} =
               materialize(workspace(%{"expires_at" => in_days(-3)}))

      refute_received {:gitlab, _, _, _, _}
    end

    test "an API failure fails closed: the token is unverifiable, never delivered" do
      stub_gitlab(pat_status: 401)

      assert {:error, {:git_credential_bot_token_unverifiable, _} = error} =
               materialize(workspace())

      assert GitCredential.format_error(error) =~ "could not be verified"

      Req.Test.stub(@http, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:git_credential_bot_token_unverifiable, _} = error} =
               materialize(workspace())

      refute inspect(error) =~ @bot
    end

    test "a missing secret is a refusal, never a fallback" do
      assert {:error, {:git_credential_secret_missing, "GL_BOT"}} =
               materialize(workspace(%{}, %{}))
    end

    test "without a pinned project it refuses rather than deliver" do
      ws = workspace()

      assert {:error, :git_credential_remote_unknown} =
               GitCredential.materialize(plan(ws), ws, req_options())
    end
  end

  describe "delivery" do
    test "env: the helper (ARB_GIT_TOKEN) plus GITLAB_TOKEN and GITLAB_HOST, no config write" do
      env = Material.env(bot_material(), nil)

      assert {"ARB_GIT_TOKEN", @bot} in env
      assert {"GITLAB_TOKEN", @bot} in env
      assert {"GITLAB_HOST", "gitlab.com"} in env
      assert {"GIT_TERMINAL_PROMPT", "0"} in env
      assert {"GIT_CONFIG_PARAMETERS", config} = List.keyfind(env, "GIT_CONFIG_PARAMETERS", 0)
      assert config =~ ~s([ "$p" = "acme/tonic" ])
      assert config =~ "username=oauth2"
      # SSH remotes of the host go over https so the helper applies.
      assert config =~ "insteadOf"
      # The token is read from the env by the helper; it is never in the git config.
      refute config =~ @bot
    end

    test "podman gets the token as two env secrets; neither value is in the container env" do
      secrets = GitCredential.podman_secrets(bot_material(), "arb-run")

      assert Enum.sort(Enum.map(secrets, & &1.target)) == ["ARB_GIT_TOKEN", "GITLAB_TOKEN"]
      assert Enum.all?(secrets, &(&1.type == :env and &1.value == @bot))
      assert length(Enum.uniq(Enum.map(secrets, & &1.name))) == 2

      env = GitCredential.container_env(bot_material())
      refute inspect(env) =~ @bot
      assert {"GITLAB_HOST", "gitlab.com"} in env
    end

    test "a node gets the token only as secrets" do
      assert {:ok, %{env: env, secrets: secrets}} = GitCredential.remote_delivery(bot_material())

      assert secrets == %{"ARB_GIT_TOKEN" => @bot, "GITLAB_TOKEN" => @bot}
      refute inspect(env) =~ @bot
      refute List.keymember?(env, "GITLAB_TOKEN", 0)
      assert {"GITLAB_HOST", "gitlab.com"} in env
    end

    test "the output scrubber masks the token; inspect never prints it" do
      assert @bot in GitCredential.redact_values(bot_material())
      refute inspect(bot_material()) =~ "glpat"
    end

    test "there is nothing to revoke: revoke/2 sends nothing" do
      stub_gitlab()
      assert :ok = GitCredential.revoke(bot_material(), req_options())
      refute_received {:gitlab, _, _, _, _}
    end

    test "withheld_values/1 does not list the bot token (it is meant for the node)" do
      refute @bot in GitCredential.withheld_values(workspace())
    end

    test "plan -> prepare -> spawn_env hands a local worker its push and API env" do
      stub_gitlab()
      ws = workspace()
      {:ok, plan} = GitCredential.plan(ws, "tonic", role: :implementer, host_pushes?: false)

      assert {:ok, git} =
               GitCredential.prepare(plan, ws, self(), [remote: "acme/tonic"] ++ req_options())

      assert {:ok, env} = GitCredential.spawn_env(git, %{}, [{"PATH", "/usr/bin"}], [])
      assert {"GITLAB_TOKEN", @bot} in env
      assert {"ARB_GIT_TOKEN", @bot} in env
      assert {"GITLAB_HOST", "gitlab.com"} in env
      refute List.keymember?(env, "SSH_AUTH_SOCK", 0)
      assert @bot in git.redact
    end

    test "prepare/4 refuses a too-broad token before anything is delivered" do
      stub_gitlab(pat: %{"scopes" => ["api"]})
      ws = workspace()

      assert {:error, {:git_credential_bot_token_refused, {:scopes, ["api"]}}} =
               GitCredential.prepare(
                 plan(ws),
                 ws,
                 self(),
                 [remote: "acme/tonic", container?: true] ++ req_options()
               )
    end
  end

  describe "expiry (doctor)" do
    alias Arbiter.Worker.GitCredential.GitlabBot

    test "reports the live expiry, with days left" do
      stub_gitlab(pat: %{"expires_at" => in_days(40)})

      assert [%{repo: "tonic", secret: "GL_BOT", source: :live, days_left: 40} = row] =
               GitlabBot.expiries(workspace(), req_options: [plug: {Req.Test, @http}])

      assert row.expires_at == Date.add(Date.utc_today(), 40)
    end

    test "falls back to the configured expires_at when GitLab cannot be asked" do
      stub_gitlab(pat_status: 500)

      assert [%{source: :config, days_left: 20}] =
               GitlabBot.expiries(workspace(%{"expires_at" => in_days(20)}),
                 req_options: [plug: {Req.Test, @http}]
               )
    end

    test "without a probe it reports the configured expiry and asks nobody" do
      stub_gitlab()

      assert [%{source: :config, days_left: 90}] =
               GitlabBot.expiries(workspace(%{"expires_at" => in_days(90)}), probe: false)

      refute_received {:gitlab, _, _, _, _}
    end

    test "a repo with another kind reports nothing" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "glb-x-#{System.unique_integer([:positive])}",
          prefix: "gx",
          config: %{
            "git_credentials" => %{
              "repos" => %{"a" => %{"kind" => "token", "token_secret" => "T"}}
            }
          }
        })

      assert GitlabBot.expiries(ws, probe: false) == []
    end
  end
end
