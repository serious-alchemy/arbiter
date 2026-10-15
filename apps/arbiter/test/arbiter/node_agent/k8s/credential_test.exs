defmodule Arbiter.NodeAgent.K8s.CredentialTest do
  @moduledoc """
  A cluster controller's node credential (`docs/design/remote-workers.md` K§2.4 step 1,
  K§12; ticket K14): read from the Secret `arbiter-node-credential` on every boot but the
  first, which redeems the operator's join token at `POST /nodes/enroll` and writes the
  answer to that Secret. The primary here is a Req plug; the cluster is the fake API.
  """
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Arbiter.NodeAgent.K8s.Credential
  alias Arbiter.Test.FakeK8sApi

  @moduletag :tmp_dir
  @credential "arbn_0199e3a1-node." <> String.duplicate("s", 52)

  setup %{tmp_dir: dir} do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")

    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => "arbiter-node-credential", "namespace" => "arbiter-workers"},
      "type" => "Opaque"
    })

    token_file = Path.join(dir, "token")
    Map.merge(env, %{token_file: token_file, dir: dir})
  end

  # A primary whose /nodes/enroll answers `status` with `body`, and tells the test what it got.
  defp primary(status, body) do
    test = self()

    fn conn ->
      {:ok, raw, conn} = read_body(conn)
      send(test, {:enroll, conn.method, conn.request_path, Jason.decode!(raw)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  defp opts(env, plug, extra \\ []) do
    [
      primary_url: "https://primary.example.ts.net",
      token_file: env.token_file,
      name: "mesaana-k3s",
      k8s_version: "v1.31.2+k3s1",
      agent_version: "1.2.3",
      req_options: [plug: plug, retry: false]
    ] ++ extra
  end

  defp stored(env) do
    case FakeK8sApi.secret(env.api, "arbiter-node-credential")["data"] do
      %{"credential" => value} -> Base.decode64!(value)
      _ -> nil
    end
  end

  test "a stored credential is used; nothing is enrolled", env do
    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => "arbiter-node-credential"},
      "data" => %{"credential" => Base.encode64(@credential <> "\n")}
    })

    assert {:ok, @credential} =
             Credential.obtain(env.client, opts(env, fn _ -> flunk("enrolled") end))
  end

  test "first boot: the join token is redeemed and the credential written to the Secret", env do
    File.write!(env.token_file, "arbj_join-token-1\n")

    assert {:ok, @credential} =
             Credential.obtain(
               env.client,
               opts(env, primary(200, %{"credential" => @credential}))
             )

    assert_received {:enroll, "POST", "/nodes/enroll", body}

    assert body == %{
             "token" => "arbj_join-token-1",
             "kind" => "cluster",
             "name" => "mesaana-k3s",
             "k8s_version" => "v1.31.2+k3s1",
             "proto" => Arbiter.NodeAgent.Config.proto(),
             "agent_version" => "1.2.3"
           }

    assert stored(env) == @credential
    # The Secret holds the credential and nothing else; the token is never written.
    assert Map.keys(FakeK8sApi.secret(env.api, "arbiter-node-credential")["data"]) ==
             ["credential"]
  end

  test "no credential and no join token yet says so (the operator has not created it)", env do
    assert {:error, :no_join_token} =
             Credential.obtain(env.client, opts(env, fn _ -> flunk("enrolled") end))
  end

  test "a refused join token is an error naming why, and nothing is stored", env do
    File.write!(env.token_file, "arbj_spent")

    assert {:error, {:enroll_refused, 401, "Invalid or expired join token"}} =
             Credential.obtain(
               env.client,
               opts(
                 env,
                 primary(401, %{"error" => %{"message" => "Invalid or expired join token"}})
               )
             )

    assert stored(env) == nil
  end

  test "an answer without a credential is an error", env do
    File.write!(env.token_file, "arbj_t")

    assert {:error, {:enroll_refused, 200, _}} =
             Credential.obtain(env.client, opts(env, primary(200, %{"credential" => "nope"})))
  end

  test "a credential that cannot be stored is handed back so it is not lost", env do
    File.write!(env.token_file, "arbj_t")
    FakeK8sApi.fail_next(env.api, :secret_update, {403, "secrets is forbidden"})

    assert {:error, {:store_failed, {:forbidden, "secrets is forbidden"}, @credential}} =
             Credential.obtain(
               env.client,
               opts(env, primary(200, %{"credential" => @credential}))
             )

    # Storing again later, once the API lets it, needs no second enrolment.
    assert :ok = Credential.store(env.client, @credential)
    assert stored(env) == @credential
  end

  test "a stored value that is not a node credential is an error, not a re-enrolment", env do
    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => "arbiter-node-credential"},
      "data" => %{"credential" => Base.encode64("garbage")}
    })

    File.write!(env.token_file, "arbj_t")

    assert {:error, :credential_malformed} =
             Credential.obtain(env.client, opts(env, fn _ -> flunk("enrolled") end))
  end

  test "the Secret's API failure is an error (never a reason to enrol again)", env do
    FakeK8sApi.fail_next(env.api, :secret_get, 503)
    File.write!(env.token_file, "arbj_t")

    assert {:error, {:http, 503, _}} =
             Credential.obtain(env.client, opts(env, fn _ -> flunk("enrolled") end))
  end

  test "store never replaces a different credential already in the Secret", env do
    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => "arbiter-node-credential"},
      "data" => %{"credential" => Base.encode64("arbn_other.secret")}
    })

    assert {:error, :already_stored} = Credential.store(env.client, @credential)
    assert stored(env) == "arbn_other.secret"
    assert :ok = Credential.store(env.client, "arbn_other.secret")
  end
end
