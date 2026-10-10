defmodule Arbiter.NodeAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.Config

  @credential "arbn_node123." <> String.duplicate("A", 52)

  setup do
    home = Path.join(System.tmp_dir!(), "arb-nodeagent-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    cred = Path.join(home, "credential")
    File.write!(cred, @credential <> "\n")
    File.chmod!(cred, 0o600)

    %{home: home, cred: cred}
  end

  defp env(home, cred, extra \\ %{}) do
    Map.merge(
      %{
        "ARB_NODE_URL" => "https://primary.tail1234.ts.net",
        "ARB_NODE_HOME" => home,
        "ARB_NODE_CREDENTIAL_FILE" => cred
      },
      extra
    )
  end

  test "loads the primary URL, node home and credential from the environment", %{
    home: home,
    cred: cred
  } do
    assert {:ok, config} = Config.load(env: env(home, cred))
    assert config.primary_url == "https://primary.tail1234.ts.net"
    assert config.node_home == home
    assert config.credential == @credential
    assert config.node_id == "node123"
    assert config.status_path == Path.join(home, "status.json")
  end

  test "defaults the node home to ~/.arbiter-node and the credential to ~/.config/arbiter-node" do
    {:ok, config} =
      Config.load(
        env: %{"ARB_NODE_URL" => "https://p.example.ts.net", "HOME" => "/home/x"},
        app_config: [],
        read_credential: fn path ->
          send(self(), {:read, path})
          {:ok, @credential}
        end
      )

    assert config.node_home == "/home/x/.arbiter-node"
    assert_received {:read, "/home/x/.config/arbiter-node/credential"}
  end

  test "the environment wins over application config, keyword options win over both", %{
    home: home,
    cred: cred
  } do
    app = [node_home: "/from/app/config", primary_url: "https://app.example.ts.net"]

    assert {:ok, config} = Config.load(env: env(home, cred), app_config: app)
    assert config.node_home == home
    assert config.primary_url == "https://primary.tail1234.ts.net"

    assert {:ok, config} =
             Config.load(
               env: env(home, cred),
               app_config: app,
               primary_url: "https://kw.example.ts.net"
             )

    assert config.primary_url == "https://kw.example.ts.net"
  end

  test "keyword options win over the environment", %{home: home, cred: cred} do
    assert {:ok, config} =
             Config.load(
               env: env(home, cred),
               primary_url: "http://127.0.0.1:4848",
               hb_interval_ms: 25
             )

    assert config.primary_url == "http://127.0.0.1:4848"
    assert config.hb_interval_ms == 25
  end

  test "no URL is :unconfigured, named", %{home: home, cred: cred} do
    assert {:error, {:missing, "ARB_NODE_URL"}} =
             Config.load(env: env(home, cred) |> Map.delete("ARB_NODE_URL"))
  end

  test "a missing credential file is an error that names the path", %{home: home} do
    missing = Path.join(home, "nope")

    assert {:error, {:credential_unreadable, ^missing, :enoent}} =
             Config.load(env: env(home, missing))
  end

  test "a group/world-readable credential file is refused", %{home: home, cred: cred} do
    File.chmod!(cred, 0o644)
    assert {:error, {:credential_permissions, ^cred, 0o644}} = Config.load(env: env(home, cred))
  end

  test "a malformed credential is refused without echoing it", %{home: home, cred: cred} do
    File.write!(cred, "arbj_" <> String.duplicate("B", 52))
    File.chmod!(cred, 0o600)
    assert {:error, :credential_malformed} = Config.load(env: env(home, cred))
  end

  describe "proxy (§2.3)" do
    test "ARB_NODE_PROXY wins over HTTPS_PROXY / ALL_PROXY; none means nil", %{
      home: home,
      cred: cred
    } do
      assert {:ok, %{proxy: nil}} = Config.load(env: env(home, cred))

      assert {:ok, %{proxy: "http://127.0.0.1:1055"}} =
               Config.load(
                 env:
                   env(home, cred, %{
                     "ARB_NODE_PROXY" => "http://127.0.0.1:1055",
                     "HTTPS_PROXY" => "http://other:3128"
                   })
               )

      assert {:ok, %{proxy: "http://other:3128"}} =
               Config.load(env: env(home, cred, %{"ALL_PROXY" => "http://other:3128"}))
    end
  end

  describe "URL policy (§4.3)" do
    for url <- ["http://127.0.0.1:4848", "http://localhost:4848", "http://[::1]:4848"] do
      test "plain http is allowed for loopback: #{url}", %{home: home, cred: cred} do
        assert {:ok, _} = Config.load(env: env(home, cred, %{"ARB_NODE_URL" => unquote(url)}))
      end
    end

    for url <- ["http://primary.ts.net", "http://10.0.0.5:4848", "ftp://x", "primary.ts.net"] do
      test "refused: #{inspect(url)}", %{home: home, cred: cred} do
        assert {:error, {:insecure_url, _}} =
                 Config.load(env: env(home, cred, %{"ARB_NODE_URL" => unquote(url)}))
      end
    end
  end

  describe "socket_url/2" do
    test "https becomes wss with the V2 query, the proto and the agent version", %{
      home: home,
      cred: cred
    } do
      {:ok, config} = Config.load(env: env(home, cred), version: "1.2.3")
      uri = config |> Config.socket_url() |> URI.parse()

      assert uri.scheme == "wss"
      assert uri.host == "primary.tail1234.ts.net"
      assert uri.path == "/node/socket/websocket"

      assert URI.decode_query(uri.query) == %{
               "vsn" => "2.0.0",
               "token" => @credential,
               "proto" => "1",
               "agent_version" => "1.2.3"
             }
    end

    test "http loopback becomes ws and keeps the port and a base path", %{home: home, cred: cred} do
      {:ok, config} =
        Config.load(env: env(home, cred, %{"ARB_NODE_URL" => "http://127.0.0.1:4848/base/"}))

      uri = config |> Config.socket_url() |> URI.parse()
      assert {uri.scheme, uri.port, uri.path} == {"ws", 4848, "/base/node/socket/websocket"}
    end
  end

  test "inspect never prints the credential", %{home: home, cred: cred} do
    {:ok, config} = Config.load(env: env(home, cred))
    refute inspect(config) =~ "AAAA"
  end
end
