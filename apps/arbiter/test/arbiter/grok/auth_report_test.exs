defmodule Arbiter.Grok.AuthReportTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Grok.AuthReport
  alias Arbiter.Tasks.Workspace

  @moduletag :tmp_dir

  defp ws(name, config), do: %Workspace{name: name, config: config}
  defp on, do: ws("on", %{"routing" => %{"grok" => %{"enabled" => true}}})

  defp write_auth(dir, expires_at) do
    path = Path.join(dir, "auth.json")

    doc = %{
      "https://auth.x.ai::cid" => %{
        "key" => "secret-access",
        "refresh_token" => "secret-refresh",
        "expires_at" => DateTime.to_iso8601(expires_at),
        "oidc_issuer" => "https://auth.x.ai"
      }
    }

    File.write!(path, Jason.encode!(doc))
    path
  end

  test "nothing to report while no workspace uses grok" do
    assert %{enabled: false, workspaces: []} =
             AuthReport.report(
               workspaces: [ws("a", %{}), ws("b", %{"agent" => %{"type" => "claude"}})]
             )
  end

  test "an agent.type pin counts as in use", %{tmp_dir: dir} do
    r =
      AuthReport.report(
        workspaces: [ws("p", %{"agent" => %{"type" => ["claude", "grok"]}})],
        auth_path: Path.join(dir, "missing.json"),
        reauth_required: false
      )

    assert %{enabled: true, workspaces: ["p"], state: :not_logged_in} = r
  end

  test "not logged in names the fix", %{tmp_dir: dir} do
    r =
      AuthReport.report(
        workspaces: [on()],
        auth_path: Path.join(dir, "nope.json"),
        reauth_required: false
      )

    assert %{enabled: true, state: :not_logged_in, fix: fix, path: path} = r
    assert fix =~ path
  end

  test "logged in, expired, and reauth_required; never leaks a token", %{tmp_dir: dir} do
    now = ~U[2026-10-06 12:00:00Z]
    live = write_auth(dir, DateTime.add(now, 3600))
    base = [workspaces: [on()], now: now, reauth_required: false, broker_status: nil]

    r = AuthReport.report([auth_path: live] ++ base)
    assert %{state: :logged_in, fix: nil} = r
    refute inspect(r) =~ "secret"

    stale = write_auth(dir, DateTime.add(now, -60))
    ok_refresh = %{reauth_required?: false, last_attempt: :ok}

    assert %{state: :expired, fix: nil} =
             AuthReport.report([auth_path: stale, broker_status: ok_refresh] ++ base)

    assert %{state: :reauth_required, fix: fix} =
             AuthReport.report(Keyword.put([auth_path: live] ++ base, :reauth_required, true))

    assert fix =~ "grok login"
  end

  describe "bd-8rvkqd: the broker's file, and no free pass for an unrefreshable token" do
    defp account(slug), do: %Arbiter.Accounts.ProviderAccount{provider: :grok, slug: slug}

    test "reports the grok account's auth.json (what the login relay wrote), not ~/.grok",
         %{tmp_dir: dir} do
      account_dir = Path.join(dir, "grok-default")
      File.mkdir_p!(account_dir)
      path = write_auth(account_dir, ~U[2030-01-01 00:00:00Z])

      r =
        AuthReport.report(
          workspaces: [on()],
          auth_path: nil,
          accounts: [account("default")],
          accounts_root: dir,
          now: ~U[2026-10-06 12:00:00Z],
          broker_status: nil
        )

      assert %{state: :logged_in, path: ^path, path_source: :account} = r
      assert r.expires_at == "2030-01-01T00:00:00Z"
    end

    test "expired and never refreshed is a failure naming the path and expiry, no token",
         %{tmp_dir: dir} do
      now = ~U[2026-10-06 12:00:00Z]
      path = write_auth(dir, ~U[2026-10-02 12:00:00Z])

      for status <- [nil, %{reauth_required?: false, last_attempt: nil}] do
        r =
          AuthReport.report(
            workspaces: [on()],
            auth_path: path,
            now: now,
            broker_status: status
          )

        assert %{state: :refresh_unverified, path: ^path, expires_at: "2026-10-02T12:00:00Z"} = r
        assert r.fix =~ path
        refute inspect(r) =~ "secret"
      end
    end

    test "expired after a failed refresh is refresh_failed", %{tmp_dir: dir} do
      path = write_auth(dir, ~U[2026-10-02 12:00:00Z])

      r =
        AuthReport.report(
          workspaces: [on()],
          auth_path: path,
          now: ~U[2026-10-06 12:00:00Z],
          broker_status: %{reauth_required?: false, last_attempt: :transient}
        )

      assert %{state: :refresh_failed, fix: fix} = r
      assert fix =~ "last refresh failed"
    end

    test "the fallback path's fix says why ~/.grok is being read" do
      r =
        AuthReport.report(
          workspaces: [on()],
          auth_path: nil,
          accounts: [],
          broker_status: nil
        )

      assert %{path_source: :fallback, fix: fix} = r
      assert fix =~ "No grok provider account exists"
    end

    test "probe: the report makes the refresh attempt through the broker; a refused one is a fail",
         %{tmp_dir: dir} do
      now = DateTime.utc_now()
      path = write_auth(dir, DateTime.add(now, -3600))

      stub = :"auth_report_issuer_#{System.unique_integer([:positive])}"

      Req.Test.stub(stub, fn conn ->
        case conn.request_path do
          "/.well-known/openid-configuration" ->
            Req.Test.json(conn, %{"token_endpoint" => "https://auth.x.ai/oauth2/token"})

          "/oauth2/token" ->
            conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
        end
      end)

      {:ok, watchdog} =
        start_supervised(%{
          id: make_ref(),
          start:
            {Arbiter.Agents.CredentialWatchdog, :start_link,
             [[name: nil, enabled: false, adapters: [Arbiter.Grok.FakeAdapter]]]}
        })

      {:ok, broker} =
        start_supervised(%{
          id: make_ref(),
          start:
            {Arbiter.Grok.CredentialBroker, :start_link,
             [
               [
                 name: nil,
                 auth_path: path,
                 req_options: [plug: {Req.Test, stub}],
                 credential_watchdog: watchdog,
                 hold_adapter: Arbiter.Grok.FakeAdapter
               ]
             ]}
        })

      Req.Test.set_req_test_to_shared(%{async: false})

      base = [workspaces: [on()], auth_path: path, broker: broker]

      assert %{state: :refresh_unverified} = AuthReport.report(base)

      r = AuthReport.report([probe: true] ++ base)
      assert %{state: :reauth_required, path: ^path} = r
      assert r.fix =~ path
      refute inspect(r) =~ "secret"
    end
  end
end
