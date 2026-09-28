defmodule ArbiterWeb.Api.ServerController do
  @moduledoc """
  Server health and status endpoints.

  Routes:
    * `GET /api/server/migrations` — check for pending database migrations
    * `GET /api/server/bind_address` — what address the HTTP listener is
      actually bound to (bd-1c4pg3). `arb server doctor` uses this to warn
      when a server — possibly remote, via `ARB_HOST` — is reachable
      off-loopback despite the dashboard's no-login auth model.
    * `GET /api/server/agy_write_jail` — whether *this host* can jail an agy
      spawn (bd-8xy1mf), i.e. `Arbiter.Worker.Jail.diagnose/0`. The
      per-workspace `write_jail_warning` in the workspace posture only says
      whether a given workspace's resolved policy is degraded by this; a CLI
      running on the server host needs the host's own answer even when no
      workspace currently resolves `:strict`, so `arb server doctor` has
      something to show for AC1/AC6's "can this host jail agy at all" check.
    * `GET /api/server/claude_credentials` — every workspace that runs Claude
      with no setup token (or API key) of its own (bd-80ecol,
      `Arbiter.Agents.Claude.CredentialCheck.workspace_report/0`): the ones
      that used to fall back to a copy of the operator's `.credentials.json`,
      and whose Claude dispatch is now held. `arb server doctor` lists them.
      A failed read is a 500, so the doctor reports "could not check" rather
      than a false all-clear.
    * `GET /api/server/provider_accounts` — how `:provider_accounts_enabled`
      resolved for this boot (bd-cvvb02, `Arbiter.Accounts.Enablement.status/0`):
      the configured value (`auto` / `true` / `false`), whether accounts are
      on, the decision, and — re-read live — every workspace a spawn would
      raise `MissingCredentialError` for with accounts on. `arb server doctor`
      fails when an un-migrated install is held off, and points at the runbook.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts.Enablement
  alias Arbiter.Agents.Claude.CredentialCheck
  alias Arbiter.Worker.Jail

  def migrations(conn, _params) do
    case Arbiter.Migrations.count_pending() do
      {:ok, 0} ->
        json(conn, %{
          status: "ok",
          pending_count: 0
        })

      {:ok, count} ->
        json(conn, %{
          status: "warning",
          pending_count: count
        })

      {:error, reason} ->
        json(conn, %{
          status: "unknown",
          pending_count: nil,
          error: Atom.to_string(reason)
        })
    end
  end

  def bind_address(conn, _params) do
    ip =
      :arbiter_web
      |> Application.get_env(ArbiterWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:ip)

    json(conn, %{
      ip: format_ip(ip),
      loopback: ArbiterWeb.Loopback.loopback?(ip)
    })
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()

  def agy_write_jail(conn, _params) do
    case Jail.diagnose() do
      nil ->
        json(conn, %{available: true})

      %{cause: cause, message: message, fix: fix} ->
        json(conn, %{available: false, cause: Atom.to_string(cause), message: message, fix: fix})
    end
  end

  def claude_credentials(conn, _params) do
    %{checked: checked, missing: missing} = CredentialCheck.workspace_report()

    json(conn, %{
      checked: checked,
      missing:
        Enum.map(missing, fn m ->
          %{
            workspace_id: m.workspace_id,
            workspace: m.workspace,
            provider: Atom.to_string(m.provider),
            account: m.account,
            reason: Atom.to_string(m.reason),
            summary: m.summary,
            fix: m.fix
          }
        end)
    })
  end

  def provider_accounts(conn, _params) do
    status = Enablement.status()

    json(conn, %{
      configured: to_string(status.configured),
      enabled: status.enabled,
      decision: Atom.to_string(status.decision),
      stranded_workspaces: status.stranded_workspaces,
      server_env_token: status.server_env_token?,
      runbook: Enablement.runbook()
    })
  end
end
