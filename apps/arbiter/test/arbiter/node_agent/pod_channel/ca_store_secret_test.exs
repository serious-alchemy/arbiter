defmodule Arbiter.NodeAgent.PodChannel.CAStore.SecretTest do
  @moduledoc """
  The cluster's CA store (`docs/design/remote-workers.md` §16 K§2.4 step 2, K§12, ticket
  K14): the CA key and certificate in the Secret `arbiter-controller-ca`, the public
  certificate alone in the ConfigMap `arbiter-ca` the worker pods mount. Against the fake
  API server: the install's placeholders exist, the store only ever updates them.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PodChannel.{CA, Cert}
  alias Arbiter.NodeAgent.PodChannel.CAStore.Secret, as: SecretStore
  alias Arbiter.Test.FakeK8sApi

  @secret "arbiter-controller-ca"
  @config_map "arbiter-ca"

  setup do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")

    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => @secret, "namespace" => "arbiter-workers"},
      "type" => "Opaque"
    })

    FakeK8sApi.put_config_map(env.api, %{
      "metadata" => %{"name" => @config_map, "namespace" => "arbiter-workers"}
    })

    Map.put(env, :store, {SecretStore, env.client})
  end

  defp secret_data(api), do: FakeK8sApi.secret(api, @secret)["data"] || %{}

  defp puts(api, path_suffix) do
    api
    |> FakeK8sApi.requests()
    |> Enum.count(&(&1.method == "PUT" and String.ends_with?(&1.path, path_suffix)))
  end

  test "first boot stores the CA in the Secret and publishes only the certificate", env do
    assert {:ok, ca} = CA.load_or_create(env.store)

    data = secret_data(env.api)
    assert Map.keys(data) |> Enum.sort() == ["ca.crt", "ca.key"]
    assert Base.decode64!(data["ca.crt"]) == Cert.pem_cert(ca.der)
    assert Base.decode64!(data["ca.key"]) =~ "EC PRIVATE KEY"

    published = FakeK8sApi.config_map(env.api, @config_map)["data"]
    assert published == %{"ca.crt" => Cert.pem_cert(ca.der)}
    refute inspect(published) =~ "PRIVATE KEY"
  end

  test "the next boot reads the same CA back and writes no Secret", env do
    {:ok, first} = CA.load_or_create(env.store)
    {:ok, second} = CA.load_or_create(env.store)

    assert first.der == second.der
    assert puts(env.api, "/secrets/#{@secret}") == 1
  end

  test "an unchanged published certificate is not written again", env do
    {:ok, _} = CA.load_or_create(env.store)
    {:ok, _} = CA.load_or_create(env.store)

    assert puts(env.api, "/configmaps/#{@config_map}") == 1
  end

  test "publishing keeps whatever else the ConfigMap holds", env do
    FakeK8sApi.put_config_map(env.api, %{
      "metadata" => %{"name" => @config_map},
      "data" => %{"README" => "the controller fills ca.crt"}
    })

    {:ok, ca} = CA.load_or_create(env.store)

    assert FakeK8sApi.config_map(env.api, @config_map)["data"] == %{
             "README" => "the controller fills ca.crt",
             "ca.crt" => Cert.pem_cert(ca.der)
           }
  end

  test "a Secret holding half a CA is an error, never replaced", env do
    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => @secret},
      "data" => %{"ca.crt" => Base.encode64("-----BEGIN CERTIFICATE-----\n")}
    })

    assert {:error, {:ca_load_failed, :incomplete}} = CA.load_or_create(env.store)
    assert puts(env.api, "/secrets/#{@secret}") == 0
  end

  test "a value that is not base64 is an error", env do
    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => @secret},
      "data" => %{"ca.crt" => "%%%", "ca.key" => "%%%"}
    })

    assert {:error, {:ca_load_failed, :bad_encoding}} = CA.load_or_create(env.store)
  end

  test "save never overwrites a CA another controller stored in the meantime", env do
    assert :none = SecretStore.load(env.client)

    FakeK8sApi.put_secret(env.api, %{
      "metadata" => %{"name" => @secret},
      "data" => %{"ca.crt" => Base.encode64("theirs"), "ca.key" => Base.encode64("theirs")}
    })

    assert {:error, :already_stored} =
             SecretStore.save(env.client, %{cert: "mine", key: "mine"})

    assert secret_data(env.api)["ca.crt"] == Base.encode64("theirs")
  end

  test "an API error fails the load instead of minting a new CA", env do
    FakeK8sApi.fail_next(env.api, :secret_get, {403, "secrets is forbidden"})

    assert {:error, {:ca_load_failed, {:forbidden, "secrets is forbidden"}}} =
             CA.load_or_create(env.store)

    assert puts(env.api, "/secrets/#{@secret}") == 0
  end

  test "a missing placeholder Secret is an error: the store never creates one" do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")

    assert {:error, {:ca_load_failed, :not_found}} =
             CA.load_or_create({SecretStore, env.client})
  end
end
