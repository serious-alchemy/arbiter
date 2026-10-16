defmodule Arbiter.Worker.Image.RegistryResolveTest do
  @moduledoc """
  KH12 (bd-5evive, `docs/design/remote-workers.md` §20.10, OD3): which registry a
  repo's images go to (repo -> workspace -> `nodes.registry`), which credential
  pushes them (a workspace secret), the multi-host auth file and the
  anonymous-read probe.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Image.Registry

  @moduletag :tmp_dir

  @install %{registry: "install.example.com/arb", username: "inst", password: "inst-pw"}
  @gitlab_pw "gitlab-pw-NEVER-LOGGED"

  defp workspace(worker, secrets \\ %{}) do
    %Workspace{
      config: %{"worker" => worker},
      encrypted_secrets:
        secrets |> :erlang.term_to_binary() |> Arbiter.Vault.encrypt!() |> Base.encode64()
    }
  end

  defp image(block), do: %{"image" => block}

  describe "resolve/3: repo -> workspace -> nodes.registry" do
    test "nothing configured on the workspace is the install-wide registry, unchanged" do
      for ws <- [nil, workspace(%{})] do
        assert {:ok, cfg} = Registry.resolve(ws, "vstim", config: @install)
        assert cfg.registry == "install.example.com/arb"
        assert cfg.username == "inst"
        assert cfg.origin == :install
      end
    end

    test "no registry anywhere is :unset" do
      assert Registry.resolve(workspace(%{}), "vstim", config: %{}) == :unset
    end

    test "a workspace registry beats nodes.registry, with its own credential" do
      ws =
        workspace(
          image(%{
            "registry" => "registry.gitlab.com/vstim",
            "credentials_ref" => "secret:GITLAB"
          }),
          %{"GITLAB" => "deploy:" <> @gitlab_pw}
        )

      assert {:ok, cfg} = Registry.resolve(ws, "vstim", config: @install)
      assert cfg.registry == "registry.gitlab.com/vstim"
      assert cfg.host == "registry.gitlab.com"
      assert cfg.username == "deploy"
      assert cfg.password == @gitlab_pw
      assert cfg.origin == :config
      refute inspect(cfg) =~ @gitlab_pw
    end

    test "a repo registry beats the workspace's, and only that repo moves" do
      ws =
        workspace(%{
          "image" => %{"registry" => "ws.example.com/arb"},
          "repos" => %{"vstim" => image(%{"registry" => "ghcr.io/ryan"})}
        })

      assert {:ok, %{registry: "ghcr.io/ryan"}} = Registry.resolve(ws, "vstim", config: @install)

      assert {:ok, %{registry: "ws.example.com/arb"}} =
               Registry.resolve(ws, "other", config: @install)
    end

    test "a registry with no credentials_ref is an anonymous push" do
      ws = workspace(image(%{"registry" => "registry.local:5000"}))
      assert {:ok, cfg} = Registry.resolve(ws, "vstim", config: @install)
      assert {cfg.username, cfg.password} == {nil, nil}
    end

    test "a repo that changes the registry does not inherit the workspace's credential" do
      ws =
        workspace(
          %{
            "image" => %{"registry" => "ws.example.com/arb", "credentials_ref" => "secret:WS"},
            "repos" => %{"vstim" => image(%{"registry" => "ghcr.io/ryan"})}
          },
          %{"WS" => "u:ws-token"}
        )

      assert {:ok, repo_cfg} = Registry.resolve(ws, "vstim", config: @install)
      assert {repo_cfg.username, repo_cfg.password} == {nil, nil}

      assert {:ok, ws_cfg} = Registry.resolve(ws, "other", config: @install)
      assert {ws_cfg.username, ws_cfg.password} == {"u", "ws-token"}
    end

    test "a credential whose secret is missing or malformed is an error, never an anonymous push" do
      missing =
        workspace(image(%{"registry" => "r.example.com", "credentials_ref" => "secret:NOPE"}))

      assert {:error, {:registry_credentials, "secret:NOPE", :secret_not_found}} =
               Registry.resolve(missing, "vstim", config: @install)

      malformed =
        workspace(
          image(%{"registry" => "r.example.com", "credentials_ref" => "secret:BAD"}),
          %{"BAD" => "no-colon-here"}
        )

      assert {:error, {:registry_credentials, "secret:BAD", :malformed}} =
               Registry.resolve(malformed, "vstim", config: @install)
    end

    test "public_ok rides with the registry that sets it" do
      ws =
        workspace(%{
          "image" => %{"registry" => "pub.example.com/arb", "public_ok" => true},
          "repos" => %{"vstim" => image(%{"registry" => "priv.example.com/arb"})}
        })

      assert {:ok, %{public_ok: false}} = Registry.resolve(ws, "vstim", config: @install)
      assert {:ok, %{public_ok: true}} = Registry.resolve(ws, "other", config: @install)
    end
  end

  describe "with_authfile/3 across hosts" do
    defp cfg!(registry, user, pw) do
      {:ok, cfg} = Registry.fetch(config: %{registry: registry, username: user, password: pw})
      cfg
    end

    test "one 0600 file with an auths entry per host, gone afterwards", %{tmp_dir: tmp} do
      a = cfg!("registry.gitlab.com/vstim", "ci", "ci-pw")
      b = cfg!("ghcr.io/ryan", "ryan", "gh-pw")

      Registry.with_authfile([a, b], tmp, fn path ->
        send(self(), {:path, path})
        assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
        assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700

        auths = path |> File.read!() |> Jason.decode!() |> Map.fetch!("auths")
        assert Map.keys(auths) |> Enum.sort() == ["ghcr.io", "registry.gitlab.com"]
        assert auths["ghcr.io"]["auth"] == Base.encode64("ryan:gh-pw")
        assert auths["registry.gitlab.com"]["auth"] == Base.encode64("ci:ci-pw")
      end)

      assert_received {:path, path}
      refute File.exists?(path)
    end

    test "anonymous entries are left out; no login at all is nil", %{tmp_dir: tmp} do
      anon = cfg!("anon.example.com", nil, nil)
      b = cfg!("ghcr.io/ryan", "ryan", "gh-pw")

      Registry.with_authfile([anon, b], tmp, fn path ->
        auths = path |> File.read!() |> Jason.decode!() |> Map.fetch!("auths")
        assert Map.keys(auths) == ["ghcr.io"]
      end)

      assert Registry.with_authfile([anon], tmp, & &1) == nil
    end

    test "two registries on one host share a single entry", %{tmp_dir: tmp} do
      a = cfg!("ghcr.io/ryan", "ryan", "gh-pw")
      b = cfg!("ghcr.io/other", "ryan", "gh-pw")

      Registry.with_authfile([a, b], tmp, fn path ->
        assert path |> File.read!() |> Jason.decode!() |> Map.fetch!("auths") |> map_size() == 1
      end)
    end

    test "redact/2 scrubs every registry's secret" do
      a = cfg!("registry.gitlab.com/vstim", "ci", "ci-pw-SECRET")
      b = cfg!("ghcr.io/ryan", "ryan", "gh-pw-SECRET")
      out = Registry.redact("a ci-pw-SECRET b gh-pw-SECRET", [a, b])
      refute out =~ "SECRET"
    end
  end

  describe "anonymous_read/3" do
    defp probe(name, repository, cfg_opts \\ []) do
      {:ok, cfg} =
        Registry.fetch(
          config: %{registry: "reg.example.com/arb", insecure?: cfg_opts[:insecure?]}
        )

      Registry.anonymous_read(cfg, repository, req_options: [plug: {Req.Test, name}])
    end

    test "an open registry that lists tags to anyone is public" do
      Req.Test.stub(:open, fn conn ->
        assert conn.request_path == "/v2/arb/vstim/worker/tags/list"
        Req.Test.json(conn, %{"name" => "arb/vstim/worker", "tags" => ["a"]})
      end)

      assert probe(:open, "vstim/worker") == :public
    end

    test "a bearer registry that hands an anonymous token which can list is public" do
      Req.Test.stub(:bearer_public, fn conn ->
        case {conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
          {"/v2/arb/vstim/worker/tags/list", []} ->
            conn
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              ~s(Bearer realm="https://reg.example.com/token",service="registry")
            )
            |> Plug.Conn.send_resp(401, "")

          {"/token", []} ->
            assert conn.query_string =~ "scope=repository%3Aarb%2Fvstim%2Fworker%3Apull"
            assert conn.query_string =~ "service=registry"
            Req.Test.json(conn, %{"token" => "anon-token"})

          {"/v2/arb/vstim/worker/tags/list", ["Bearer anon-token"]} ->
            Req.Test.json(conn, %{"tags" => []})
        end
      end)

      assert probe(:bearer_public, "vstim/worker") == :public
    end

    test "a bearer registry whose anonymous token cannot list is private" do
      Req.Test.stub(:bearer_private, fn conn ->
        case {conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
          {"/v2/arb/vstim/worker/tags/list", []} ->
            conn
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              ~s(Bearer realm="https://reg.example.com/token",service="registry")
            )
            |> Plug.Conn.send_resp(401, "")

          {"/token", []} ->
            Req.Test.json(conn, %{"token" => "anon-token"})

          {"/v2/arb/vstim/worker/tags/list", ["Bearer anon-token"]} ->
            Plug.Conn.send_resp(conn, 401, "")
        end
      end)

      assert probe(:bearer_private, "vstim/worker") == :private
    end

    test "basic-auth, forbidden and absent repositories are private" do
      for {name, status} <- [basic: 401, forbidden: 403, absent: 404] do
        Req.Test.stub(name, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Basic realm="r"))
          |> Plug.Conn.send_resp(status, "")
        end)

        assert probe(name, "vstim/worker") == :private
      end
    end

    test "a server error or an unreachable registry is unknown, not public" do
      Req.Test.stub(:boom, &Plug.Conn.send_resp(&1, 500, ""))
      assert {:unknown, {:http_status, 500}} = probe(:boom, "vstim/worker")

      Req.Test.stub(:down, &Req.Test.transport_error(&1, :econnrefused))
      assert {:unknown, _} = probe(:down, "vstim/worker")
    end
  end
end
