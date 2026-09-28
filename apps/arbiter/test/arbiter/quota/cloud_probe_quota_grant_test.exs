defmodule Arbiter.Quota.CloudProbeQuotaGrantTest do
  @moduledoc """
  CloudProbe with a dedicated quota-poller grant (bd-b632tz): an account's
  `:cli_credentials_path` credential names a `.credentials.json` that a
  `claude` login in its own `CLAUDE_CONFIG_DIR` keeps. The poll prefers it
  over every other `/api/oauth/usage` credential, reads its access token
  fresh each cycle, and never stores the token anywhere.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Messages.Message
  alias Arbiter.Quota.CloudProbe
  alias Arbiter.Tasks.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} = context do
    Application.put_env(:arbiter, :oauth_usage_http_stub, true)
    Req.Test.set_req_test_to_shared(context)

    account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "grant-poll"})
    ws = Ash.create!(Workspace, %{name: "grant-poll-ws"})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    # A pre-bd-b632tz snapshot credential on the same account: the grant must win.
    Ash.create!(ProviderCredential, %{
      provider_account_id: account.id,
      kind: :cli_credentials_file,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      fingerprint: "grant-poll-snapshot-fp",
      secret: "stale-snapshot-token"
    })

    grant_dir = Path.join(tmp_dir, "quota-claude")
    File.mkdir_p!(grant_dir)
    grant_file = Path.join(grant_dir, ".credentials.json")
    write_grant!(grant_file, "grant-token-1")

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: grant_dir})

    on_exit(fn -> Arbiter.Quota.OAuthUsage.reset_cooldown!(account.id) end)

    %{account: account, ws: ws, grant_dir: grant_dir, grant_file: grant_file}
  end

  defp write_grant!(path, token) do
    File.write!(
      path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => token,
          "expiresAt" => System.system_time(:millisecond) + 3_600_000
        }
      })
    )
  end

  defp start_probe(opts) do
    start_supervised!({CloudProbe, Keyword.merge([name: nil, enabled: true], opts)})
  end

  defp start_watchdog do
    {:ok, pid} =
      start_supervised(%{
        id: make_ref(),
        start: {CredentialWatchdog, :start_link, [[name: nil, enabled: false]]}
      })

    pid
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(5)
        wait_until(fun, deadline)
    end
  end

  defp stub_usage(status) do
    test_pid = self()

    Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
      send(test_pid, {:oauth_usage_call, Plug.Conn.get_req_header(conn, "authorization")})

      case status do
        200 -> Req.Test.json(conn, %{"seven_day_sonnet" => %{"utilization" => 42}})
        code -> Plug.Conn.send_resp(conn, code, "")
      end
    end)
  end

  test "prefers the grant, re-reads its access token every poll, and stores no token",
       %{account: account, grant_file: grant_file} do
    stub_usage(200)
    pid = start_probe(interval_ms: 3_600_000, refresh_fun: fn _ -> :ok end)

    CloudProbe.probe(pid)
    assert_receive {:oauth_usage_call, ["Bearer grant-token-1"]}, 2_000
    wait_until(fn -> CloudProbe.state(pid).probe_count == 1 end)

    # The CLI refreshed the grant in place: the next poll must use the new token.
    write_grant!(grant_file, "grant-token-2")
    Arbiter.Quota.OAuthUsage.reset_cooldown!(account.id)
    CloudProbe.probe(pid)
    assert_receive {:oauth_usage_call, ["Bearer grant-token-2"]}, 2_000
    refute_received {:oauth_usage_call, ["Bearer stale-snapshot-token"]}

    # Nothing Arbiter persisted holds either token: the grant row is a path.
    secrets =
      ProviderCredential
      |> Ash.read!()
      |> Enum.map(&ProviderCredential.secret/1)

    assert grant_file in secrets
    refute Enum.any?(secrets, &(&1 =~ "grant-token"))
  end

  test "a lapsed grant escalates once, naming the re-login command, and never marks Claude expired",
       %{grant_dir: grant_dir, grant_file: grant_file} do
    stub_usage(401)
    watchdog = start_watchdog()

    pid =
      start_probe(
        interval_ms: 3_600_000,
        refresh_fun: fn _ -> :ok end,
        credential_watchdog: watchdog,
        oauth_401_expiry_threshold: 1
      )

    ExUnit.CaptureLog.capture_log(fn ->
      CloudProbe.probe(pid)
      assert_receive {:oauth_usage_call, ["Bearer grant-token-1"]}, 2_000
      wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_failures == 1 end)

      # Then the grant file disappears altogether.
      File.rm!(grant_file)

      for n <- 2..5 do
        CloudProbe.probe(pid)
        wait_until(fn -> CloudProbe.state(pid).oauth_consecutive_failures == n end)
      end
    end)

    # The poll never falls back to the stale snapshot credential.
    refute_received {:oauth_usage_call, ["Bearer stale-snapshot-token"]}

    [msg] = Message.inbox(Message.coordinator_ref())
    assert msg.kind == :escalation
    assert msg.subject =~ "quota grant"
    assert msg.body =~ "CLAUDE_CONFIG_DIR=#{grant_dir} claude auth login"
    refute msg.subject =~ "interactive Claude login lapsed"

    _ = :sys.get_state(watchdog)
    refute CredentialWatchdog.escalated?(Arbiter.Agents.Claude, watchdog)
  end
end
