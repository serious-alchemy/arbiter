defmodule Arbiter.Accounts.LoginCompletionTest do
  @moduledoc """
  bd-djh1yr (login relay 4/6): what a confirmed login does — reference the
  dedicated config dir as the account's credential, clear the matching alerts,
  poke the quota poller, and write the Login history record.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.LoginCompletion
  alias Arbiter.Accounts.LoginRecord
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Agents.Claude
  alias Arbiter.Alerts

  @token "SECRET-ACCESS-TOKEN-1234"

  setup do
    dir = Path.join(System.tmp_dir!(), "lc4-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write_grant(dir, provider \\ :claude) do
    {name, body} =
      case provider do
        :claude -> {".credentials.json", ~s({"claudeAiOauth":{"accessToken":"#{@token}"}})}
        :codex -> {"auth.json", ~s({"tokens":{"access_token":"#{@token}"}})}
      end

    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  defp info(provider, account, dir, extra \\ %{}) do
    Map.merge(
      %{
        login_id: Ash.UUID.generate(),
        provider: provider,
        account: account,
        config_dir: dir,
        started_by: "operator",
        started_at: DateTime.add(DateTime.utc_now(), -30, :second)
      },
      extra
    )
  end

  defp active_credentials(account_id) do
    ProviderCredential
    |> Ash.read!()
    |> Enum.filter(&(&1.provider_account_id == account_id and &1.active))
    |> Ash.load!(:secret)
  end

  defp raise_expired do
    {:ok, _} =
      Alerts.raise_alert(%{
        kind: :credential_expired,
        key: "#{inspect(Claude)}:worker_report",
        detail: "expired"
      })
  end

  test "success references the dedicated dir, copies nothing, clears the alert, polls quota",
       %{dir: dir} do
    path = write_grant(dir)
    {:ok, account} = Accounts.create_account(%{provider: :claude, slug: "work"})
    raise_expired()
    test_pid = self()

    assert {:ok, result} =
             LoginCompletion.complete(info(:claude, "work", dir),
               outcome: :succeeded,
               quota_refresh: fn account_id -> send(test_pid, {:quota_poll, account_id}) end
             )

    # credential by reference
    assert [credential] = active_credentials(account.id)
    assert credential.kind == :cli_credentials_path
    assert credential.secret == path
    assert result.credential == :referenced

    # nothing copied: the only credential file is the CLI's own
    assert dir |> File.ls!() |> Enum.sort() == [".credentials.json"]

    # alert cleared
    assert {:ok, []} = Alerts.clear(:credential_expired, "#{inspect(Claude)}:worker_report")

    # quota poller poked for the poller account
    assert_receive {:quota_poll, account_id}
    assert account_id == account.id
  end

  test "a lapsed-login escalation naming the config dir is cleared", %{dir: dir} do
    write_grant(dir)
    {:ok, _} = Accounts.create_account(%{provider: :claude, slug: "lapsed"})
    snapshot = %{workspace_id: "ws-lapsed"}

    :ok =
      Arbiter.Messages.CoordinatorNotifier.quota_grant_failing(
        snapshot,
        Path.join(dir, ".credentials.json"),
        {:poll_failing, 3, {:http_error, 401}}
      )

    subject = "Anthropic quota grant needs re-login — #{dir}"

    assert Arbiter.Messages.Message.last_escalation(:quota_grant_failing,
             subject: subject,
             open: true
           )

    {:ok, _} =
      LoginCompletion.complete(info(:claude, "lapsed", dir),
        outcome: :succeeded,
        quota_refresh: fn _ -> :ok end
      )

    refute Arbiter.Messages.Message.last_escalation(:quota_grant_failing,
             subject: subject,
             open: true
           )
  end

  test "records a Login history row with a non-secret fingerprint", %{dir: dir} do
    write_grant(dir)
    {:ok, _} = Accounts.create_account(%{provider: :claude, slug: "hist"})
    i = info(:claude, "hist", dir)

    assert {:ok, _} =
             LoginCompletion.complete(i, outcome: :succeeded, quota_refresh: fn _ -> :ok end)

    assert [record] = LoginRecord |> Ash.read!() |> Enum.filter(&(&1.account == "hist"))
    assert record.outcome == :succeeded
    assert record.started_by == "operator"
    assert record.provider == :claude
    assert %DateTime{} = record.ended_at
    assert DateTime.compare(record.started_at, record.ended_at) == :lt
    assert record.fingerprint =~ ~r/\A[0-9a-f]{12}\z/
    refute inspect(record) =~ @token
  end

  test "a failed login records history without a fingerprint and leaves alerts alone", %{dir: dir} do
    {:ok, _} = Accounts.create_account(%{provider: :claude, slug: "bad"})
    raise_expired()

    assert {:ok, _} = LoginCompletion.complete(info(:claude, "bad", dir), outcome: :failed)

    assert [record] = LoginRecord |> Ash.read!() |> Enum.filter(&(&1.account == "bad"))
    assert record.outcome == :failed
    assert record.fingerprint == nil
    assert [_active] = Alerts.active(kind: :credential_expired)
  end

  test "an account without a known account row is created and referenced", %{dir: dir} do
    path = write_grant(dir)

    assert {:ok, %{credential: :referenced}} =
             LoginCompletion.complete(info(:claude, "fresh", dir),
               outcome: :succeeded,
               quota_refresh: fn _ -> :ok end
             )

    assert {:ok, account} = Accounts.get_account("claude:fresh")
    assert [%{secret: ^path}] = active_credentials(account.id)
  end

  test "re-login replaces the active reference instead of stacking", %{dir: dir} do
    write_grant(dir)
    {:ok, account} = Accounts.create_account(%{provider: :claude, slug: "again"})
    opts = [outcome: :succeeded, quota_refresh: fn _ -> :ok end]

    {:ok, _} = LoginCompletion.complete(info(:claude, "again", dir), opts)
    {:ok, _} = LoginCompletion.complete(info(:claude, "again", dir), opts)

    assert [_one] = active_credentials(account.id)
  end

  test "codex has no quota grant: no credential row, no poll, still records history",
       %{dir: dir} do
    write_grant(dir, :codex)
    {:ok, _} = Accounts.create_account(%{provider: :codex, slug: "cx"})
    test_pid = self()

    assert {:ok, %{credential: :unsupported}} =
             LoginCompletion.complete(info(:codex, "cx", dir),
               outcome: :succeeded,
               quota_refresh: fn id -> send(test_pid, {:quota_poll, id}) end
             )

    refute_received {:quota_poll, _}
    assert [record] = LoginRecord |> Ash.read!() |> Enum.filter(&(&1.account == "cx"))
    assert record.fingerprint =~ ~r/\A[0-9a-f]{12}\z/
  end
end
