defmodule Arbiter.Worker.GitCredentialTest do
  @moduledoc """
  G16 (bd-9cygoo): materializing, staging and delivering a repo-scoped credential,
  and the guarantee that it does not work for a different repo.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.GitCredential.Material

  @moduletag :tmp_dir

  @http Arbiter.Worker.GitCredential.HTTP

  defp workspace(git_credentials, secrets) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gc-#{System.unique_integer([:positive])}",
        prefix: "gc",
        config: %{"git_credentials" => git_credentials},
        secrets: secrets
      })

    ws
  end

  defp plan(ws, repo) do
    {:ok, %GitCredential{mode: :scoped} = plan} =
      GitCredential.plan(ws, repo, role: :implementer, guarded?: true)

    plan
  end

  defp rsa_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    {key, pem}
  end

  defp req_options, do: [req_options: [plug: {Req.Test, @http}]]

  describe "materialize/3 for a deploy key" do
    test "reads the key from the workspace secret" do
      ws = workspace(%{"repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "K"}}}, %{"K" => "PEMDATA"})

      assert {:ok, %Material{kind: :deploy_key, key: "PEMDATA\n"}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, [])
    end

    test "a missing secret is a refusal naming the secret, never a fallback" do
      ws = workspace(%{"repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "K"}}}, %{})

      assert {:error, {:git_credential_secret_missing, "K"}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, [])
    end

    test "non-scoped plans materialize nothing" do
      assert {:ok, nil} = GitCredential.materialize(%GitCredential{mode: :legacy}, nil, [])
      assert {:ok, nil} = GitCredential.materialize(%GitCredential{mode: :unenforced}, nil, [])
      assert {:ok, nil} = GitCredential.materialize(%GitCredential{mode: :not_needed}, nil, [])
    end
  end

  describe "stage/3 and delivery of a deploy key" do
    test "writes a 0600 key file and points ssh at it alone, never at an agent", %{tmp_dir: tmp} do
      material = %Material{kind: :deploy_key, key: "PRIVATE\n"}
      assert {:ok, staged} = GitCredential.stage(material, self(), root: tmp)

      assert File.read!(staged.key_path) == "PRIVATE\n"
      assert File.stat!(staged.key_path).mode |> Bitwise.band(0o777) == 0o600
      assert Path.dirname(staged.key_path) |> File.stat!() |> Map.fetch!(:mode) |> Bitwise.band(0o777) == 0o700

      env = Map.new(staged.env)
      assert env["GIT_SSH_COMMAND"] =~ "-i #{staged.key_path}"
      assert env["GIT_SSH_COMMAND"] =~ "IdentitiesOnly=yes"
      assert env["GIT_SSH_COMMAND"] =~ "IdentityAgent=none"
      refute Map.has_key?(env, "SSH_AUTH_SOCK")
    end

    test "staging is idempotent per owner", %{tmp_dir: tmp} do
      material = %Material{kind: :deploy_key, key: "PRIVATE\n"}
      {:ok, a} = GitCredential.stage(material, self(), root: tmp)
      {:ok, b} = GitCredential.stage(material, self(), root: tmp)
      assert a.key_path == b.key_path
    end

    test "podman gets the key as a --secret mount, the token as a --secret env" do
      key = %Material{kind: :deploy_key, key: "PRIVATE\n"}
      tok = %Material{kind: :token, token: "tok", remote: "acme/tonic", host: "github.com"}

      assert [%{name: "arb-x-git-key", type: :mount, target: "arb_git_key", value: "PRIVATE\n"}] =
               GitCredential.podman_secrets(key, "arb-x")

      assert [%{name: "arb-x-git-token", type: :env, target: "ARB_GIT_TOKEN", value: "tok"}] =
               GitCredential.podman_secrets(tok, "arb-x")

      assert GitCredential.podman_key_path() == "/run/secrets/arb_git_key"
    end
  end

  describe "token delivery is pinned to the repo" do
    setup do
      %{
        material: %Material{
          kind: :token,
          token: "s3cr3t-token",
          host: "github.com",
          username: "x-access-token",
          remote: "acme/tonic"
        }
      }
    end

    defp credential_fill(env, path, global \\ "/dev/null") do
      input = "protocol=https\nhost=github.com\npath=#{path}\n\n"
      script = Path.join(System.tmp_dir!(), "gcf-#{System.unique_integer([:positive])}.sh")
      File.write!(script, "printf '%s' \"$1\" | git credential fill\n")
      on_exit(fn -> File.rm(script) end)

      System.cmd("sh", [script, input],
        env: env ++ [{"HOME", System.tmp_dir!()}, {"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", global}],
        stderr_to_stdout: true
      )
    end

    test "the helper returns the token for the repo it was minted for", %{material: m} do
      {out, 0} = credential_fill(Material.env(m, nil), "acme/tonic.git")
      assert out =~ "username=x-access-token"
      assert out =~ "password=s3cr3t-token"
    end

    test "a different repo gets no credential, so a push to it fails", %{material: m} do
      {out, status} = credential_fill(Material.env(m, nil), "acme/other.git")
      refute out =~ "s3cr3t-token"
      refute status == 0

      {out, status} = credential_fill(Material.env(m, nil), "other-org/tonic.git")
      refute out =~ "s3cr3t-token"
      refute status == 0
    end

    test "a real push to another repo's url is refused before any network use", %{material: m, tmp_dir: tmp} do
      repo = Path.join(tmp, "r")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "--allow-empty", "-m", "x"], env: [{"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@t"}, {"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@t"}])

      # The remote does not resolve: git has to ask for a credential first and,
      # finding none for this path, must fail on authentication, not hand the token over.
      env = Material.env(m, nil) ++ [{"HOME", tmp}, {"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_TRACE_CURL", "0"}]
      {out, status} = System.cmd("git", ["-C", repo, "ls-remote", "https://127.0.0.1:1/acme/other.git"], env: env, stderr_to_stdout: true)
      refute status == 0
      refute out =~ "s3cr3t-token"
    end

    test "the operator's own credential helper is reset, so it never answers", %{material: m, tmp_dir: tmp} do
      global = Path.join(tmp, "gitconfig")

      File.write!(
        global,
        "[credential]\n\thelper = \"!f() { echo username=op; echo password=OPERATOR; }; f\"\n"
      )

      {out, 0} = credential_fill(Material.env(m, nil), "acme/tonic.git", global)
      assert out =~ "password=s3cr3t-token"
      refute out =~ "OPERATOR"

      {out, status} = credential_fill(Material.env(m, nil), "acme/other.git", global)
      refute out =~ "OPERATOR"
      refute status == 0
    end

    test "ssh remotes are rewritten to https so the helper applies", %{material: m} do
      env = Map.new(Material.env(m, nil))
      {out, 0} =
        System.cmd("git", ["ls-remote", "--get-url", "git@github.com:acme/tonic.git"],
          env: Map.to_list(env) ++ [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
        )

      assert String.trim(out) == "https://github.com/acme/tonic.git"
    end

    test "the token is in env, the operator's helpers are reset, prompts are off", %{material: m} do
      env = Map.new(Material.env(m, nil))
      assert env["ARB_GIT_TOKEN"] == "s3cr3t-token"
      assert env["GIT_TERMINAL_PROMPT"] == "0"
      assert env["GIT_CONFIG_PARAMETERS"] =~ "'credential.helper='"
      refute Map.has_key?(env, "SSH_AUTH_SOCK")
    end

    test "a hostile remote cannot inject shell into the helper" do
      m = %Material{kind: :token, token: "t", host: "github.com", remote: "a/b';touch x;'"}
      assert_raise ArgumentError, fn -> Material.env(m, nil) end
    end
  end

  describe "github_app minting" do
    setup do
      {key, pem} = rsa_pem()

      ws =
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
          %{"APP_KEY" => pem}
        )

      %{ws: ws, key: key}
    end

    test "mints an installation token restricted to the one repo, with no gist or delete rights", %{ws: ws, key: key} do
      test_pid = self()

      Req.Test.stub(@http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:mint, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)})
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "ghs_scoped", "expires_at" => "2099-01-01T00:00:00Z"})
      end)

      assert {:ok, %Material{kind: :github_app, token: "ghs_scoped", remote: "acme/tonic"}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, [remote: "acme/tonic"] ++ req_options())

      assert_receive {:mint, "/app/installations/7/access_tokens", ["Bearer " <> jwt], body}

      assert body["repositories"] == ["tonic"]
      assert body["permissions"] == %{"contents" => "write", "metadata" => "read", "pull_requests" => "read"}
      refute Map.has_key?(body["permissions"], "administration")

      # the JWT is an RS256 assertion by the App, verifiable with the App's public key
      [h, p, s] = String.split(jwt, ".")
      assert %{"alg" => "RS256"} = h |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert %{"iss" => "42", "exp" => exp, "iat" => iat} = p |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert exp - iat <= 600 + 60
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key
      pub = {:RSAPublicKey, n, e}
      assert :public_key.verify(h <> "." <> p, :sha256, Base.url_decode64!(s, padding: false), pub)
    end

    test "a tracker token is a second, narrower mint for the same repo", %{ws: ws} do
      test_pid = self()

      Req.Test.stub(@http, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(body)
        send(test_pid, {:mint, body})
        token = if body["permissions"]["issues"], do: "ghs_tracker", else: "ghs_push"
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => token, "expires_at" => "2099-01-01T00:00:00Z"})
      end)

      assert {:ok, %Material{token: "ghs_push", tracker_token: "ghs_tracker"}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, [remote: "acme/tonic", tracker?: true] ++ req_options())

      assert_receive {:mint, %{"repositories" => ["tonic"], "permissions" => %{"issues" => "write"} = perms}}
      assert perms["pull_requests"] == "write"
      refute Map.has_key?(perms, "administration")
    end

    test "a mint failure refuses the spawn", %{ws: ws} do
      Req.Test.stub(@http, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, {:git_credential_mint_failed, 404, _}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, [remote: "acme/tonic"] ++ req_options())
    end

    test "without a pinned remote it refuses rather than mint an unscoped token", %{ws: ws} do
      assert {:error, :git_credential_remote_unknown} =
               GitCredential.materialize(plan(ws, "tonic"), ws, req_options())
    end
  end

  describe "static token kind" do
    setup do
      ws =
        workspace(
          %{"repos" => %{"tonic" => %{"kind" => "token", "token_secret" => "T"}}},
          %{"T" => "fine-grained"}
        )

      %{ws: ws}
    end

    test "a classic PAT (one that reports OAuth scopes) is refused: it cannot be limited to a repo", %{ws: ws} do
      Req.Test.stub(@http, fn conn ->
        conn |> Plug.Conn.put_resp_header("x-oauth-scopes", "repo, gist") |> Req.Test.json(%{"login" => "x"})
      end)

      assert {:error, {:git_credential_token_too_broad, scopes}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, [remote: "acme/tonic"] ++ req_options())

      assert "gist" in scopes
    end

    test "a fine-grained token (no OAuth scope header) is accepted", %{ws: ws} do
      Req.Test.stub(@http, fn conn -> Req.Test.json(conn, %{"login" => "x"}) end)

      assert {:ok, %Material{kind: :token, token: "fine-grained", remote: "acme/tonic", tracker_token: "fine-grained"}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, [remote: "acme/tonic", tracker?: true] ++ req_options())
    end

    test "a host other than github.com is not probed (GitLab project tokens are repo-bound)" do
      ws =
        workspace(
          %{"repos" => %{"tonic" => %{"kind" => "token", "token_secret" => "T", "host" => "gitlab.com", "username" => "oauth2"}}},
          %{"T" => "glpat"}
        )

      assert {:ok, %Material{host: "gitlab.com", username: "oauth2"}} =
               GitCredential.materialize(plan(ws, "tonic"), ws, remote: "acme/tonic")
    end
  end

  describe "tracker env" do
    test "the tracker var gets the repo-scoped token, not a binding's broader one" do
      m = %Material{kind: :github_app, token: "push", tracker_token: "ghs_tracker", remote: "a/b", host: "github.com"}
      assert GitCredential.tracker_token(m) == "ghs_tracker"
      assert GitCredential.tracker_token(%Material{kind: :deploy_key, key: "k"}) == nil
      assert GitCredential.tracker_token(nil) == nil
    end

    test "redaction values cover every secret the material carries" do
      m = %Material{kind: :github_app, token: "push", tracker_token: "trk", key: nil}
      assert Enum.sort(GitCredential.redact_values(m)) == ["push", "trk"]
      assert GitCredential.redact_values(%Material{kind: :deploy_key, key: "PEM\n"}) == ["PEM"]
    end
  end
end

defmodule Arbiter.Worker.GitCredentialSpawnTest do
  @moduledoc "G16: `prepare/4` and `spawn_env/4`, the seam the session start uses."
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Projection
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential

  @moduletag :tmp_dir
  @http Arbiter.Worker.GitCredential.HTTP

  defp workspace(git_credentials, secrets) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gs-#{System.unique_integer([:positive])}",
        prefix: "gs",
        config: %{"git_credentials" => git_credentials},
        secrets: secrets
      })

    ws
  end

  defp token_ws,
    do: workspace(%{"repos" => %{"tonic" => %{"kind" => "token", "token_secret" => "T", "host" => "gitlab.com"}}}, %{"T" => "scoped-tok"})

  defp plan(ws, repo \\ "tonic") do
    {:ok, plan} = GitCredential.plan(ws, repo, role: :implementer, guarded?: true)
    plan
  end

  defp projection(env_var \\ "GH_TOKEN"),
    do: %Projection{guarded?: true, claims: ["tracker_write"], tracker_env: env_var}

  test "a legacy or unenforced plan delivers nothing and changes nothing" do
    for mode <- [:legacy, :unenforced, :not_needed] do
      assert {:ok, git} = GitCredential.prepare(%GitCredential{mode: mode}, nil, self(), [])
      assert git.material == nil and git.env == [] and git.redact == []
      assert {:ok, [{"A", "b"}]} = GitCredential.spawn_env(git, Projection.unguarded(), [{"A", "b"}], [])
    end
  end

  test "a deploy key is staged on the host and named by GIT_SSH_COMMAND", %{tmp_dir: tmp} do
    ws = workspace(%{"repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "K"}}}, %{"K" => "KEYDATA"})
    assert {:ok, git} = GitCredential.prepare(plan(ws), ws, self(), root: tmp)
    assert File.read!(git.key_path) == "KEYDATA\n"
    assert {"GIT_SSH_COMMAND", cmd} = List.keyfind(git.env, "GIT_SSH_COMMAND", 0)
    assert cmd =~ git.key_path
    assert git.redact == ["KEYDATA"]
  end

  test "a container spawn is not staged on the host: its key travels as a podman secret", %{tmp_dir: tmp} do
    ws = workspace(%{"repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "K"}}}, %{"K" => "KEYDATA"})
    assert {:ok, git} = GitCredential.prepare(plan(ws), ws, self(), root: tmp, container?: true)
    assert git.material.key == "KEYDATA\n"
    assert git.key_path == nil and git.env == []
    assert File.ls!(tmp) == []
  end

  test "the origin remote of the worktree pins a token", %{tmp_dir: tmp} do
    {_, 0} = System.cmd("git", ["init", "-q", tmp])
    {_, 0} = System.cmd("git", ["-C", tmp, "remote", "add", "origin", "git@gitlab.com:acme/tonic.git"])

    ws = token_ws()
    assert {:ok, git} = GitCredential.prepare(plan(ws), ws, self(), worktree_path: tmp)
    assert git.material.remote == "acme/tonic"
    assert Map.new(git.env)["ARB_GIT_TOKEN"] == "scoped-tok"
  end

  test "a token with no derivable remote is refused" do
    ws = token_ws()
    assert {:error, :git_credential_remote_unknown} = GitCredential.prepare(plan(ws), ws, self(), worktree_path: "/nonexistent")
  end

  test "the tracker var gets the repo-scoped token, replacing the binding's broader one", %{tmp_dir: tmp} do
    {_, 0} = System.cmd("git", ["init", "-q", tmp])
    {_, 0} = System.cmd("git", ["-C", tmp, "remote", "add", "origin", "git@gitlab.com:acme/tonic.git"])
    ws = token_ws()

    {:ok, git} = GitCredential.prepare(plan(ws), ws, self(), worktree_path: tmp, projection: projection("GITLAB_TOKEN"))
    {:ok, env} = GitCredential.spawn_env(git, projection("GITLAB_TOKEN"), [{"GITLAB_TOKEN", "broad-binding-token"}, {"X", "1"}], [])

    assert {"GITLAB_TOKEN", "scoped-tok"} in env
    refute {"GITLAB_TOKEN", "broad-binding-token"} in env
    assert {"X", "1"} in env
  end

  test "with a deploy key the binding's own tracker token is kept, but a classic PAT is refused", %{tmp_dir: tmp} do
    ws = workspace(%{"repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "K"}}}, %{"K" => "KEYDATA"})
    {:ok, git} = GitCredential.prepare(plan(ws), ws, self(), root: tmp)

    Req.Test.stub(@http, fn conn -> Req.Test.json(conn, %{"login" => "x"}) end)
    opts = [req_options: [plug: {Req.Test, @http}]]
    assert {:ok, env} = GitCredential.spawn_env(git, projection(), [{"GH_TOKEN", "fine-grained"}], opts)
    assert {"GH_TOKEN", "fine-grained"} in env

    Req.Test.stub(@http, fn conn ->
      conn |> Plug.Conn.put_resp_header("x-oauth-scopes", "repo, delete_repo") |> Req.Test.json(%{})
    end)

    assert {:error, {:git_credential_token_too_broad, scopes}} =
             GitCredential.spawn_env(git, projection(), [{"GH_TOKEN", "classic"}], opts)

    assert "delete_repo" in scopes
  end

  test "a legacy spawn's tracker token is left alone (no scope check, as before)" do
    {:ok, git} = GitCredential.prepare(%GitCredential{mode: :legacy}, nil, self(), [])
    assert {:ok, [{"GH_TOKEN", "x"}]} = GitCredential.spawn_env(git, projection(), [{"GH_TOKEN", "x"}], [])
  end
end
