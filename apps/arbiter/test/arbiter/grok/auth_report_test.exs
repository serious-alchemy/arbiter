defmodule Arbiter.Grok.AuthReportTest do
  use ExUnit.Case, async: true

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

    assert %{enabled: true, state: :not_logged_in, fix: fix} = r
    assert fix =~ "grok login --device-code"
  end

  test "logged in, expired, and reauth_required; never leaks a token", %{tmp_dir: dir} do
    now = ~U[2026-10-06 12:00:00Z]
    live = write_auth(dir, DateTime.add(now, 3600))
    base = [workspaces: [on()], now: now, reauth_required: false]

    r = AuthReport.report([auth_path: live] ++ base)
    assert %{state: :logged_in, fix: nil} = r
    refute inspect(r) =~ "secret"

    stale = write_auth(dir, DateTime.add(now, -60))
    assert %{state: :expired} = AuthReport.report([auth_path: stale] ++ base)

    assert %{state: :reauth_required, fix: fix} =
             AuthReport.report(Keyword.put([auth_path: live] ++ base, :reauth_required, true))

    assert fix =~ "grok login"
  end
end
