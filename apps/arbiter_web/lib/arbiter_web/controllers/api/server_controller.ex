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
      Its `network` key (bd-cfktou, `Arbiter.Worker.Jail.diagnose_network/0`)
      is a third: whether the jail can run in a network namespace with its
      `socat` bridges, which an agy spawn needs for its only route out.
    * `GET /api/server/egress_jail` — the "egress jail" self-test (bd-5yydxh,
      G10, `Arbiter.Worker.Egress.SelfTest`): `bwrap --unshare-net` and `socat`
      present, a proxy listener up, and against a local stand-in (no internet)
      one allow and one deny. Run on demand rather than cached, since it
      starts a proxy. A failure carries the same `cause`/`message`/`fix` as the
      jail diagnoses above.
    * `GET /api/server/guardrails` — the guardrail posture (bd-anwb0u, G11,
      `Arbiter.Guardrails.Report`): per workspace, the effective tier of each
      attached (provider, model) subject, and the issues (an inert block, an
      unmatched or out-of-scope subject, a tier its adapter cannot enforce on
      this host, a dead cap). `active: false` with no issues when nothing is
      configured.
    * `GET /api/server/claude_credentials` — every workspace that runs Claude
      with no setup token (or API key) of its own (bd-80ecol,
      `Arbiter.Agents.Claude.CredentialCheck.workspace_report/0`): the ones
      that used to fall back to a copy of the operator's `.credentials.json`,
      and whose Claude dispatch is now held. `arb server doctor` lists them.
      A failed read is a 500, so the doctor reports "could not check" rather
      than a false all-clear.
    * `GET /api/server/grok_auth` — grok's login state (bd-dpv4vt,
      `Arbiter.Grok.AuthReport`): `enabled: false` unless a workspace routes to
      or pins grok, else `state` (`logged_in` / `expired` / `refresh_unverified` /
      `refresh_failed` / `reauth_required` / `not_logged_in`), the `path` the
      broker reads and its `expires_at` (bd-8rvkqd), and the fix. An expired
      token the broker has not refreshed yet is refreshed here (`probe: true`),
      through the broker. `arb server doctor` reports it.
    * `GET /api/server/provider_accounts` — how this boot classified the
      install's provider accounts (bd-cvvb02, P13 bd-9gqj8e,
      `Arbiter.Accounts.Enablement.status/0`): the decision, and — re-read
      live — every workspace a spawn would raise `MissingCredentialError` for
      and whether a now-ignored `CLAUDE_CODE_OAUTH_TOKEN` is still in the
      server environment. `arb server doctor` fails on either, and points at
      the runbook.
    * `GET /api/server/merge_routing` — every workspace repo's effective merge
      strategy (a `merge.repos.<repo>` override, else the workspace's), and
      each one whose checkout cannot carry it (bd-73zv62,
      `Arbiter.Mergers.RoutingCheck.report/0`): a forge strategy with no
      `origin` remote, or an `origin` that is not the effective
      `owner/repo`. `arb server doctor` lists them with the fix.
    * `GET /api/server/podman_sandbox` — rootless-podman sandbox readiness
      checks (`arb server doctor`)
    * `GET /api/server/tmux` — whether `tmux` is installed on this host
      (bd-c99hys, `Arbiter.Accounts.LoginRunner.tmux_diagnosis/0`). The dashboard
      login relay runs each provider CLI's login in a hidden tmux session, so
      without it no account can be logged in or re-authenticated.
      `arb server doctor` reports it with the install hint.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts.Enablement
  alias Arbiter.Accounts.LoginRunner
  alias Arbiter.Agents.Claude.CredentialCheck
  alias Arbiter.Guardrails
  alias Arbiter.Mergers.RoutingCheck
  alias Arbiter.Worker.Egress.SelfTest
  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.MemoryScope.Diagnosis, as: MemoryDiagnosis

  action_fallback(ArbiterWeb.Api.FallbackController)

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

  def dashboard_auth(conn, _params), do: json(conn, ArbiterWeb.DashboardAuth.mode())

  def bind_address(conn, _params), do: json(conn, ArbiterWeb.InstallationSettings.bind_address())

  def agy_write_jail(conn, _params) do
    json(
      conn,
      jail_diagnosis(Jail.diagnose())
      |> Map.put(:ssh, jail_diagnosis(Jail.diagnose_ssh()))
      |> Map.put(:escape, jail_diagnosis(Jail.diagnose_escape()))
      |> Map.put(:reads, jail_diagnosis(Jail.diagnose_reads()))
      |> Map.put(:network, jail_diagnosis(Jail.diagnose_network()))
      |> Map.put(:keyring, jail_diagnosis(Jail.diagnose_keyring()))
      |> Map.put(:dbus_proxy, Jail.dbus_proxy())
    )
  end

  # bd-5yydxh (G10): the "egress jail" self-test, run on demand. It starts a
  # proxy against a local stand-in and expects 1 allow and 1 deny, so it is
  # not a cached probe like the others.
  def egress_jail(conn, _params) do
    case SelfTest.run() do
      {:ok, %{allowed: allowed, denied: denied}} ->
        json(conn, %{available: true, allowed: allowed, denied: denied})

      {:error, reason} ->
        json(conn, jail_diagnosis(SelfTest.explain(reason)))
    end
  end

  # bd-anwb0u (G11): the guardrail posture, per workspace: each attached
  # subject's tier, and what is inconsistent or unmeetable on this host
  # (`Arbiter.Guardrails.Report`).
  def guardrails(conn, _params) do
    case Ash.read(Arbiter.Tasks.Workspace) do
      {:ok, workspaces} -> json(conn, Guardrails.Report.build(workspaces))
      {:error, _} = err -> err
    end
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

  # bd-dpv4vt: grok's login state, reported only when a workspace uses grok.
  def grok_auth(conn, _params), do: json(conn, Arbiter.Grok.AuthReport.report(probe: true))

  # bd-5ad4ch: where per-run worker TMPDIRs live, and whether that is RAM.
  def worker_tmp(conn, _params), do: json(conn, Arbiter.Worker.RunTmp.diagnosis())

  # bd-46xndf: is this host ready for the rootless-podman worker sandbox?
  def podman_sandbox(conn, _params) do
    opts = Application.get_env(:arbiter, :podman_readiness_opts, [])
    json(conn, Arbiter.Worker.PodmanReadiness.diagnose(opts))
  end

  # bd-6zuoo6: is the per-worker memory cap in force, and what does the
  # server's own unit do when the kernel OOM-kills one of its processes?
  def worker_memory(conn, _params), do: json(conn, MemoryDiagnosis.run())

  def tmux(conn, _params), do: json(conn, LoginRunner.tmux_diagnosis())

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
      decision: Atom.to_string(status.decision),
      stranded_workspaces: status.stranded_workspaces,
      server_env_token: status.server_env_token?,
      runbook: Enablement.runbook()
    })
  end
end
