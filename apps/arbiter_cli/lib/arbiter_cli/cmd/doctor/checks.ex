defmodule ArbiterCli.Cmd.Doctor.Checks do
  @moduledoc """
  The individual `arb doctor` health checks. Shared by `ArbiterCli.Cmd.Doctor`
  and `arb start`/`arb server deploy`/`arb server restart`/`arb update` so
  "green" has one definition everywhere.
  """

  alias ArbiterCli.{Client, SchedulerState, Workspace}
  alias ArbiterCli.Cmd.Doctor.Distribution
  alias ArbiterCli.Cmd.Start

  defmodule Result do
    @moduledoc false
    defstruct [:name, :status, :detail, :hint, :fatal, :blocks_readiness]

    @type t :: %__MODULE__{
            name: String.t(),
            status: :ok | :fail,
            detail: nil | String.t(),
            hint: nil | String.t(),
            fatal: boolean(),
            blocks_readiness: boolean()
          }
  end

  @doc """
  Run every health check and return the result structs, in display order.
  """
  @spec run() :: [Result.t()]
  def run do
    [
      phoenix(),
      check_workspaces_exist(),
      check_active_workspace(),
      check_repos(),
      check_versions(),
      check_migrations(),
      check_bind_address(),
      check_anonymous_api(),
      Distribution.check(),
      check_restart_safety(),
      check_security_defaults(),
      check_legacy_safe_defaults_key(),
      check_agy_write_jail(),
      check_agy_jail_escape(),
      check_agy_jail_network(),
      check_egress_jail(),
      check_agy_ssh_transport(),
      check_tmux(),
      check_worker_tmp(),
      check_claude_worker_credentials(),
      check_provider_accounts(),
      check_account_policy_binding(),
      check_merge_routing()
    ]
  end

  @doc """
  Just the "is Phoenix reachable" check on its own — the cheap single-request
  signal `arb start` uses to decide whether the stack is already up.
  """
  @spec phoenix() :: Result.t()
  def phoenix do
    check_phoenix()
  end

  defp check_phoenix do
    case Client.get("/api/workspaces") do
      {:ok, _} ->
        %Result{
          name: "phoenix reachable",
          status: :ok,
          detail: Client.base_url(),
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{kind: :connection_refused} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: reachable_hint(),
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: err.hint,
          fatal: true,
          blocks_readiness: true
        }
    end
  end

  defp check_workspaces_exist do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when list != [] ->
        %Result{
          name: "at least one workspace exists",
          status: :ok,
          detail: "#{length(list)} workspace(s)",
          fatal: true,
          blocks_readiness: true
        }

      {:ok, _} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: "no workspaces found",
          hint: "Run `mix run priv/repo/seeds.exs` or create one via the API.",
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{kind: :connection_refused} = err} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: err.message,
          hint: reachable_hint(),
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: err.message,
          hint: err.hint,
          fatal: true,
          blocks_readiness: true
        }
    end
  end

  @doc """
  Check version alignment between CLI and server.
  """
  @spec check_versions() :: Result.t()
  def check_versions do
    cli_sha = ArbiterCli.Version.git_sha_clean()
    cli_vsn = ArbiterCli.Version.app_version()

    case Client.get("/api/version") do
      {:ok, %{"version" => server_vsn} = body} ->
        server_sha = Map.get(body, "sha", "unknown")
        version_result(cli_vsn, cli_sha, server_vsn, server_sha)

      {:error, %Client.Error{kind: :connection_refused}} ->
        %Result{
          name: "version",
          status: :ok,
          detail: "CLI #{cli_vsn} @ #{cli_sha} (server unreachable)",
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "version",
          status: :ok,
          detail: "CLI #{cli_vsn} @ #{cli_sha} (server error: #{err.message})",
          fatal: true,
          blocks_readiness: true
        }
    end
  end

  @doc false
  def check_versions(cli_vsn, cli_sha, server_vsn, server_sha) do
    version_result(cli_vsn, cli_sha, server_vsn, server_sha)
  end

  # Always report both versions explicitly, and only claim a match when the
  # version numbers themselves are equal. SHAs are informational only — in
  # particular, both CLI and server routinely report sha "unknown" (no git at
  # runtime in a release build), so `cli_sha == server_sha` is NOT evidence of
  # a real match and must never be used as one.
  #
  # `arb server deploy` doesn't refresh the local CLI binary, so a CLI that's
  # a release behind the server is the normal post-deploy state — reported as
  # a warning (`fatal: false`), never as a reason to auto-roll-back a deploy.
  defp version_result(cli_vsn, cli_sha, server_vsn, server_sha) do
    cond do
      cli_vsn == server_vsn ->
        %Result{
          name: "version",
          status: :ok,
          detail: "server #{server_vsn}, CLI #{cli_vsn} (CLI and server match)",
          fatal: false,
          blocks_readiness: false
        }

      major_version(cli_vsn) != major_version(server_vsn) ->
        %Result{
          name: "version",
          status: :fail,
          detail: "server #{server_vsn} @ #{server_sha}, CLI #{cli_vsn} @ #{cli_sha}",
          hint: "Major version mismatch — upgrade both CLI and server to the same major.",
          fatal: false,
          blocks_readiness: false
        }

      true ->
        hint =
          if dev_install?() do
            if cli_behind?(cli_vsn, cli_sha, server_vsn, server_sha) do
              "The `arb` CLI is older than the server — rebuild and reinstall the `arb` CLI (e.g. `arb install-cli`)."
            else
              "The server's compiled version is stale — restart the server via your process manager (e.g. `systemctl --user restart arbiter`)."
            end
          else
            "`arb server deploy` does not refresh the local CLI — reinstall the CLI from " <>
              "the #{server_vsn} release asset to match the server."
          end

        %Result{
          name: "version",
          status: :fail,
          detail: "server #{server_vsn} @ #{server_sha}, CLI #{cli_vsn} @ #{cli_sha}",
          hint: hint,
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp cli_behind?(cli_vsn, cli_sha, server_vsn, server_sha) do
    case {Version.parse(cli_vsn), Version.parse(server_vsn)} do
      {{:ok, cli}, {:ok, server}} ->
        case Version.compare(cli, server) do
          :lt -> true
          :gt -> false
          :eq -> sha_behind?(cli_sha, server_sha)
        end

      _ ->
        sha_behind?(cli_sha, server_sha)
    end
  end

  defp sha_behind?(_cli_sha, "unknown"), do: false
  defp sha_behind?("unknown", _server_sha), do: false

  defp sha_behind?(cli_sha, server_sha) do
    clean_cli = String.trim_trailing(cli_sha, "*")
    clean_server = String.trim_trailing(server_sha, "*")

    if clean_cli == clean_server do
      false
    else
      # Check if cli_sha is an ancestor of server_sha in git
      case Start.run_cmd("git", ["merge-base", "--is-ancestor", clean_cli, clean_server],
             stderr_to_stdout: true
           ) do
        {_, 0} -> true
        _ -> false
      end
    end
  end

  defp major_version(vsn) do
    case Version.parse(vsn) do
      {:ok, %Version{major: major}} -> major
      :error -> nil
    end
  end

  # True if the CLI was built from a source checkout (has git available at build time).
  # A dev/source install's version mismatch hint should point to the stale
  # compile-time value, not to reinstalling from a release asset.
  defp dev_install? do
    ArbiterCli.Version.dev_build?()
  end

  # `phoenix reachable`'s connection-refused hint, mode-aware: a source
  # checkout's stack is booted with `mix phx.server` directly, but a release
  # install has no Mix/Elixir toolchain on the box at all — that advice is
  # simply wrong there. Reuses the same `dev_install?/0` signal the version
  # check already keys its own mode-aware hint off of.
  defp reachable_hint do
    if dev_install?() do
      "Phoenix app isn't running. Start it with `mix phx.server` from the umbrella root."
    else
      "Phoenix app isn't running. Start it with `systemctl --user start arbiter` " <>
        "(or `<data-home>/current/bin/arbiter start` if not managed by systemd)."
    end
  end

  # `fatal: true` — this is still an operator-actionable misconfiguration
  # (ambiguous or unresolvable workspace selector) and `arb doctor` should
  # exit non-zero on it, same as any other broken CLI command depending on
  # `Workspace.resolve/0` (`arb ticket`, `arb ready`, `arb where`, `arb
  # config`). But `blocks_readiness: false` — it says which workspace CLI
  # commands will operate against, not whether the deployed server is
  # healthy, so `green?/0` (which backs `arb server deploy`'s auto-rollback
  # wait) must not treat it as a reason to roll back an otherwise-healthy
  # deploy (see bd-8ix2tw: every deploy auto-rolled-back on an install whose
  # only workspace wasn't named "default").
  defp check_active_workspace do
    case Workspace.resolve() do
      {:ok, ws} ->
        %Result{
          name: "active workspace resolves",
          status: :ok,
          detail: "#{ws["name"]} (#{ws["id"]})",
          fatal: true,
          blocks_readiness: false
        }

      {:error, msg} ->
        %Result{
          name: "active workspace resolves",
          status: :fail,
          detail: msg,
          hint: "Set ARB_WORKSPACE to pick one of the existing workspaces.",
          fatal: true,
          blocks_readiness: false
        }
    end
  end

  # Repo config is the one piece of workspace state every dispatch depends on
  # and nothing else here validates. bd-3pqzsa: v0.1.56 removed the `rig_paths`
  # fallback, so an un-migrated install resolved ZERO repos — every dispatch
  # failed, PRPatrol went silent — while doctor reported 5/5 green for three
  # days, because "config intact" and "config read" are indistinguishable from
  # the config alone. Two signals make that state loud: any workspace still on
  # a retired config key (exact, names the workspace, count-independent — see
  # legacy_workspaces/1), and otherwise an explicit repo count, which is the
  # generic backstop the next config-key rename lands on.
  #
  # `fatal: true` — an install that resolves no repos is operator-actionable
  # and `arb doctor` should exit non-zero. `blocks_readiness: false` — it says
  # nothing about whether the *deployed server* is healthy, so it must never
  # auto-roll-back a deploy (same reasoning as check_active_workspace, bd-8ix2tw).
  defp check_repos do
    workspaces = workspace_entries()

    case legacy_workspaces(workspaces) do
      [] -> check_repo_count(workspaces)
      names -> legacy_key_result(names)
    end
  end

  # The repo count alone is not enough: `GET /api/repos` aggregates across
  # *every* workspace plus the `:arbiter, :repo_paths` app-env fallback, so on
  # a two-workspace install a migrated workspace A supplies repos while an
  # un-migrated workspace B dispatches nothing — a non-zero total, and the same
  # silence all over again. So flag a lingering `rig_paths` on its own,
  # independent of the count, and name the workspace.
  #
  # Only a *map* under `rig_paths` counts, matching
  # `Arbiter.Boot.ConfigMigrator`'s own candidate filter exactly: anything else
  # is junk the migration will never clear, and flagging it would pin doctor
  # red with no remediation that works.
  defp legacy_workspaces(entries) do
    entries
    |> Enum.filter(&is_map(Map.get(&1.config, "rig_paths")))
    |> Enum.map(& &1.name)
  end

  defp legacy_key_result(names) do
    %Result{
      name: "repos resolved",
      status: :fail,
      detail:
        "#{workspace_phrase(names)} still on the retired `rig_paths` key: #{Enum.join(names, ", ")}",
      hint: legacy_key_hint(),
      fatal: true,
      blocks_readiness: false
    }
  end

  defp workspace_phrase([_]), do: "1 workspace"
  defp workspace_phrase(names), do: "#{length(names)} workspaces"

  # Lead with the remediation that works on every install shape. Production
  # installs are Mix-less releases (`arb server deploy` ships a tarball), so
  # `mix arbiter.migrate_rig_paths` is unrunnable there and belongs last.
  defp legacy_key_hint do
    "Its repo map is intact but nothing reads it. Restart the server " <>
      "(`arb server restart`) — the boot config migrator moves it to `repo_paths` " <>
      "automatically. To migrate without a restart: `bin/arbiter eval " <>
      "Arbiter.Release.migrate_config` on a release install, or " <>
      "`mix arbiter.migrate_rig_paths --apply` from a source checkout."
  end

  defp check_repo_count(workspaces) do
    case Client.get("/api/repos") do
      {:ok, %{"data" => [_ | _] = repos}} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "#{length(repos)} repo(s)",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"data" => []}} ->
        no_repos_result(workspaces)

      {:ok, _other} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "unexpected response — skipping",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :connection_refused}} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "server unreachable",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: 404}} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "server does not expose repos",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "repos resolved",
          status: :fail,
          detail: err.message,
          hint: err.hint,
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # Zero repos on a fresh install with no workspace yet is expected, not a
  # fault — the workspace check already owns that failure and we must not
  # double-report it. Once a workspace exists, zero repos means no work can be
  # dispatched, and the hint names the exact remediation. (The `rig_paths` case
  # never reaches here — `check_repos` catches it ahead of the count.)
  defp no_repos_result([]) do
    %Result{
      name: "repos resolved",
      status: :ok,
      detail: "no workspaces — nothing to resolve",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp no_repos_result(_workspaces) do
    %Result{
      name: "repos resolved",
      status: :fail,
      detail: "no repos registered",
      hint: "Register a repo with `arb config set repo_paths.<repo>.path <path>`.",
      fatal: true,
      blocks_readiness: false
    }
  end

  # bd-4420va: a workspace that pinned `agent.security.permissions.safe_defaults`
  # before a new default category shipped (vstim pinning the 4 categories that
  # existed pre-v0.1.78) used to silently resolve fewer categories than a
  # workspace that never pinned, with nothing surfacing the gap. The legacy
  # `safe_defaults` key is now inert (see `Arbiter.Agents.SecurityPolicy`), so
  # this only ever fires when a workspace explicitly names a category in
  # `safe_defaults_exclude` — but that exclusion should still be visible here
  # rather than only discoverable in a live worker's `--settings`.
  defp check_security_defaults do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when is_list(list) ->
        offenders =
          list
          |> Enum.map(fn ws -> {workspace_label(ws), missing_safe_defaults(ws)} end)
          |> Enum.filter(fn {_name, missing} -> missing != [] end)

        security_defaults_result(offenders)

      _ ->
        %Result{
          name: "workspace safe-default categories",
          status: :ok,
          detail: "server unreachable — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp security_defaults_result([]) do
    %Result{
      name: "workspace safe-default categories",
      status: :ok,
      detail: "every workspace resolves every current default category",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp security_defaults_result(offenders) do
    detail =
      Enum.map_join(offenders, "; ", fn {name, missing} ->
        "#{name}: #{Enum.join(missing, ", ")}"
      end)

    %Result{
      name: "workspace safe-default categories",
      status: :fail,
      detail: "missing default categories — #{detail}",
      hint:
        "These exclusions are named in `agent.security.permissions.safe_defaults_exclude`. " <>
          "Remove a category from that list to re-enable it, or leave it if intentional.",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp workspace_label(ws), do: Map.get(ws, "name") || Map.get(ws, "id") || "(unnamed)"

  defp missing_safe_defaults(ws) do
    case Map.get(ws, "security_posture") do
      %{"safe_defaults_exclude" => excl} when is_list(excl) -> excl
      _ -> []
    end
  end

  # bd-4420va: the legacy `permissions.safe_defaults` config key is inert
  # (see `Arbiter.Agents.SecurityPolicy`) — a workspace that once opted out
  # with `safe_defaults: []` now silently resolves every default category
  # again. Flag any workspace whose raw config still carries the key so an
  # operator relying on the old opt-out notices before it matters.
  defp check_legacy_safe_defaults_key do
    offenders =
      workspace_entries()
      |> Enum.filter(fn %{config: config} -> has_legacy_safe_defaults_key?(config) end)
      |> Enum.map(& &1.name)

    legacy_safe_defaults_result(offenders)
  end

  defp has_legacy_safe_defaults_key?(config) do
    config
    |> get_in(["agent", "security", "permissions"])
    |> case do
      %{} = permissions -> Map.has_key?(permissions, "safe_defaults")
      _ -> false
    end
  end

  defp legacy_safe_defaults_result([]) do
    %Result{
      name: "legacy safe_defaults key",
      status: :ok,
      detail: "no workspace config carries the inert legacy key",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp legacy_safe_defaults_result(offenders) do
    %Result{
      name: "legacy safe_defaults key",
      status: :fail,
      detail: "legacy key ignored — use safe_defaults_exclude: #{Enum.join(offenders, ", ")}",
      hint:
        "`agent.security.permissions.safe_defaults` no longer has any effect (it is always " <>
          "the current default set minus safe_defaults_exclude). Remove the key, and if it " <>
          "was used to opt a category out, move that category into " <>
          "`agent.security.permissions.safe_defaults_exclude` instead.",
      fatal: false,
      blocks_readiness: false
    }
  end

  # bd-3s82pf: the agy write jail is default-on in every mode now, keyed on
  # the base `sandbox.enabled` / `filesystem: :worktree` default. Outside
  # `:strict` a host that can't jail just runs agy unconfined rather than
  # refusing (the only fail-closed mode is `:strict`, gated separately by
  # `security_posture.write_confinement`), so this is the one place that gap
  # is visible rather than silent.
  #
  # bd-8xy1mf: a `[fail]` here is only warranted when the gap is actually
  # fatal to some workspace — i.e. that workspace resolves `:strict` (agy is
  # already the configured/eligible provider by the time `write_jail_warning`
  # is non-nil at all, see `Arbiter.Agents.Gemini.write_jail_warning/1`).
  # Outside `:strict` the warning is real but informational: `[ ok ]` with the
  # cause and fix still named in `detail`, so an operator preparing to switch
  # a scope to `:strict` sees it ahead of time without doctor crying wolf on
  # every `:auto`/`:bypass` install that simply doesn't have bwrap yet.
  defp check_agy_write_jail do
    host = host_jail_status()

    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when is_list(list) ->
        offenders =
          list
          |> Enum.flat_map(fn ws ->
            Enum.map(jail_warnings(ws), &{workspace_label(ws), &1})
          end)

        agy_write_jail_result(host, offenders)

      _ ->
        %Result{
          name: "agy write jail",
          status: :ok,
          detail: "server unreachable — skipping (host jail status: #{host_status_text(host)})",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # The host's own answer to "can this host jail an agy spawn at all" —
  # `Arbiter.Worker.Jail.diagnose/0` via `/api/server/agy_write_jail`
  # (bd-8xy1mf AC1). Distinct from `jail_warnings/1`: a workspace/repo warning
  # is only non-nil once some policy actually needs the jail, so on an
  # install where nothing resolves agy yet the workspace scan alone can never
  # tell an operator whether the host can jail at all.
  # bd-5d5mrs: independent of `check_agy_write_jail/0` — a host can jail
  # writes fine while `ssh -G` still can't parse the jail's mirrored ssh
  # config (a changed `/etc/ssh/ssh_config`, no `ssh` on `PATH`), and that
  # would otherwise only surface as a jailed worker's `git push` failing.
  # `Jail.diagnose_ssh/0` via the same `/api/server/agy_write_jail` payload's
  # `ssh` key (added alongside the existing `available`/`cause`/`message`/
  # `fix` shape, so an older CLI reading only those keeps working).
  defp check_agy_ssh_transport do
    case Client.get("/api/server/agy_write_jail") do
      {:ok, %{"ssh" => %{"available" => true}}} ->
        %Result{
          name: "agy ssh transport",
          status: :ok,
          detail: "ssh config parses inside the jail",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"ssh" => %{"available" => false, "message" => message} = ssh}} ->
        %Result{
          name: "agy ssh transport",
          status: :fail,
          detail: "git over ssh inside the jail may fail: #{message}",
          hint: Map.get(ssh, "fix") || "See Arbiter.Worker.Jail.ssh_shadow_config/0 (bd-5d5mrs).",
          fatal: false,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "agy ssh transport",
          status: :ok,
          detail: "server unreachable or predates this check — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # bd-7o08mj: the jail's `--ro-bind / /` exposes the session bus, systemd's
  # private socket, resolved's varlink socket, ssh-agent and keyring, any of
  # which lets a jailed process act outside the jail. `Jail.diagnose_escape/0`
  # (the payload's `escape` key) probes them inside a real jail; any reachable
  # vector is a FAIL. `dbus_proxy` is informational: without xdg-dbus-proxy
  # agy cannot use the keyring inside the jail (it fails closed).
  defp check_agy_jail_escape do
    case Client.get("/api/server/agy_write_jail") do
      {:ok, %{"escape" => %{"available" => true}} = body} ->
        proxy =
          case Map.get(body, "dbus_proxy") do
            path when is_binary(path) -> "xdg-dbus-proxy: #{path}"
            _ -> "xdg-dbus-proxy not installed (keyring unavailable inside the jail)"
          end

        %Result{
          name: "agy jail escape vectors",
          status: :ok,
          detail: "no session bus, systemd, resolver or agent socket reachable; #{proxy}",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"escape" => %{"available" => false, "message" => message} = esc}} ->
        %Result{
          name: "agy jail escape vectors",
          status: :fail,
          detail: message,
          hint: Map.get(esc, "fix") || "See Arbiter.Worker.Jail.mask_paths/0 (bd-7o08mj).",
          fatal: false,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "agy jail escape vectors",
          status: :ok,
          detail: "server unreachable or predates this check — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # bd-cfktou (G6): an agy spawn runs in a network namespace whose only exit
  # is the run's egress proxy and its `socat` bridges. A host with no `socat`
  # or no network namespaces falls back to the filesystem jail on the shared
  # network, so this FAILs (non-blocking) rather than staying quiet about it.
  # `Jail.diagnose_network/0` via the payload's `network` key.
  defp check_agy_jail_network do
    case Client.get("/api/server/agy_write_jail") do
      {:ok, %{"network" => %{"available" => true}}} ->
        %Result{
          name: "agy jail network",
          status: :ok,
          detail: "agy runs in a network namespace; its only route out is the egress proxy",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"network" => %{"available" => false, "message" => message} = net}} ->
        %Result{
          name: "agy jail network",
          status: :fail,
          detail: "agy runs on the shared network: #{message}",
          hint: Map.get(net, "fix") || "See Arbiter.Worker.Jail.network_probe/0 (bd-cfktou).",
          fatal: false,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "agy jail network",
          status: :ok,
          detail: "server unreachable or predates this check — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # bd-5yydxh (G10, design §7.3): `egress: allowlist` / `none` are only as good
  # as the host's ability to run the egress jail. The server runs the
  # self-test: `bwrap --unshare-net` and `socat` present, a proxy listener up,
  # and against a local stand-in (no internet) 1 allow and 1 deny.
  # `Arbiter.Worker.Egress.SelfTest` via `/api/server/egress_jail`. A FAIL is
  # non-fatal: `egress: open`, the default, does not need it.
  defp check_egress_jail do
    case Client.get("/api/server/egress_jail") do
      {:ok, %{"available" => true} = body} ->
        %Result{
          name: "egress jail",
          status: :ok,
          detail:
            "bwrap --unshare-net and socat present; proxy listener up; self-test against a " <>
              "local stand-in saw #{Map.get(body, "allowed", 1)} allow and " <>
              "#{Map.get(body, "denied", 1)} deny",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"available" => false, "message" => message} = body} ->
        %Result{
          name: "egress jail",
          status: :fail,
          detail: "`egress: allowlist` / `none` cannot be enforced on this host: #{message}",
          hint: Map.get(body, "fix") || "See Arbiter.Worker.Egress.SelfTest (bd-5yydxh).",
          fatal: false,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "egress jail",
          status: :ok,
          detail: "server unreachable or predates this check — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp host_jail_status do
    case Client.get("/api/server/agy_write_jail") do
      {:ok, %{"available" => true}} ->
        :ok

      {:ok, %{"available" => false, "message" => message, "fix" => fix}} ->
        {:error, message, fix}

      _ ->
        :unknown
    end
  end

  defp host_status_text(:ok), do: "can jail agy"
  defp host_status_text({:error, message, nil}), do: "cannot jail agy: #{message}"
  defp host_status_text({:error, message, fix}), do: "cannot jail agy: #{message} — #{fix}"
  defp host_status_text(:unknown), do: "unknown — server may predate this check"

  # Every degraded-jail warning for `ws`: the workspace-level one (as before)
  # plus one per `agent.security.repos.<repo>` override that resolves its own
  # policy (bd-8xy1mf finding: a repo can be `:strict` while the workspace
  # default isn't — see `WorkspaceJSON.repo_security_postures/2`).
  defp jail_warnings(ws) do
    posture = Map.get(ws, "security_posture") || %{}

    repo_entries =
      posture
      |> Map.get("repos", %{})
      |> Enum.flat_map(fn {repo, repo_posture} -> warning_entry(repo_posture, repo) end)

    warning_entry(posture, nil) ++ repo_entries
  end

  defp warning_entry(posture, repo) do
    case Map.get(posture, "write_jail_warning") do
      warning when is_binary(warning) ->
        [%{message: warning, strict?: Map.get(posture, "mode") == "strict", repo: repo}]

      _ ->
        []
    end
  end

  defp agy_write_jail_result(:ok, []) do
    %Result{
      name: "agy write jail",
      status: :ok,
      detail: "host can jail agy — agy is :strict-eligible",
      fatal: false,
      blocks_readiness: false
    }
  end

  # `hint` is only ever printed for `:fail` results (see
  # `ArbiterCli.Cmd.Doctor.Formatter`), so the "why this is still [ ok ]"
  # explanation has to live in `detail` here, not `hint`.
  defp agy_write_jail_result({:error, _, _} = host, []) do
    %Result{
      name: "agy write jail",
      status: :ok,
      detail:
        "host #{host_status_text(host)} — no workspace or repo currently resolves :strict " <>
          "for agy, so this is informational only",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp agy_write_jail_result(:unknown, []) do
    %Result{
      name: "agy write jail",
      status: :ok,
      detail: "no workspace has a degraded agy write jail (host jail status unknown)",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp agy_write_jail_result(host, offenders) do
    detail =
      Enum.map_join(offenders, "; ", fn {name, %{message: message, repo: repo}} ->
        label = if repo, do: "#{name} (repo #{repo})", else: name
        "#{label}: #{message}"
      end)

    strict? = Enum.any?(offenders, fn {_name, %{strict?: strict?}} -> strict? end)

    %Result{
      name: "agy write jail",
      status: if(strict?, do: :fail, else: :ok),
      detail: "host #{host_status_text(host)}; " <> detail,
      hint:
        if strict? do
          "A `:strict` workspace/repo can't fall back to running agy unconfined — see the " <>
            "cause and fix named above, or drop it out of `:strict` until the host can jail."
        end,
      fatal: strict?,
      blocks_readiness: false
    }
  end

  # bd-80ecol: every workspace that runs Claude with no setup token (or API
  # key) of its own. Such a workspace used to fall back to a copy of the
  # operator's `.credentials.json` (mode B) — a second holder of a refresh
  # token Claude rotates on every refresh, so either side's refresh locked the
  # other out. Its Claude dispatch is now held instead, which is an
  # operator-actionable failure (non-zero exit) but says nothing about whether
  # the server itself is healthy, so it never blocks deploy readiness.
  # bd-c99hys: the dashboard login relay runs each provider CLI's login in a
  # hidden tmux session. A host without tmux cannot log an account in from the
  # dashboard, but nothing else breaks, so this FAILs without blocking readiness.
  # bd-5ad4ch: the per-run worker TMPDIR root must be disk-backed and small.
  defp check_worker_tmp do
    case Client.get("/api/server/worker_tmp") do
      {:ok, %{"tmpfs" => true} = body} ->
        %Result{
          name: "worker temp dir",
          status: :warn,
          detail:
            "#{Map.get(body, "root")} is on #{Map.get(body, "fstype")} (RAM-backed): worker " <>
              "scratch files consume memory",
          hint: "Set ARBITER_WORKER_TMP_ROOT (or ARBITER_SCRATCH_ROOT) to a disk-backed path.",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"over_threshold" => true} = body} ->
        %Result{
          name: "worker temp dir",
          status: :warn,
          detail:
            "#{Map.get(body, "root")} holds #{Map.get(body, "size_bytes")} bytes " <>
              "(warn threshold #{Map.get(body, "threshold_bytes")})",
          hint: "Orphaned per-run temp dirs are swept at server boot; restart or remove them.",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"root" => root}} ->
        %Result{
          name: "worker temp dir",
          status: :ok,
          detail: "#{root} is disk-backed and within its size threshold",
          fatal: false,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "worker temp dir",
          status: :ok,
          detail: "server unreachable or predates this check — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp check_tmux do
    case Client.get("/api/server/tmux") do
      {:ok, %{"available" => true} = tmux} ->
        %Result{
          name: "tmux",
          status: :ok,
          detail:
            "installed (#{Map.get(tmux, "version") || "unknown version"}) — the dashboard " <>
              "login relay can run provider logins",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"available" => false} = tmux} ->
        %Result{
          name: "tmux",
          status: :fail,
          detail:
            "#{Map.get(tmux, "message") || "tmux is not installed"}: the dashboard cannot log " <>
              "in or re-authenticate a provider account",
          hint: Map.get(tmux, "fix") || "Install tmux.",
          fatal: false,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "tmux",
          status: :ok,
          detail: "server unreachable or predates this check — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp check_claude_worker_credentials do
    case Client.get("/api/server/claude_credentials") do
      {:ok, %{"checked" => checked, "missing" => []}} ->
        %Result{
          name: "claude worker credentials",
          status: :ok,
          detail:
            "#{checked} Claude workspace(s), each with a setup token of its own — none falls " <>
              "back to the operator's .credentials.json",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"missing" => missing}} when is_list(missing) ->
        %Result{
          name: "claude worker credentials",
          status: :fail,
          detail:
            Enum.map_join(missing, "; ", fn m ->
              "#{Map.get(m, "workspace") || Map.get(m, "workspace_id")} " <>
                "(#{Map.get(m, "provider", "claude")}): #{Map.get(m, "summary")} — " <>
                "fix: #{Map.get(m, "fix")}"
            end),
          hint:
            "Claude dispatch for these workspaces is held: Arbiter no longer copies the " <>
              "operator's ~/.claude/.credentials.json into a worker, since Claude rotates its " <>
              "refresh token on every refresh and two holders lock each other out.",
          fatal: true,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "claude worker credentials",
          status: :ok,
          detail: "could not check — server unreachable, or it predates this check",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # bd-73zv62: every repo's effective merge strategy (a `merge.repos.<repo>`
  # override, else the workspace's), and each repo whose checkout cannot carry
  # it — a github/gitlab strategy with no `origin` remote, or an `origin` that
  # is not the effective owner/repo. Its PRs would never open, or open against
  # the wrong repository: operator-actionable (non-zero exit), but says nothing
  # about the server's health, so it never blocks deploy readiness.
  defp check_merge_routing do
    case Client.get("/api/server/merge_routing") do
      {:ok, %{"problems" => [_ | _] = problems}} ->
        %Result{
          name: "merge routing",
          status: :fail,
          detail: Enum.map_join(problems, "; ", &routing_problem/1),
          hint:
            "Set a per-repo override with `arb config set merge.repos.<repo>.…` " <>
              "(see `arb config schema`, merge.repos).",
          fatal: true,
          blocks_readiness: false
        }

      {:ok, %{"repos" => repos}} when is_list(repos) ->
        %Result{
          name: "merge routing",
          status: :ok,
          detail: routing_summary(repos),
          fatal: false,
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "merge routing",
          status: :ok,
          detail: "could not check — server unreachable, or it predates this check",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp routing_summary([]), do: "no workspace repos to route"

  defp routing_summary(repos),
    do: Enum.map_join(repos, ", ", &"#{routing_label(&1)}: #{Map.get(&1, "strategy")}")

  defp routing_label(entry), do: "#{Map.get(entry, "workspace")}/#{Map.get(entry, "repo")}"

  defp routing_problem(%{"problem" => "no_remote"} = entry) do
    "#{routing_label(entry)} merges via #{Map.get(entry, "strategy")} but its checkout has " <>
      "no origin remote — fix: #{Map.get(entry, "fix")}"
  end

  defp routing_problem(%{"problem" => "remote_mismatch"} = entry) do
    "#{routing_label(entry)} merges via #{Map.get(entry, "strategy")} into " <>
      "#{Map.get(entry, "expected")} but its origin is #{Map.get(entry, "remote")} — " <>
      "fix: #{Map.get(entry, "fix")}"
  end

  defp routing_problem(entry),
    do: "#{routing_label(entry)}: #{Map.get(entry, "problem")} — fix: #{Map.get(entry, "fix")}"

  # bd-cvvb02 / P13 (bd-9gqj8e): provider accounts are always on and there is
  # no legacy credential chain. An un-migrated install that still carries
  # legacy provider credentials therefore raises MissingCredentialError on
  # every spawn in those workspaces (and its server-env token is read by
  # nothing), so it is an operator-actionable failure (non-zero exit). Like
  # the Claude credential check it says nothing about whether the server is
  # healthy, so it never blocks deploy readiness: an upgrade's `arb server
  # deploy` must not roll back over it.
  defp check_provider_accounts do
    case Client.get("/api/server/provider_accounts") do
      {:ok, %{"decision" => decision} = status} ->
        provider_accounts_result(decision, status)

      _ ->
        %Result{
          name: "provider accounts",
          status: :ok,
          detail: "could not check — server unreachable, or it predates this check",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp provider_accounts_result("unmigrated_legacy_credentials", status) do
    %Result{
      name: "provider accounts",
      status: :fail,
      detail:
        "legacy provider credentials with no migration record (" <>
          legacy_sources(status) <>
          "); provider accounts are the only credential " <>
          "source, so nothing reads them and those workspaces cannot spawn",
      hint:
        "Migrate them into provider accounts — census, migrate, restart — per " <>
          "#{runbook(status)}.",
      fatal: true,
      blocks_readiness: false
    }
  end

  defp provider_accounts_result(decision, %{"stranded_workspaces" => [_ | _]} = status) do
    %Result{
      name: "provider accounts",
      status: :fail,
      detail:
        "#{decision}, but workspace(s) #{Enum.join(status["stranded_workspaces"], ", ")} " <>
          "still carry a provider credential in worker_env that no account supplies — their " <>
          "next spawn raises MissingCredentialError",
      hint: "Migrate those workspaces (census, then migrate) per #{runbook(status)}.",
      fatal: true,
      blocks_readiness: false
    }
  end

  defp provider_accounts_result(decision, status) do
    detail =
      case {decision, status["server_env_token"]} do
        {"unresolved", _} ->
          "not resolved yet — the server is still booting"

        {_, true} ->
          "on (#{decision}); CLAUDE_CODE_OAUTH_TOKEN in the server environment is " <>
            "ignored — remove it"

        {_, _} ->
          "on (#{decision})"
      end

    %Result{
      name: "provider accounts",
      status: :ok,
      detail: detail,
      fatal: false,
      blocks_readiness: false
    }
  end

  defp legacy_sources(status) do
    workspaces =
      case status["stranded_workspaces"] do
        [_ | _] = names -> ["worker_env of #{Enum.join(names, ", ")}"]
        _ -> []
      end

    server =
      if status["server_env_token"],
        do: ["CLAUDE_CODE_OAUTH_TOKEN in the server environment"],
        else: []

    Enum.join(workspaces ++ server, "; ")
  end

  defp runbook(status), do: status["runbook"] || "docs/provider-accounts-release-runbook.md"

  # bd-c7ll4t: `Arbiter.Quota.Gate` resolves every threshold as
  # `min(account, workspace)` — the account's `quota_config` is a floor a
  # workspace may only tighten, never loosen. `claude:default` left at the
  # migrated `quota_config: {}` (a flat 0.90 weekly threshold) silently
  # capped a workspace explicitly set to `threshold_mode: paced` with no
  # ceiling of its own (bd-5ps98m) — `GET /api/quota?workspace=` was the only
  # place that showed which side actually bound, and only after this ticket.
  # Flag any workspace that configured its own `quota` setting but is not
  # the side `policy_binding` reports as binding.
  defp check_account_policy_binding do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when is_list(list) ->
        offenders =
          list
          |> Enum.filter(&workspace_configures_quota?/1)
          |> Enum.flat_map(&policy_override_offenders/1)

        account_policy_binding_result(offenders)

      _ ->
        %Result{
          name: "account/workspace quota policy",
          status: :ok,
          detail: "server unreachable — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp workspace_configures_quota?(ws) do
    case get_in(config_of(ws), ["quota"]) do
      %{} = quota -> map_size(quota) > 0
      _ -> false
    end
  end

  # A workspace's `quota` map qualifies a *window* only when it expressed an
  # opinion about that window itself — its own flat key, or `threshold_mode:
  # "paced"` (which covers both windows, since a paced side has no flat key
  # to set). Flagging every key just because the workspace configured
  # *something* reported "account overrides its own weekly_threshold" for a
  # workspace that only ever set `throttle_threshold`, or an unrelated key
  # like `weekly_warning_policy` — a false positive against nothing the
  # workspace actually asked for.
  defp workspace_configures_window?(quota, key),
    do: Map.has_key?(quota, key) or Map.get(quota, "threshold_mode") == "paced"

  defp policy_override_offenders(ws) do
    quota = get_in(config_of(ws), ["quota"]) || %{}

    case Client.get("/api/quota", workspace: Map.get(ws, "id")) do
      {:ok, %{"data" => data}} ->
        ["throttle_threshold", "weekly_threshold"]
        |> Enum.filter(
          &(workspace_configures_window?(quota, &1) and
              get_in(data, ["policy_binding", &1]) == "account")
        )
        |> Enum.map(&"#{workspace_label(ws)}: account overrides its own #{&1}")

      _ ->
        []
    end
  end

  defp account_policy_binding_result([]) do
    %Result{
      name: "account/workspace quota policy",
      status: :ok,
      detail: "no workspace's own quota setting is overridden by a stricter account policy",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp account_policy_binding_result(offenders) do
    %Result{
      name: "account/workspace quota policy",
      status: :fail,
      detail: Enum.join(offenders, "; "),
      hint:
        "Arbiter.Quota.Gate resolves each ceiling as min(account, workspace) — the account's " <>
          "quota_config is a floor the workspace may only tighten, never loosen. `arb account " <>
          "set <ref> --threshold-mode ... / --weekly-threshold ...` adjusts the account side.",
      fatal: false,
      blocks_readiness: false
    }
  end

  # `%{name: , config: }` per workspace — the name so a failure can point at
  # the workspace that needs fixing, the config so key-level checks (the
  # retired `rig_paths`, and whatever the next rename is) can run client-side.
  defp workspace_entries do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when is_list(list) ->
        Enum.map(list, fn ws ->
          %{name: Map.get(ws, "name") || Map.get(ws, "id") || "(unnamed)", config: config_of(ws)}
        end)

      _ ->
        []
    end
  end

  defp config_of(ws) do
    case Map.get(ws, "config") do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  defp check_migrations do
    case Client.get("/api/server/migrations") do
      {:ok, %{"status" => "ok", "pending_count" => 0}} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "all migrations applied",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"status" => "warning", "pending_count" => count}}
      when is_integer(count) and count > 0 ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "#{count} pending",
          hint: "The server has unapplied migrations. Wait for the deployment to complete.",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"status" => "unknown"}} ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "could not check",
          hint: "The server could not verify migration status. Check server logs for errors.",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, _other} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "unexpected response — skipping",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :connection_refused}} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "server unreachable",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: 404}} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "server does not expose migration status",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{}} ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "could not check migration status",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # bd-1c4pg3: the dashboard's auth model is "a loopback peer is trusted;
  # there is no login", so a server reachable off-loopback exposes
  # unauthenticated LiveView pages to anyone who can reach the port. This is
  # purely informational — never fatal, never blocks readiness — and any
  # ambiguous response (server predates this endpoint, transient error, etc.)
  # is treated as green rather than risking a spurious [fail] on installs
  # that are already fine.
  defp check_bind_address do
    case Client.get("/api/server/bind_address") do
      {:ok, %{"loopback" => true, "ip" => ip}} ->
        %Result{
          name: "bind address is loopback",
          status: :ok,
          detail: ip,
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"loopback" => false, "ip" => ip}} ->
        %Result{
          name: "bind address is loopback",
          status: :fail,
          detail:
            "bound to #{ip} — the dashboard has no login; " <>
              "anyone who can reach this address gets full access to its " <>
              "unauthenticated pages",
          hint:
            "Off-loopback peers get no terminal. If this is intentional " <>
              "(e.g. a VPN-reachable install), unset ARB_BIND_ADDRESS to fall " <>
              "back to loopback-only and use SSH port-forwarding instead " <>
              "(`ssh -L 4848:127.0.0.1:4848 <host>`), or leave it set only if " <>
              "you understand the exposure.",
          fatal: false,
          blocks_readiness: false
        }

      _other ->
        %Result{
          name: "bind address is loopback",
          status: :ok,
          detail: "could not determine — skipping",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # bd-asawcq: loopback is not an identity — every worker runs on this host as
  # the operator's own user — so `/api` must refuse a caller with no token, on
  # loopback exactly like off it. Probe it with requests that change nothing
  # even on a server that lets them through: a config PATCH of `{}` on a
  # workspace that does not exist (an open server answers 404/422), and a read
  # of every workspace's tickets. Anything but 401/403 means the request got
  # past auth: fatal, so `arb doctor` exits 1. Not readiness-blocking — a
  # deploy rolling back over it would land on a build with the same hole. A
  # server this cannot reach is the reachability check's failure, not this
  # one's.
  @anonymous_probes [
    {:patch, "/api/workspaces/arb-doctor-anonymous-probe/config", [json: %{}]},
    {:get, "/api/issues", [params: [limit: 1]]}
  ]

  @doc false
  @spec check_anonymous_api() :: Result.t()
  def check_anonymous_api do
    accepted =
      for {method, path, opts} <- @anonymous_probes,
          status = accepted_status(Client.anonymous(method, path, opts)),
          do: "#{method |> to_string() |> String.upcase()} #{path} → #{status}"

    result = %Result{
      name: "anonymous /api access refused",
      status: :ok,
      detail: "a request without a bearer token gets 401",
      fatal: true,
      blocks_readiness: false
    }

    case accepted do
      [] ->
        result

      _ ->
        %{
          result
          | status: :fail,
            detail: "served without a token: " <> Enum.join(accepted, ", "),
            hint:
              "Any process on this host — every worker included — can drive this server " <>
                "with a plain curl. Upgrade the server (bd-asawcq); `/api` must answer " <>
                "401 without `Authorization: Bearer <token>`."
        }
    end
  end

  # The status a probe was *served* with, or nil when the server refused it
  # (401/403) or could not be asked at all.
  defp accepted_status({:ok, _body}), do: 200

  defp accepted_status({:error, %Client.Error{kind: :http, status: s}}) when s in [401, 403],
    do: nil

  defp accepted_status({:error, %Client.Error{kind: :http, status: s}}) when s in 200..499, do: s
  defp accepted_status({:error, _}), do: nil

  # bd-9fgg04: "is it safe to restart?" is the question doctor is reached for.
  # Informational like the bind-address check — never fatal, never blocks
  # readiness (a deploy's own wait must not hang on a drain) — but a paused
  # scheduler still draining is a [fail]: a restart now kills live work. A
  # running scheduler is normal operation, so [ ok ], with the caveat spelled
  # out. Only an unreadable state falls back to green, as the other
  # informational checks do.
  defp check_restart_safety do
    case SchedulerState.fetch() do
      {:ok, body} -> restart_safety_result(SchedulerState.state(body), body)
      {:error, _} -> restart_safety(:ok, "could not determine — skipping", nil)
    end
  end

  defp restart_safety_result("draining", body) do
    lines = Enum.map(SchedulerState.entry_lines(body), &("\n          " <> &1))

    restart_safety(
      :fail,
      "scheduler " <> SchedulerState.headline(body) <> Enum.join(lines),
      "Wait for it to drain: `arb scheduler wait`, then restart promptly."
    )
  end

  defp restart_safety_result("running", body) do
    restart_safety(
      :ok,
      "scheduler #{SchedulerState.headline(body)} — to restart: " <>
        "`arb scheduler pause && arb scheduler wait`",
      nil
    )
  end

  defp restart_safety_result(_state, body),
    do: restart_safety(:ok, "scheduler " <> SchedulerState.headline(body), nil)

  defp restart_safety(status, detail, hint) do
    %Result{
      name: "safe to restart",
      status: status,
      detail: detail,
      hint: hint,
      fatal: false,
      blocks_readiness: false
    }
  end
end
