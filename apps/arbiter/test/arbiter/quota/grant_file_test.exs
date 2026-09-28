defmodule Arbiter.Quota.GrantFileTest do
  @moduledoc """
  `Arbiter.Quota.GrantFile` (bd-b632tz) — reads the dedicated quota-poller
  grant's `.credentials.json` by path, fresh on every call, without ever
  exposing the access token through `inspect/1`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Quota.GrantFile

  @moduletag :tmp_dir

  defp write_grant!(dir, oauth) do
    path = Path.join(dir, ".credentials.json")
    File.write!(path, Jason.encode!(%{"claudeAiOauth" => oauth}))
    path
  end

  describe "read/1" do
    test "returns the access token and both expiries", %{tmp_dir: dir} do
      path =
        write_grant!(dir, %{
          "accessToken" => "grant-access-token",
          "refreshToken" => "grant-refresh-token",
          "expiresAt" => 1_790_569_839_391,
          "refreshTokenExpiresAt" => 1_793_099_795_391
        })

      assert {:ok, %GrantFile{} = grant} = GrantFile.read(path)
      assert grant.access_token == "grant-access-token"
      assert grant.expires_at == ~U[2026-09-28 04:30:39.391Z]
      assert grant.refresh_token_expires_at == ~U[2026-10-27 11:16:35.391Z]
      assert grant.path == path
    end

    test "never shows either token when inspected", %{tmp_dir: dir} do
      path =
        write_grant!(dir, %{
          "accessToken" => "grant-access-token",
          "refreshToken" => "grant-refresh-token",
          "expiresAt" => 1_790_569_839_391
        })

      {:ok, grant} = GrantFile.read(path)
      refute inspect(grant) =~ "grant-access-token"
      refute inspect(grant) =~ "grant-refresh-token"
    end

    test "re-reads the file on every call", %{tmp_dir: dir} do
      path = write_grant!(dir, %{"accessToken" => "first", "expiresAt" => 1_790_569_839_391})
      assert {:ok, %{access_token: "first"}} = GrantFile.read(path)

      write_grant!(dir, %{"accessToken" => "second", "expiresAt" => 1_790_569_839_391})
      assert {:ok, %{access_token: "second"}} = GrantFile.read(path)
    end

    test "missing expiries read as nil", %{tmp_dir: dir} do
      path = write_grant!(dir, %{"accessToken" => "t"})
      assert {:ok, %{expires_at: nil, refresh_token_expires_at: nil}} = GrantFile.read(path)
    end

    test "a missing file, bad JSON or no access token is an error", %{tmp_dir: dir} do
      assert {:error, :enoent} = GrantFile.read(Path.join(dir, "nope.json"))

      bad = Path.join(dir, "bad.json")
      File.write!(bad, "{not json")
      assert {:error, :malformed} = GrantFile.read(bad)

      assert {:error, :no_access_token} = GrantFile.read(write_grant!(dir, %{"expiresAt" => 1}))
    end
  end

  describe "normalize_path/1" do
    test "a config dir resolves to the .credentials.json inside it", %{tmp_dir: dir} do
      path = write_grant!(dir, %{"accessToken" => "t"})
      assert GrantFile.normalize_path(dir) == {:ok, path}
      assert GrantFile.normalize_path(path) == {:ok, path}
    end

    test "expands ~ and relative segments", %{tmp_dir: dir} do
      path = write_grant!(dir, %{"accessToken" => "t"})
      assert GrantFile.normalize_path(dir <> "/./") == {:ok, path}
    end

    test "rejects a file not named .credentials.json — the CLI would never refresh it",
         %{tmp_dir: dir} do
      other = Path.join(dir, "creds.json")
      File.write!(other, Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "t"}}))
      assert {:error, :not_a_credentials_file} = GrantFile.normalize_path(other)
    end

    test "rejects a path with no readable grant", %{tmp_dir: dir} do
      assert {:error, :enoent} = GrantFile.normalize_path(dir)
    end
  end

  test "config_dir/1 is the CLAUDE_CONFIG_DIR the CLI refreshes the file under" do
    assert GrantFile.config_dir("/x/quota-claude/.credentials.json") == "/x/quota-claude"
  end
end
