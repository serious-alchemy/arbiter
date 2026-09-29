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
      The response's `ssh` key is a second, independent diagnosis (bd-5d5mrs,
      `Arbiter.Worker.Jail.diagnose_ssh/0`) — whether `ssh -G` can parse the
      jail's mirrored ssh config, since a host can jail writes fine while
      that regresses (a changed `/etc/ssh/ssh_config`, no `ssh` on `PATH`).
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
    * `GET /api/server/merge_routing` — every workspace repo's effective merge
      strategy (a `merge.repos.<repo>` override, else the workspace's), and
      each one whose checkout cannot carry it (bd-73zv62,
      `Arbiter.Mergers.RoutingCheck.report/0`): a forge strategy with no
      `origin` remote, or an `origin` that is not the effective
      `owner/repo`. `arb server doctor` lists them with the fix.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts.Enablement
  alias Arbiter.Agents.Claude.CredentialCheck
  alias Arbiter.Mergers.RoutingCheck
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
    json(
      conn,
      Map.put(jail_diagnosis(Jail.diagnose()), :ssh, jail_diagnosis(Jail.diagnose_ssh()))
    )
  end

  defp jail_diagnosis(nil), do: %{available: true}

  defp jail_diagnosis(%{cause: cause, message: message, fix: fix}),
    do: %{available: false, cause: Atom.to_string(cause), message: message, fix: fix}

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

  def merge_routing(conn, _params) do
    repos = Enum.map(RoutingCheck.report(), &routing_entry/1)
    json(conn, %{repos: repos, problems: Enum.filter(repos, & &1.problem)})
  end

  defp routing_entry(entry) do
    %{entry | problem: entry.problem && Atom.to_string(entry.problem)}
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
