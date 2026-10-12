defmodule Arbiter.Mergers.Github.HostCredentialTest do
  @moduledoc """
  bd-bsmkfu: the GitHub merger opens, comments on and merges a PR with the repo's
  scoped GitHub App token when `git_credentials.repos.<repo>` is a github_app;
  a repo without one keeps the merger config's `credentials_ref`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Mergers
  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.Github.Config
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.HostCredential

  @mint Arbiter.Worker.GitCredential.HTTP
  @env_var "BSMKFU_OPERATOR_TOKEN"

  setup do
    System.put_env(@env_var, "operator-classic-token")
    HostCredential.Cache.clear()

    Application.put_env(:arbiter, :host_credential_req_options, plug: {Req.Test, @mint})

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
      Application.delete_env(:arbiter, :host_credential_req_options)
    end)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ghhc-#{System.unique_integer([:positive])}",
        prefix: "ghhc",
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{"credentials_ref" => "env:#{@env_var}"}
          },
          "git_credentials" => %{
            "repos" => %{
              "tonic" => %{
                "kind" => "github_app",
                "app_id" => "42",
                "installation_id" => "7",
                "private_key_secret" => "APP_KEY",
                "remote" => "acme/tonic"
              },
              "legacy" => %{"legacy_operator" => true}
            }
          }
        },
        secrets: %{"APP_KEY" => pem}
      })

    %{ws: ws}
  end

  defp stub_mint(status \\ 201) do
    test_pid = self()

    Req.Test.stub(@mint, fn conn ->
      send(test_pid, :minted)

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(
        if status == 201,
          do: %{"token" => "ghs_app_bot", "expires_at" => "2099-01-01T00:00:00Z"},
          else: %{"message" => "Bad credentials"}
      )
    end)
  end

  test "a github_app repo resolves the App's installation token, not credentials_ref", %{ws: ws} do
    stub_mint()
    Mergers.prepare_with_repo(ws, "tonic")

    assert {:ok, %{token: "ghs_app_bot"}} = Config.resolve()
  end

  test "the PR is opened with the App's token (so the App bot is the author)", %{ws: ws} do
    stub_mint()
    Mergers.prepare_with_repo(ws, "tonic")
    Config.override_repo("acme/tonic")

    Req.Test.stub(Github.HTTP, fn conn ->
      assert ["Bearer ghs_app_bot"] = Plug.Conn.get_req_header(conn, "authorization")

      case {conn.method, conn.request_path} do
        {"GET", "/repos/acme/tonic/pulls"} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/acme/tonic/pulls"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 9})
      end
    end)

    assert {:ok, _ref} = Github.open("feature/x", "t", "d", %{})
  end

  test "repeated polls mint once", %{ws: ws} do
    stub_mint()
    Mergers.prepare_with_repo(ws, "tonic")
    assert {:ok, _} = Config.resolve()
    Mergers.prepare_with_repo(ws, "tonic")
    assert {:ok, _} = Config.resolve()

    assert_received :minted
    refute_received :minted
  end

  test "a legacy_operator repo keeps today's token", %{ws: ws} do
    Mergers.prepare_with_repo(ws, "legacy")
    assert {:ok, %{token: "operator-classic-token"}} = Config.resolve()
  end

  test "a repo with no git_credentials entry keeps today's token", %{ws: ws} do
    Mergers.prepare_with_repo(ws, "other")
    assert {:ok, %{token: "operator-classic-token"}} = Config.resolve()
  end

  test "an unscoped workspace keeps today's token", %{ws: ws} do
    Mergers.prepare(ws)
    assert {:ok, %{token: "operator-classic-token"}} = Config.resolve()
  end

  test "a failed mint is an error, not the operator's token", %{ws: ws} do
    stub_mint(401)
    Mergers.prepare_with_repo(ws, "tonic")

    assert {:error, %Github.Error{kind: :config_missing, message: message}} = Config.resolve()
    assert message =~ "tonic"
    assert message =~ "refusing" or message =~ "minting"
  end
end
