defmodule Arbiter.Worker.Image.RegistryTest do
  @moduledoc """
  K8 (bd-9vrbx7): the `nodes.registry` credential handling. The password reaches
  podman only through a 0600 auth file that is gone afterwards, and no
  rendering of the config (inspect, error text) carries it.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Settings
  alias Arbiter.Worker.Image.Registry

  @password "p4ss-w0rd-NEVER-LOGGED"

  defp config(extra \\ %{}) do
    {:ok, cfg} =
      Registry.fetch(
        config:
          Map.merge(
            %{
              registry: "registry.example.com:5000/arbiter",
              username: "bot",
              password: @password,
              insecure?: false
            },
            extra
          )
      )

    cfg
  end

  describe "fetch/1" do
    test ":unset when nodes.registry is not configured" do
      assert Registry.fetch() == :unset
    end

    test "reads the settings, decrypting the password" do
      {:ok, _} = Settings.Registry.put("nodes.registry", "registry.example.com/arb")
      {:ok, _} = Settings.Registry.put("nodes.registry_username", "bot")
      {:ok, _} = Settings.Registry.put("nodes.registry_password", @password)
      {:ok, _} = Settings.Registry.put("nodes.registry_insecure", true)

      assert {:ok, cfg} = Registry.fetch()
      assert cfg.registry == "registry.example.com/arb"
      assert cfg.host == "registry.example.com"
      assert cfg.username == "bot"
      assert cfg.password == @password
      assert cfg.insecure?
    end
  end

  test "repository/2 joins the registry path and the image name" do
    assert Registry.repository(config(), "worker") == "registry.example.com:5000/arbiter/worker"
    assert config().host == "registry.example.com:5000"
  end

  test "the password never appears when the config is inspected" do
    refute inspect(config()) =~ @password
  end

  describe "with_authfile/3" do
    @tag :tmp_dir
    test "writes a 0600 auth file that exists only inside the callback", %{tmp_dir: tmp} do
      {path, body} =
        Registry.with_authfile(config(), tmp, fn path ->
          assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
          assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
          {path, File.read!(path)}
        end)

      refute File.exists?(path)
      refute File.exists?(Path.dirname(path))

      assert %{"auths" => %{"registry.example.com:5000" => %{"auth" => auth}}} =
               Jason.decode!(body)

      assert Base.decode64!(auth) == "bot:" <> @password
    end

    @tag :tmp_dir
    test "no username and password: no auth file at all", %{tmp_dir: tmp} do
      cfg = config(%{username: nil, password: nil})
      assert Registry.with_authfile(cfg, tmp, & &1) == nil
    end

    @tag :tmp_dir
    test "the file is removed even when the callback raises", %{tmp_dir: tmp} do
      test_pid = self()

      assert_raise RuntimeError, fn ->
        Registry.with_authfile(config(), tmp, fn path ->
          send(test_pid, {:path, path})
          raise "boom"
        end)
      end

      assert_received {:path, path}
      refute File.exists?(path)
    end
  end

  test "redact/2 scrubs the password and its base64 form from tool output" do
    cfg = config()
    basic = Base.encode64("bot:" <> @password)

    out = Registry.redact("denied: #{@password} Authorization: Basic #{basic} ok", cfg)
    refute out =~ @password
    refute out =~ basic
    assert out =~ "denied:"
  end

  test "push_flags/1 asks for no TLS verification only for an insecure registry" do
    assert Registry.tls_flags(config()) == []
    assert Registry.tls_flags(config(%{insecure?: true})) == ["--tls-verify=false"]
  end

  test "digest_pinned?/1" do
    digest = String.duplicate("a", 64)
    assert Registry.digest_pinned?("registry.example.com/arb/worker@sha256:" <> digest)
    refute Registry.digest_pinned?("registry.example.com/arb/worker:latest")
    refute Registry.digest_pinned?("registry.example.com/arb/worker@sha256:abc")
  end
end
