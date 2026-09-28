defmodule Arbiter.Accounts.QuotaGrantCredentialTest do
  @moduledoc """
  The `:cli_credentials_path` credential kind (bd-b632tz): an account
  references the quota poller's dedicated Claude grant **by path**. The row
  stores the location only — never the grant's tokens — and is never
  projected into a worker's spawn env.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace

  @moduletag :tmp_dir

  defp account!(slug, attrs \\ %{}) do
    Ash.create!(ProviderAccount, Map.merge(%{provider: :claude, slug: slug}, attrs))
  end

  defp grant_dir!(tmp_dir, token \\ "grant-access-token") do
    dir = Path.join(tmp_dir, "quota-claude")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".credentials.json"),
      Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => token, "expiresAt" => 1}})
    )

    dir
  end

  describe "Accounts.rotate_credential/2 with kind cli_credentials_path" do
    test "stores the normalized .credentials.json path, never the token, under CLAUDE_CONFIG_DIR",
         %{tmp_dir: tmp_dir} do
      account = account!("grant-rotate")
      dir = grant_dir!(tmp_dir)

      assert {:ok, credential} =
               Accounts.rotate_credential(account.id, %{
                 "kind" => "cli_credentials_path",
                 "secret" => dir
               })

      assert credential.kind == :cli_credentials_path
      assert credential.env_var == "CLAUDE_CONFIG_DIR"

      {:ok, stored} = Ash.get(ProviderCredential, credential.id)
      assert ProviderCredential.secret(stored) == Path.join(dir, ".credentials.json")
      refute ProviderCredential.secret(stored) =~ "grant-access-token"
    end

    test "a blank env var (the dashboard form's default) still files it under CLAUDE_CONFIG_DIR",
         %{tmp_dir: tmp_dir} do
      account = account!("grant-blank-env")

      assert {:ok, %{env_var: "CLAUDE_CONFIG_DIR"}} =
               Accounts.rotate_credential(account.id, %{
                 "kind" => "cli_credentials_path",
                 "env_var" => "",
                 "secret" => grant_dir!(tmp_dir)
               })
    end

    test "refuses a location with no readable grant", %{tmp_dir: tmp_dir} do
      account = account!("grant-missing")

      assert {:error, {:invalid_credentials_path, :enoent}} =
               Accounts.rotate_credential(account.id, %{
                 kind: :cli_credentials_path,
                 secret: Path.join(tmp_dir, "nowhere")
               })
    end
  end

  describe "Credentials.account_quota_grant_path/1" do
    test "returns the path of the account's active grant", %{tmp_dir: tmp_dir} do
      account = account!("grant-path")
      dir = grant_dir!(tmp_dir)

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})

      assert Credentials.account_quota_grant_path(account.id) ==
               {:ok, Path.join(dir, ".credentials.json")}
    end

    test "is :none for a parked account or an account without one", %{tmp_dir: tmp_dir} do
      account = account!("grant-parked")
      dir = grant_dir!(tmp_dir)

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})

      Ash.update!(account, %{enabled: false})

      assert Credentials.account_quota_grant_path(account.id) == :none
      assert Credentials.account_quota_grant_path(account!("grant-none").id) == :none
      assert Credentials.account_quota_grant_path(nil) == :none
    end
  end

  test "quota_grants/0 lists every enabled account's grant path", %{tmp_dir: tmp_dir} do
    account = account!("grant-list")
    dir = grant_dir!(tmp_dir)

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})

    assert %{account_id: account.id, path: Path.join(dir, ".credentials.json")} in Credentials.quota_grants()
  end

  test "a grant path is never projected into a spawn env", %{tmp_dir: tmp_dir} do
    account = account!("grant-no-env")
    dir = grant_dir!(tmp_dir)

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})

    ws = Ash.create!(Workspace, %{name: "grant-no-env-ws"})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    assert Credentials.workspace_pairs(ws.id) == []
    assert Credentials.install_credential("CLAUDE_CONFIG_DIR") == :none
  end
end
