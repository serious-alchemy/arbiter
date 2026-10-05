defmodule Arbiter.Grok.CredentialStoreTest do
  # bd-9p4lx9: the canonical grok credential file. Pure file I/O in a private
  # tmp dir; no token value is a real one.
  use ExUnit.Case, async: true

  alias Arbiter.Grok.CredentialStore

  @entry_key "https://auth.x.ai::client-1"

  setup do
    dir = Path.join(System.tmp_dir!(), "gcs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "auth.json")}
  end

  defp write_auth!(path, overrides \\ %{}) do
    entry =
      Map.merge(
        %{
          "key" => "access-1",
          "auth_mode" => "oidc",
          "refresh_token" => "refresh-1",
          "expires_at" => "2030-01-01T00:00:00.000000000Z",
          "oidc_issuer" => "https://auth.x.ai",
          "oidc_client_id" => "client-1",
          "email" => "operator@example.com"
        },
        overrides
      )

    File.write!(path, Jason.encode!(%{@entry_key => entry}))
    File.chmod!(path, 0o600)
  end

  describe "read/1" do
    test "parses the OIDC entry", %{path: path} do
      write_auth!(path)

      assert {:ok, creds} = CredentialStore.read(path)
      assert creds.access_token == "access-1"
      assert creds.refresh_token == "refresh-1"
      assert creds.issuer == "https://auth.x.ai"
      assert creds.client_id == "client-1"
      assert creds.expires_at == ~U[2030-01-01 00:00:00.000000Z]
    end

    test "a missing file is :not_logged_in, and is not created", %{path: path} do
      assert {:error, :not_logged_in} = CredentialStore.read(path)
      refute File.exists?(path)
    end

    test "garbage and entry-less files are :not_logged_in", %{path: path} do
      File.write!(path, "not json")
      assert {:error, :not_logged_in} = CredentialStore.read(path)

      File.write!(path, "{}")
      assert {:error, :not_logged_in} = CredentialStore.read(path)
    end

    test "an entry with no refresh token is :not_logged_in", %{path: path} do
      write_auth!(path, %{"refresh_token" => nil})
      assert {:error, :not_logged_in} = CredentialStore.read(path)
    end
  end

  describe "persist/3" do
    test "rewrites only the token fields, keeps the rest, stays 0600", %{path: path} do
      write_auth!(path)
      {:ok, creds} = CredentialStore.read(path)

      rotated = %{
        access_token: "access-2",
        refresh_token: "refresh-2",
        expires_at: ~U[2030-06-01 12:00:00.000000Z]
      }

      assert :ok = CredentialStore.persist(path, creds, rotated)

      assert {:ok, back} = CredentialStore.read(path)
      assert back.access_token == "access-2"
      assert back.refresh_token == "refresh-2"
      assert back.expires_at == ~U[2030-06-01 12:00:00.000000Z]

      entry = path |> File.read!() |> Jason.decode!() |> Map.fetch!(@entry_key)
      assert entry["email"] == "operator@example.com"
      assert entry["oidc_client_id"] == "client-1"

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert File.ls!(Path.dirname(path)) == ["auth.json"]
    end

    test "a failed write is an error and leaves the previous file in place", %{path: path} do
      write_auth!(path)
      {:ok, creds} = CredentialStore.read(path)
      before = File.read!(path)

      rotated = %{access_token: "a", refresh_token: "r", expires_at: ~U[2031-01-01 00:00:00Z]}

      # The rename target is a directory, so the final step fails after the
      # temp file was written.
      blocked = Path.join(Path.dirname(path), "blocked.json")
      File.mkdir_p!(blocked)
      File.write!(Path.join(blocked, "keep"), "x")

      assert {:error, _} = CredentialStore.persist(blocked, creds, rotated)
      assert File.read!(path) == before
      assert File.ls!(Path.dirname(path)) |> Enum.sort() == ["auth.json", "blocked.json"]
    end

    test "an entry that vanished is an error, not a recreate", %{path: path} do
      write_auth!(path)
      {:ok, creds} = CredentialStore.read(path)
      File.write!(path, "{}")

      rotated = %{access_token: "a", refresh_token: "r", expires_at: ~U[2031-01-01 00:00:00Z]}
      assert {:error, :entry_gone} = CredentialStore.persist(path, creds, rotated)
      assert File.read!(path) == "{}"
    end
  end

  describe "fingerprint/1" do
    test "is stable, short, and does not contain the token" do
      fp = CredentialStore.fingerprint("refresh-1")
      assert fp == CredentialStore.fingerprint("refresh-1")
      refute fp == CredentialStore.fingerprint("refresh-2")
      refute fp =~ "refresh"
      assert byte_size(fp) == 12
    end
  end
end
