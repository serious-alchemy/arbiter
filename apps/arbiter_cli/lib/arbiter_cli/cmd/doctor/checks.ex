defmodule ArbiterCli.Cmd.Doctor.Checks do
  @moduledoc """
  The individual `arb doctor` health checks. Shared by `ArbiterCli.Cmd.Doctor`
  and `arb start`/`arb server deploy`/`arb server restart`/`arb update` so
  "green" has one definition everywhere.
  """

  alias ArbiterCli.{Client, SchedulerState, Workspace}
  alias ArbiterCli.Cmd.Doctor.{Distribution, Scope}
  alias ArbiterCli.Cmd.Start

  defmodule Result do
    @moduledoc """
    One check's verdict.

    `status` is the severity: `:ok`, `:warn` (should be fixed, nothing is
    broken), `:fail` (broken now; the only severity that makes `arb server
    doctor` exit non-zero) or `:na` (the check does not apply to this install;
    `detail` says why). `id` and `group` are stable keys for `--json`; `parent`
    names the composite a sub-check collapses into (`agy_jail`); `meta` carries
    the few facts the report header prints.
    """
    defstruct [
      :id,
      :group,
      :parent,
      :name,
      :status,
      :detail,
      :hint,
      meta: %{},
      blocks_readiness: false
    ]

    @type status :: :ok | :warn | :fail | :na
    @type group :: :core | :auth | :sandboxes | :security

    @type t :: %__MODULE__{
            id: nil | String.t(),
            group: nil | group(),
            parent: nil | String.t(),
            name: String.t(),
            status: status(),
            detail: nil | String.t(),
            hint: nil | String.t(),
            meta: map(),
            blocks_readiness: boolean()
          }
  end

  # `{id, group, parent, applies_when, check}` in display order within a group.
  # `applies_when` is read against the install's `Scope` (see
  # `ArbiterCli.Cmd.Doctor.Scope`); a check that does not apply is reported as
  # `:na` with the scope's reason and its endpoint is never called. A check
  # that returns a list (nodes) gets one id per result, derived from its name.
  defp registry do
    [
      {"phoenix_reachable", :core, nil, :always, plain(&phoenix/0)},
      {"workspaces_exist", :core, nil, :always, plain(&check_workspaces_exist/0)},
      {"active_workspace", :core, nil, :always, plain(&check_active_workspace/0)},
      {"repos_resolved", :core, nil, :always, plain(&check_repos/0)},
      {"version", :core, nil, :always, plain(&check_versions/0)},
      {"last_deploy", :core, nil, :always, plain(&check_last_deploy/0)},
      {"migrations", :core, nil, :always, plain(&check_migrations/0)},
      {"restart_safety", :core, nil, :always, plain(&check_restart_safety/0)},
      {"merge_routing", :core, nil, :always, plain(&check_merge_routing/0)},
      {"nodes", :core, nil, :always, plain(&check_nodes/0)},
      {"claude_worker_credentials", :auth, nil, :always, plain(&check_claude_worker_credentials/0)},
      {"grok_auth", :auth, nil, :always, plain(&check_grok_auth/0)},
      {"provider_accounts", :auth, nil, :always, plain(&check_provider_accounts/0)},
      {"tmux", :auth, nil, :always, plain(&check_tmux/0)},
      {"quota_policy", :auth, nil, :always, plain(&check_account_policy_binding/0)},
      {"agy_write_jail", :sandboxes, "agy_jail", {:provider, "gemini"}, plain(&check_agy_write_jail/0)},
      {"agy_jail_escape", :sandboxes, "agy_jail", {:provider, "gemini"}, plain(&check_agy_jail_escape/0)},
      {"agy_jail_reads", :sandboxes, "agy_jail", {:provider, "gemini"}, plain(&check_agy_jail_reads/0)},
      {"agy_jail_network", :sandboxes, "agy_jail", {:provider, "gemini"},
       plain(&check_agy_jail_network/0)},
      {"agy_jail_keyring", :sandboxes, "agy_jail", {:provider, "gemini"},
       plain(&check_agy_jail_keyring/0)},
      {"agy_ssh_transport", :sandboxes, "agy_jail", {:provider, "gemini"},
       plain(&check_agy_ssh_transport/0)},
      {"egress_jail", :sandboxes, nil, :egress, &check_egress_jail/1},
      {"podman_sandbox", :sandboxes, nil, :podman, &check_podman_sandbox/1},
      {"worker_tmp", :sandboxes, nil, :always, plain(&check_worker_tmp/0)},
      {"worker_memory", :sandboxes, nil, :always, plain(&check_worker_memory/0)},
      {"bind_address", :security, nil, :always, plain(&check_bind_address/0)},
      {"anonymous_api", :security, nil, :always, plain(&check_anonymous_api/0)},
      {"dashboard_auth", :security, nil, :always, plain(&check_dashboard_auth/0)},
      {"erlang_distribution", :security, nil, :always, plain(&Distribution.check/0)},
      {"safe_default_categories", :security, nil, :always, plain(&check_security_defaults/0)},
      {"guardrails", :security, nil, :always, plain(&check_guardrails/0)}
    ]
  end

  defp plain(fun), do: fn _scope -> fun.() end

  @doc "The check ids, in display order (the node list is the single id `nodes`)."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(registry(), &elem(&1, 0))

  @doc """
  Run every health check and return the result structs, tagged with their
  `id`/`group`/`parent`, in group order: core, auth & providers, sandboxes,
  security posture.

  Applicability is read once (`Scope.fetch/0`); a check that does not apply to
  this install comes back as `:na` rather than being dropped, so `--all` and
  `--json` still list it.
  """
  @spec run() :: [Result.t()]
  def run do
    scope = Scope.fetch()

    registry()
    |> Enum.flat_map(fn {id, group, parent, applies_when, check} ->
      case Scope.applies?(scope, applies_when) do
        :yes ->
          check.(scope) |> List.wrap() |> tag(id, group, parent)

        {:no, reason} ->
          [%Result{name: na_name(id), status: :na, detail: reason} |> tag_one(id, group, parent)]
      end
    end)
    |> Enum.sort_by(&group_rank(&1.group))
  end

  @group_order [:core, :auth, :sandboxes, :security]
  defp group_rank(group), do: Enum.find_index(@group_order, &(&1 == group))

  defp tag([single], id, group, parent), do: [tag_one(single, id, group, parent)]

  defp tag(results, id, group, parent),
    do: Enum.map(results, &tag_one(&1, id <> "." <> slug(&1.name), group, parent))

  defp tag_one(%Result{} = r, id, group, parent),
    do: %{r | id: id, group: group, parent: parent}

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

  # The display name of a check that never ran.
  @na_names %{
    "agy_write_jail" => "agy write jail",
    "agy_jail_escape" => "agy jail escape vectors",
    "agy_jail_reads" => "agy jail hidden reads",
    "agy_jail_network" => "agy jail network",
    "agy_jail_keyring" => "agy jail keyring proxy",
    "agy_ssh_transport" => "agy ssh transport",
    "egress_jail" => "egress jail",
    "podman_sandbox" => "podman sandbox readiness"
  }
  defp na_name(id), do: Map.fetch!(@na_names, id)

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
          blocks_readiness: true
        }

      {:error, %Client.Error{kind: :connection_refused} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: reachable_hint(),
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: err.hint,
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
          meta: %{workspaces: Enum.map(list, &workspace_label/1)},
          blocks_readiness: true
        }

      {:ok, _} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: "no workspaces found",
          hint: "Run `mix run priv/repo/seeds.exs` or create one via the API.",
          blocks_readiness: true
        }

      {:error, %Client.Error{kind: :connection_refused} = err} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: err.message,
          hint: reachable_hint(),
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: err.message,
          hint: err.hint,
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

      other ->
        %Result{} = result = unknown_result("version", other)
        %{result | detail: result.detail <> " (CLI #{cli_vsn} @ #{cli_sha})", blocks_readiness: true}
    end
  end

  @doc """
  The last `arb server deploy`, from its own status file (tag, time, outcome,
  database backup path). A failed or rolled-back deploy is a `[warn]` with a
  hint: the server that is running is whatever it rolled back to, so nothing is
  broken now. A host with no recorded deploy (a source checkout) is n/a.
  """
  @spec check_last_deploy() :: Result.t()
  def check_last_deploy do
    alias ArbiterCli.Cmd.ReleaseDeploy.Status

    case Status.read() do
      nil ->
        %Result{
          name: "last deploy",
          status: :na,
          detail: "no `arb server deploy` recorded on this host",
          blocks_readiness: false
        }

      %{"state" => state} = last ->
        good? = state == "succeeded" or (state == "running" and not Status.interrupted?(last))

        %Result{
          name: "last deploy",
          status: if(good?, do: :ok, else: :warn),
          detail: Status.describe(last),
          hint:
            if(good?,
              do: nil,
              else: "See #{Status.path()}; `arb server deploy` again once the cause is fixed."
            ),
          blocks_readiness: false
        }

      _ ->
        %Result{
          name: "last deploy",
          status: :warn,
          detail: "could not check: the deploy status file is unreadable",
          blocks_readiness: false
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
  # `arb server deploy` installs the matching CLI after a green deploy, but a
  # CLI that's a release behind the server is still possible (`--no-self-update`,
  # a failed self-update, a deploy from another machine) — reported as a warning
  # (`fatal: false`), never as a reason to auto-roll-back a deploy.
  defp version_result(cli_vsn, cli_sha, server_vsn, server_sha) do
    cond do
      cli_vsn == server_vsn ->
        %Result{
          name: "version",
          status: :ok,
          detail: "server #{server_vsn}, CLI #{cli_vsn} (CLI and server match)",
          meta: %{server_version: server_vsn},
          blocks_readiness: false
        }

      major_version(cli_vsn) != major_version(server_vsn) ->
        %Result{
          name: "version",
          status: :fail,
          detail: "server #{server_vsn} @ #{server_sha}, CLI #{cli_vsn} @ #{cli_sha}",
          hint: "Major version mismatch — upgrade both CLI and server to the same major.",
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
            "Run `arb self-update --version v#{server_vsn}` to install the CLI matching the server."
          end

        %Result{
          name: "version",
          status: :fail,
          detail: "server #{server_vsn} @ #{server_sha}, CLI #{cli_vsn} @ #{cli_sha}",
          hint: hint,
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
          blocks_readiness: false
        }

      {:error, msg} ->
        %Result{
          name: "active workspace resolves",
          status: :fail,
          detail: msg,
          hint: "Set ARB_WORKSPACE to pick one of the existing workspaces.",
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
          blocks_readiness: false
        }

      {:ok, %{"data" => []}} ->
        no_repos_result(workspaces)

      other ->
        unknown_result("repos resolved", other)
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
      status: :na,
      detail: "no workspaces — nothing to resolve",
      blocks_readiness: false
    }
  end

  defp no_repos_result(_workspaces) do
    %Result{
      name: "repos resolved",
      status: :fail,
      detail: "no repos registered",
      hint: "Register a repo with `arb config set repo_paths.<repo>.path <path>`.",
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

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("workspace safe-default categories", err)

      other ->
        unknown_result("workspace safe-default categories", other)
    end
  end

  defp security_defaults_result([]) do
    %Result{
      name: "workspace safe-default categories",
      status: :ok,
      detail: "every workspace resolves every current default category",
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
      status: :warn,
      detail: "missing default categories — #{detail}",
      hint:
        "These exclusions are named in `agent.security.permissions.safe_defaults_exclude`. " <>
          "Remove a category from that list to re-enable it, or leave it if intentional.",
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

  # The `legacy safe_defaults key` check (bd-4420va) is gone: the migration off
  # `agent.security.permissions.safe_defaults` finished and the key is inert, so a
  # standing advisory for it is the noise bd-7pnat1 removes.

  # bd-3s82pf: the agy write jail is default-on in every mode now, keyed on
  # the base `sandbox.enabled` / `filesystem: :worktree` default. Outside
  # `:strict` a host that can't jail just runs agy unconfined rather than
  # refusing (the only fail-closed mode is `:strict`, gated separately by
  # `security_posture.write_confinement`), so this is the one place that gap
  # is visible rather than silent.
  #
  # bd-8xy1mf: a `[fail]` here is only warranted when the gap is actually
  # fatal to some workspace — i.e. that workspace resolves `:strict`. Other
  # adapters (Codex, bd-99emmd) also report a non-nil `write_jail_warning`, so
  # `jail_warnings/1` keeps only postures whose `"provider"` is agy (`gemini`);
  # a Codex `:bypass`/`:strict` warning is about codex, not the bwrap jail, and
  # a `:strict` Codex workspace is not fatal (the pool substitutes a
  # strict-capable provider, see `Arbiter.Agents.strict_eligible_provider/4`).
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

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("agy write jail", err)

      other ->
        unknown_result("agy write jail", other)
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
          blocks_readiness: false
        }

      {:ok, %{"ssh" => %{"available" => false, "message" => message} = ssh}} ->
        %Result{
          name: "agy ssh transport",
          status: :warn,
          detail: "git over ssh inside the jail may fail: #{message}",
          hint: Map.get(ssh, "fix") || "See Arbiter.Worker.Jail.ssh_shadow_config/0 (bd-5d5mrs).",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("agy ssh transport", err)

      other ->
        unknown_result("agy ssh transport", other)
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
          blocks_readiness: false
        }

      {:ok, %{"escape" => %{"available" => false, "message" => message} = esc}} ->
        %Result{
          name: "agy jail escape vectors",
          status: :warn,
          detail: message,
          hint: Map.get(esc, "fix") || "See Arbiter.Worker.Jail.mask_paths/0 (bd-7o08mj).",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("agy jail escape vectors", err)

      other ->
        unknown_result("agy jail escape vectors", other)
    end
  end

  # bd-3q2djr (G3): `--ro-bind / /` lets a jailed worker read every credential
  # the operator can. `Jail.diagnose_reads/0` (the payload's `reads` key) runs
  # a real jail with the live hide set and checks that the install DB,
  # `~/.arbiter`, the credential dirs, the durable log root, another worker's
  # worktree and another workspace's repo cannot be read from inside. A
  # reachable path is a FAIL (non-blocking, like the escape check).
  defp check_agy_jail_reads do
    case Client.get("/api/server/agy_write_jail") do
      {:ok, %{"reads" => %{"available" => true}}} ->
        %Result{
          name: "agy jail hidden reads",
          status: :ok,
          detail:
            "the install DB, credential dirs, log root and other workspaces' worktrees " <>
              "and repos cannot be read from inside the jail",
          blocks_readiness: false
        }

      {:ok, %{"reads" => %{"available" => false, "message" => message} = reads}} ->
        %Result{
          name: "agy jail hidden reads",
          status: :warn,
          detail: message,
          hint: Map.get(reads, "fix") || "See Arbiter.Worker.Jail.Hide.paths/1 (bd-3q2djr).",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("agy jail hidden reads", err)

      other ->
        unknown_result("agy jail hidden reads", other)
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
          blocks_readiness: false
        }

      {:ok, %{"network" => %{"available" => false, "message" => message} = net}} ->
        %Result{
          name: "agy jail network",
          status: :warn,
          detail: "agy runs on the shared network: #{message}",
          hint: Map.get(net, "fix") || "See Arbiter.Worker.Jail.network_probe/0 (bd-cfktou).",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("agy jail network", err)

      other ->
        unknown_result("agy jail network", other)
    end
  end

  # bd-c9fqsk: the filtered keyring proxy is probed with a per-run TMPDIR built
  # the way real spawns build it (`Jail.keyring_probe/0`), so a socket path
  # that outgrows sun_path's 107 bytes is caught here, not on the first run.
  defp check_agy_jail_keyring do
    case Client.get("/api/server/agy_write_jail") do
      {:ok, %{"keyring" => %{"available" => true}}} ->
        %Result{
          name: "agy jail keyring proxy",
          status: :ok,
          detail: "the filtered keyring bus comes up with a per-run TMPDIR",
          blocks_readiness: false
        }

      {:ok, %{"keyring" => %{"available" => false, "message" => message} = kr}} ->
        %Result{
          name: "agy jail keyring proxy",
          status: :warn,
          detail: message,
          hint: Map.get(kr, "fix") || "See Arbiter.Worker.Jail.keyring_probe/0 (bd-c9fqsk).",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("agy jail keyring proxy", err)

      other ->
        unknown_result("agy jail keyring proxy", other)
    end
  end

  # bd-5yydxh (G10, design §7.3): `egress: allowlist` / `none` are only as good
  # as the host's ability to run the egress jail. The server runs the
  # self-test: `bwrap --unshare-net` and `socat` present, a proxy listener up,
  # and against a local stand-in (no internet) 1 allow and 1 deny.
  # `Arbiter.Worker.Egress.SelfTest` via `/api/server/egress_jail`. A FAIL is
  # a FAIL when some workspace enforces an allowlist (n/a otherwise, see `Scope`).
  defp check_egress_jail(scope) do
    # With the scope known this only runs when a workspace enforces an
    # allowlist, so a host that cannot is broken now; with it unknown, it may
    # not be needed.
    unavailable = if scope.known?, do: :fail, else: :warn

    case Client.get("/api/server/egress_jail") do
      {:ok, %{"available" => true} = body} ->
        %Result{
          name: "egress jail",
          status: :ok,
          detail:
            "bwrap --unshare-net and socat present; proxy listener up; self-test against a " <>
              "local stand-in saw #{Map.get(body, "allowed", 1)} allow and " <>
              "#{Map.get(body, "denied", 1)} deny",
          blocks_readiness: false
        }

      {:ok, %{"available" => false, "message" => message} = body} ->
        %Result{
          name: "egress jail",
          status: unavailable,
          detail: "`egress: allowlist` / `none` cannot be enforced on this host: #{message}",
          hint: Map.get(body, "fix") || "See Arbiter.Worker.Egress.SelfTest (bd-5yydxh).",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("egress jail", err)

      other ->
        unknown_result("egress jail", other)
    end
  end

  # bd-anwb0u (G11, design §7.3): the effective guardrail tier of every
  # attached (provider, model) subject, per workspace, and anything
  # inconsistent: an inert `guardrails` block, an unmatched or out-of-scope
  # subject, a tier its adapter cannot enforce here. Computed server-side
  # (`Arbiter.Guardrails.Report`). A FAIL is non-fatal, and with nothing
  # configured the check passes: guardrails are off, not broken.
  defp check_guardrails do
    case Client.get("/api/server/guardrails") do
      {:ok, %{"active" => false, "issues" => []}} ->
        %Result{
          name: "guardrail profiles",
          status: :ok,
          detail: "no subject rules configured, so guardrails are off and nothing is tiered",
          blocks_readiness: false
        }

      {:ok, %{"issues" => [], "workspaces" => workspaces}} ->
        %Result{
          name: "guardrail profiles",
          status: :ok,
          detail: guardrail_tiers_detail(workspaces),
          blocks_readiness: false
        }

      {:ok, %{"issues" => issues, "workspaces" => workspaces}} when is_list(issues) ->
        %Result{
          name: "guardrail profiles",
          status: :warn,
          detail:
            Enum.map_join(issues, "; ", fn i ->
              "#{Map.get(i, "workspace")}: #{Map.get(i, "message")}"
            end) <> " — " <> guardrail_tiers_detail(workspaces),
          hint:
            "Fix the subject rules (guardrail_subjects) or the workspace `guardrails` block; " <>
              "see docs/design/guardrail-profiles.md §7.",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("guardrail profiles", err)

      other ->
        unknown_result("guardrail profiles", other)
    end
  end

  # "default: claude=privileged, antigravity/gemini-3.8-flash-low=quarantine; emricare: …"
  defp guardrail_tiers_detail(workspaces) do
    Enum.map_join(workspaces, "; ", fn ws ->
      subjects =
        ws
        |> Map.get("subjects", [])
        |> Enum.map_join(", ", fn s ->
          label =
            case Map.get(s, "model") do
              nil -> Map.get(s, "provider")
              model -> "#{Map.get(s, "provider")}/#{model}"
            end

          "#{label}=#{Map.get(s, "tier") || "off"}"
        end)

      "#{Map.get(ws, "workspace")}: #{subjects}"
    end)
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

    if agy_posture?(posture) do
      repo_entries =
        posture
        |> Map.get("repos", %{})
        |> Enum.flat_map(fn {repo, repo_posture} -> warning_entry(repo_posture, repo) end)

      warning_entry(posture, nil) ++ repo_entries
    else
      []
    end
  end

  # A server that predates the `"provider"` key only ever reported agy's
  # warning, so a missing key still counts as agy.
  defp agy_posture?(posture), do: Map.get(posture, "provider") in [nil, "gemini"]

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
      blocks_readiness: false
    }
  end

  # agy is in use and the host cannot jail it: outside `:strict` it runs
  # unconfined rather than refusing, so nothing is broken, but it should be
  # fixed before a scope is switched to `:strict`.
  defp agy_write_jail_result({:error, _, fix} = host, []) do
    %Result{
      name: "agy write jail",
      status: :warn,
      detail:
        "host #{host_status_text(host)} — no workspace or repo currently resolves :strict " <>
          "for agy, so agy runs unconfined rather than refusing",
      hint: fix,
      blocks_readiness: false
    }
  end

  defp agy_write_jail_result(:unknown, []) do
    %Result{
      name: "agy write jail",
      status: :warn,
      detail: "could not check: the server did not report the host's jail status",
      hint: "Check the server log for the failing /api/server/agy_write_jail request.",
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
      status: if(strict?, do: :fail, else: :warn),
      detail: "host #{host_status_text(host)}; " <> detail,
      hint:
        if strict? do
          "A `:strict` workspace/repo can't fall back to running agy unconfined — see the " <>
            "cause and fix named above, or drop it out of `:strict` until the host can jail."
        end,
      blocks_readiness: false
    }
  end

  # A 5xx (or other non-404 HTTP error) from a server-backed check: the check
  # did not run, so it is a `[warn]` naming the reason (see `unknown_result/2`).
  defp server_error_result(name, %Client.Error{} = err),
    do: unknown_result(name, {:error, err})

  defp error_detail(%Client.Error{message: message, body: body}) do
    case body do
      %{"detail" => d} when is_binary(d) -> "#{message} (#{d})"
      %{"error" => e} when is_binary(e) -> "#{message} (#{e})"
      _ -> to_string(message)
    end
  end

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
          blocks_readiness: false
        }

      {:ok, %{"root" => root}} ->
        %Result{
          name: "worker temp dir",
          status: :ok,
          detail: "#{root} is disk-backed and within its size threshold",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status != 404 ->
        server_error_result("worker temp dir", err)

      other ->
        unknown_result("worker temp dir", other)
    end
  end

  # bd-6zuoo6: workers live in the server's cgroup unless the per-worker memory
  # cap puts each in its own scope, and under the default `OOMPolicy=stop` the
  # kernel OOM-killing any process there stops the whole service (incident
  # 2026-10-03: a 17.5 GB `mix test` BEAM took every run down with it).
  defp check_worker_memory do
    case Client.get("/api/server/worker_memory") do
      {:ok, %{"service_unit" => unit} = body} when not is_nil(unit) ->
        worker_memory_result(body)

      {:ok, %{"capped" => capped} = body} when is_boolean(capped) ->
        worker_memory_ok(
          "not running as a systemd service (no OOMPolicy to set); " <> cap_summary(body)
        )

      {:error, %Client.Error{kind: :http, status: status} = err} when status != 404 ->
        server_error_result("worker memory cap", err)

      other ->
        unknown_result("worker memory cap", other)
    end
  end

  # `systemctl show` failed on the server (no binary, bus error): the policy is
  # unknown, which is not the same claim as `OOMPolicy=stop`.
  defp worker_memory_result(%{"oom_policy" => nil, "service_unit" => unit} = body) do
    worker_memory_warn(
      "could not read OOMPolicy for #{unit} (systemctl show failed on the server); " <>
        "workers are #{cap_summary(body)}",
      memory_hint(body)
    )
  end

  defp worker_memory_result(%{"oom_policy" => policy, "capped" => capped} = body) do
    stop? = policy == "stop"
    unit = Map.get(body, "service_unit")

    cond do
      stop? and not capped ->
        worker_memory_warn(
          "#{unit} has OOMPolicy=#{policy} and no per-worker memory cap " <>
            "(#{cap_summary(body)}): one runaway worker process gets the whole server stopped",
          memory_hint(body)
        )

      stop? ->
        worker_memory_warn(
          "#{unit} has OOMPolicy=#{policy}; workers are #{cap_summary(body)}, but " <>
            "anything else the kernel OOM-kills inside the unit still stops the server",
          memory_hint(body)
        )

      not capped ->
        worker_memory_warn(
          "#{unit} has OOMPolicy=#{policy} but there is no per-worker memory cap " <>
            "(#{cap_summary(body)}): a runaway worker can still exhaust host memory",
          memory_hint(body)
        )

      true ->
        worker_memory_ok("#{unit}: OOMPolicy=#{policy}; workers are #{cap_summary(body)}")
    end
  end

  defp cap_summary(%{"capped" => true, "cap" => cap}), do: "capped at #{cap} each"

  defp cap_summary(%{"unavailable_reason" => reason}) when is_binary(reason),
    do: "uncapped: #{reason}"

  defp cap_summary(_), do: "uncapped"

  defp memory_hint(body) do
    policy_hint =
      "Add a drop-in: `systemctl --user edit arbiter.service` with " <>
        "`[Service]` / `OOMPolicy=continue`, then `systemctl --user daemon-reload` " <>
        "(or re-run `arb install service`, which now writes it). See docs/worker-memory-cap.md."

    cap_hint =
      if Map.get(body, "capped"),
        do: "",
        else:
          " Cap each worker with ARBITER_WORKER_MEMORY_MAX (e.g. 12G or 40%) — it needs " <>
            "systemd, cgroup v2 and the memory controller delegated to user units."

    policy_hint <> cap_hint
  end

  defp worker_memory_warn(detail, hint) do
    %Result{
      name: "worker memory cap",
      status: :warn,
      detail: detail,
      hint: hint,
      blocks_readiness: false
    }
  end

  defp worker_memory_ok(detail) do
    %Result{
      name: "worker memory cap",
      status: :ok,
      detail: detail,
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
  defp check_tmux do
    case Client.get("/api/server/tmux") do
      {:ok, %{"available" => true} = tmux} ->
        %Result{
          name: "tmux",
          status: :ok,
          detail:
            "installed (#{Map.get(tmux, "version") || "unknown version"}) — the dashboard " <>
              "login relay can run provider logins",
          blocks_readiness: false
        }

      {:ok, %{"available" => false} = tmux} ->
        %Result{
          name: "tmux",
          status: :warn,
          detail:
            "#{Map.get(tmux, "message") || "tmux is not installed"}: the dashboard cannot log " <>
              "in or re-authenticate a provider account",
          hint: Map.get(tmux, "fix") || "Install tmux.",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("tmux", err)

      other ->
        unknown_result("tmux", other)
    end
  end

  # bd-46xndf: is this host ready for the rootless-podman worker sandbox
  # (docs/design/podman-worker-containers.md)? The backend is optional, so a
  # failure is operator-actionable but never readiness-blocking; it is only probed
  # (and only a fail) when a workspace uses the podman backend.
  defp check_podman_sandbox(scope) do
    # With the scope known this only runs when a workspace uses podman, so an
    # unusable host is broken now. With the scope unknown it may not be used.
    unready = if scope.known?, do: :fail, else: :warn

    # The server runs its probes in series (up to 60 s each for the two
    # container runs), so the default 10 s receive timeout is far too short.
    case Client.get("/api/server/podman_sandbox", [], receive_timeout: 150_000) do
      {:ok, %{"installed" => false}} ->
        %Result{
          name: "podman sandbox readiness",
          status: unready,
          detail: "podman is not installed, but a workspace's sandbox backend is podman",
          hint:
            "Install podman (e.g. `sudo dnf install podman`), or move the workspace off " <>
              "`sandbox.backend: podman`.",
          blocks_readiness: false
        }

      {:ok, %{"checks" => checks} = body} when is_list(checks) ->
        failed = Enum.filter(checks, &(Map.get(&1, "status") == "fail"))
        ready? = Map.get(body, "ready", failed == [])

        %Result{
          name: "podman sandbox readiness",
          status: if(ready?, do: :ok, else: unready),
          detail: podman_detail(checks, failed, ready?),
          hint:
            failed
            |> Enum.map(&Map.get(&1, "hint"))
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" "),
          blocks_readiness: false
        }

      {:error, %{kind: kind} = err} when kind in [:timeout, :transport] ->
        %Result{
          name: "podman sandbox readiness",
          status: :warn,
          detail:
            "could not check: the readiness probe did not complete: " <>
              "#{Map.get(err, :message) || kind}",
          hint:
            "The host is too slow or a `podman run` is hung; run `podman run --rm --userns=keep-id <image> true` by hand as the Arbiter user.",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("podman sandbox readiness", err)

      other ->
        unknown_result("podman sandbox readiness", other)
    end
  end

  defp podman_detail(checks, _failed, true) do
    warns = Enum.filter(checks, &(Map.get(&1, "status") == "warn"))
    base = "#{length(checks)} checks passed"

    case warns do
      [] -> base
      _ -> base <> "; warnings: " <> Enum.map_join(warns, "; ", &podman_line/1)
    end
  end

  defp podman_detail(_checks, failed, false),
    do: "not ready: " <> Enum.map_join(failed, "; ", &podman_line/1)

  defp podman_line(c), do: "#{Map.get(c, "name")}: #{Map.get(c, "detail")}"

  defp check_claude_worker_credentials do
    case Client.get("/api/server/claude_credentials") do
      {:ok, %{"checked" => 0, "missing" => []}} ->
        %Result{
          name: "claude worker credentials",
          status: :na,
          detail: "no workspace runs Claude",
          blocks_readiness: false
        }

      {:ok, %{"checked" => checked, "missing" => []}} ->
        %Result{
          name: "claude worker credentials",
          status: :ok,
          detail:
            "#{checked} Claude workspace(s), each with a setup token of its own — none falls " <>
              "back to the operator's .credentials.json",
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
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("claude worker credentials", err)

      other ->
        unknown_result("claude worker credentials", other)
    end
  end

  # bd-dpv4vt: grok is off unless a workspace routes to or pins it; then report
  # its login. A missing or refused login holds grok dispatch only, so it is
  # operator-actionable (non-zero exit) but never blocks deploy readiness.
  # bd-8rvkqd: the report names the file the broker reads and its expiry, and an
  # expired token is only ok while a refresh is known to work.
  defp check_grok_auth do
    case Client.get("/api/server/grok_auth") do
      {:ok, %{"enabled" => true, "state" => state} = body} when state in ~w(logged_in expired) ->
        %Result{
          name: "grok auth",
          status: :ok,
          detail:
            "#{state |> String.replace("_", " ")} (#{Enum.join(Map.get(body, "workspaces", []), ", ")})" <>
              grok_credential_detail(body) <>
              if(state == "expired",
                do:
                  " — the broker's last refresh worked, so it refreshes this on the next dispatch",
                else: ""
              ),
          blocks_readiness: false
        }

      {:ok, %{"enabled" => true, "state" => state} = body} ->
        %Result{
          name: "grok auth",
          status: :fail,
          detail:
            "#{String.replace(state, "_", " ")} (#{Enum.join(Map.get(body, "workspaces", []), ", ")})" <>
              grok_credential_detail(body),
          hint: Map.get(body, "fix"),
          blocks_readiness: false
        }

      {:ok, %{"enabled" => false}} ->
        %Result{
          name: "grok auth",
          status: :na,
          detail: "grok is not enabled for any workspace",
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("grok auth", err)

      other ->
        unknown_result("grok auth", other)
    end
  end

  defp grok_credential_detail(body) do
    case {Map.get(body, "path"), Map.get(body, "expires_at")} do
      {path, expires} when is_binary(path) and is_binary(expires) ->
        " — #{path}, access token expires #{expires}"

      {path, _} when is_binary(path) ->
        " — #{path}"

      _ ->
        ""
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
          blocks_readiness: false
        }

      {:ok, %{"repos" => repos}} when is_list(repos) ->
        %Result{
          name: "merge routing",
          status: :ok,
          detail: routing_summary(repos),
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("merge routing", err)

      other ->
        unknown_result("merge routing", other)
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

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("provider accounts", err)

      other ->
        unknown_result("provider accounts", other)
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
      blocks_readiness: false
    }
  end

  defp provider_accounts_result(decision, status) do
    {severity, detail, hint} =
      case {decision, status["server_env_token"]} do
        {"unresolved", _} ->
          {:warn, "could not check: provider accounts are not resolved yet — the server is still booting",
           "Re-run `arb server doctor` once the server has finished booting."}

        {_, true} ->
          {:warn,
           "on (#{decision}); CLAUDE_CODE_OAUTH_TOKEN in the server environment is " <>
             "ignored — remove it",
           "Unset CLAUDE_CODE_OAUTH_TOKEN in the server's environment (e.g. its systemd unit) " <>
             "and restart; provider accounts are the only credential source."}

        {_, _} ->
          {:ok, "on (#{decision})", nil}
      end

    %Result{
      name: "provider accounts",
      status: severity,
      detail: detail,
      hint: hint,
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

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("account/workspace quota policy", err)

      other ->
        unknown_result("account/workspace quota policy", other)
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
      blocks_readiness: false
    }
  end

  defp account_policy_binding_result(offenders) do
    %Result{
      name: "account/workspace quota policy",
      status: :warn,
      detail: Enum.join(offenders, "; "),
      hint:
        "Arbiter.Quota.Gate resolves each ceiling as min(account, workspace) — the account's " <>
          "quota_config is a floor the workspace may only tighten, never loosen. `arb account " <>
          "set <ref> --threshold-mode ... / --weekly-threshold ...` adjusts the account side.",
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
          blocks_readiness: false
        }

      {:ok, %{"status" => "warning", "pending_count" => count}}
      when is_integer(count) and count > 0 ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "#{count} pending",
          hint: "The server has unapplied migrations. Wait for the deployment to complete.",
          blocks_readiness: false
        }

      {:ok, %{"status" => "unknown"} = body} ->
        %Result{
          name: "migrations up to date",
          status: :warn,
          detail: "could not check: the server could not verify its migration status" <>
            case Map.get(body, "error") do
              reason when is_binary(reason) -> " (#{reason})"
              _ -> ""
            end,
          hint: "The server could not verify migration status. Check server logs for errors.",
          blocks_readiness: false
        }

      other ->
        unknown_result("migrations up to date", other)
    end
  end

  # ---- nodes (RW7, docs/design/remote-workers.md §4.3, §14) ------------------
  #
  # Fed by the operator-only `GET /api/nodes`. Every problem is a `[warn]`
  # (never a fail, never blocks deploy readiness): a sleeping laptop or a
  # missing tailnet is the operator's to act on, not a reason to roll back a
  # deploy. A server that predates the endpoint, or a token without operator
  # proof (403), is one `[warn] could not check` — never an all-clear. With no
  # node enrolled the section is n/a.

  @doc """
  The nodes section: `nodes.public_url reachable` (an anonymous `GET
  <public_url>/nodes/ping`), whether the endpoint looks private (§4.3), one line
  per node that is not revoked, the local worker cap and the cap total against
  `conductor.max_concurrent`.
  """
  @spec check_nodes() :: [Result.t()]
  def check_nodes do
    case Client.get("/api/nodes") do
      {:ok, %{"nodes" => nodes} = resp} when is_list(nodes) ->
        nodes_results(resp, Enum.reject(nodes, &(&1["state"] == "revoked")))

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        [server_error_result("nodes", err)]

      other ->
        [unknown_result("nodes", other)]
    end
  end

  defp nodes_results(resp, nodes) do
    url = resp["public_url"]

    if nodes == [] and is_nil(url) and "local_cap_zero" not in (resp["warnings"] || []) do
      [nodes_result("nodes", :na, "no remote nodes enrolled")]
    else
      [
        public_url_result(url, nodes),
        exposure_result(url, resp)
      ] ++
        Enum.map(nodes, &node_result/1) ++
        [local_cap_result(resp)] ++
        capacity_result(resp, nodes)
    end
    |> Enum.reject(&is_nil/1)
  end

  defp public_url_result(nil, []), do: nil

  defp public_url_result(nil, _nodes) do
    nodes_result(
      "nodes.public_url reachable",
      :warn,
      "nodes are enrolled but nodes.public_url is not set",
      "arb settings set nodes.public_url https://<primary>.<tailnet>.ts.net"
    )
  end

  defp public_url_result(url, _nodes) do
    case Client.probe_url(url <> "/nodes/ping") do
      {:ok, _} ->
        nodes_result("nodes.public_url reachable", :ok, url)

      {:error, reason} ->
        nodes_result(
          "nodes.public_url reachable",
          :warn,
          "#{url}/nodes/ping did not answer: #{probe_reason(reason)}",
          "Nodes dial this address. Run `tailscale serve --https=443 http://127.0.0.1:4848` " <>
            "on the primary, and check that this machine is on the same tailnet."
        )
    end
  end

  defp probe_reason({:status, status}), do: "HTTP #{status}"
  defp probe_reason(reason), do: inspect(reason)

  defp exposure_result(nil, _resp), do: nil

  defp exposure_result(url, %{"exposure" => "public"} = resp) do
    allowed? = resp["allow_public_endpoint"] == true

    nodes_result(
      "nodes.public_url is a private endpoint",
      :warn,
      "#{url} looks like a public internet address (not *.ts.net, not a private or loopback range)" <>
        if(allowed?,
          do: "; tolerated because nodes.allow_public_endpoint is on, a standing warning",
          else: "; enrolment would be reachable from the internet"
        ),
      "Prefer a tailnet name. Public exposure puts the login page, /api/version and the " <>
        "/live socket on the internet; it is refused unless nodes.allow_public_endpoint is true."
    )
  end

  defp exposure_result(url, _resp),
    do: nodes_result("nodes.public_url is a private endpoint", :ok, url)

  defp node_result(n) do
    state = n["state"] || n["status"]
    health = n["health"]
    ok? = state in ["online", "draining"] and health in [nil, "ready"]

    nodes_result(
      "node #{n["name"]}",
      if(ok?, do: :ok, else: :warn),
      node_detail(n, state, health),
      unless(ok?, do: node_hint(state, health))
    )
  end

  defp node_detail(n, state, health) do
    health_part = if health in [nil, "ready"], do: [], else: ["health #{health}"]

    Enum.join(
      [
        to_string(state),
        "seen #{age(n["last_heartbeat_at"] || n["last_seen_at"])}",
        "v#{n["agent_version"] || "?"} (primary v#{n["server_version"] || "?"})",
        "#{n["live"] || 0}/#{n["max"] || "?"} workers"
      ] ++ health_part,
      ", "
    )
  end

  defp node_hint(state, _health) when state in ["offline", "suspect"],
    do: "The agent is not heartbeating. Check `systemctl --user status arbiter-node` on the node."

  defp node_hint(_state, "outdated"), do: "Run `arb node upgrade <name>`."
  defp node_hint(_state, "ahead"), do: "Run `arb node upgrade <name>` to move it back."

  defp node_hint(_state, "incompatible"),
    do: "The agent speaks a protocol this primary does not; upgrade it."

  defp node_hint(_state, _health), do: "See `arb node show <name>`."

  defp local_cap_result(%{"local" => %{"max" => 0}}) do
    nodes_result(
      "local worker cap",
      :warn,
      "the local cap is 0: work that can only run on this machine (reviewers, fix and " <>
        "conflict passes, agy/codex runs, research) will wait",
      "Raise it with `arb node set local --max-workers N`."
    )
  end

  defp local_cap_result(%{"local" => %{"max" => max}}),
    do: nodes_result("local worker cap", :ok, to_string(max))

  defp local_cap_result(_), do: nodes_result("local worker cap", :ok, "not reported")

  defp capacity_result(_resp, []), do: []

  defp capacity_result(%{"total" => total, "ceiling" => ceiling} = resp, _nodes) do
    cond do
      "ceiling_below_total" in (resp["warnings"] || []) ->
        [
          nodes_result(
            "node capacity vs conductor.max_concurrent",
            :warn,
            "the caps add up to #{total} but conductor.max_concurrent is #{ceiling}: " <>
              "the extra capacity will sit idle",
            "Raise conductor.max_concurrent (it is the operator-owned spend valve), or lower a cap."
          )
        ]

      "ceiling_far_above_total" in (resp["warnings"] || []) ->
        [
          nodes_result(
            "node capacity vs conductor.max_concurrent",
            :warn,
            "conductor.max_concurrent is #{ceiling} but the caps add up to only #{total}: " <>
              "the board will plan more than any machine can start",
            "Lower conductor.max_concurrent, or raise a cap."
          )
        ]

      true ->
        [
          nodes_result(
            "node capacity vs conductor.max_concurrent",
            :ok,
            "#{total} of #{ceiling}"
          )
        ]
    end
  end

  defp capacity_result(_resp, _nodes), do: []

  defp age(nil), do: "never"

  defp age(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> age_text(max(DateTime.diff(DateTime.utc_now(), at), 0))
      _ -> "at an unknown time"
    end
  end

  defp age_text(s) when s < 60, do: "#{s}s ago"
  defp age_text(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp age_text(s) when s < 86_400, do: "#{div(s, 3600)}h ago"
  defp age_text(s), do: "#{div(s, 86_400)}d ago"

  defp nodes_result(name, status, detail, hint \\ nil) do
    %Result{
      name: name,
      status: status,
      detail: detail,
      hint: hint,
      blocks_readiness: false
    }
  end

  # bd-1c4pg3: the dashboard's auth model is "a loopback peer is trusted;
  # there is no login", so a server reachable off-loopback exposes
  # unauthenticated LiveView pages to anyone who can reach the port. This is
  # a posture advisory ([warn], never blocks readiness). An ambiguous response
  # (server predates this endpoint, unreachable, 5xx) is a [warn] "could not
  # check", never an all-clear.
  defp check_bind_address do
    case Client.get("/api/server/bind_address") do
      {:ok, %{"loopback" => true, "ip" => ip}} ->
        %Result{
          name: "bind address is loopback",
          status: :ok,
          detail: ip,
          meta: %{bind: ip},
          blocks_readiness: false
        }

      {:ok, %{"loopback" => false, "ip" => ip}} ->
        %Result{
          name: "bind address is loopback",
          status: :warn,
          meta: %{bind: ip},
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
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: status} = err} when status >= 500 ->
        server_error_result("bind address is loopback", err)

      other ->
        unknown_result("bind address is loopback", other)
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
    probes =
      for {method, path, opts} <- @anonymous_probes do
        label = "#{method |> to_string() |> String.upcase()} #{path}"
        {label, probe_verdict(Client.anonymous(method, path, opts))}
      end

    accepted = for {label, {:accepted, status}} <- probes, do: "#{label} → #{status}"
    unanswered = for {label, {:unknown, why}} <- probes, do: "#{label} (#{why})"

    cond do
      accepted != [] ->
        %Result{
          name: "anonymous /api access refused",
          status: :fail,
          detail: "served without a token: " <> Enum.join(accepted, ", "),
          hint:
            "Any process on this host — every worker included — can drive this server " <>
              "with a plain curl. Upgrade the server (bd-asawcq); `/api` must answer " <>
              "401 without `Authorization: Bearer <token>`."
        }

      unanswered != [] ->
        %Result{
          name: "anonymous /api access refused",
          status: :warn,
          detail: "could not check: " <> Enum.join(unanswered, ", "),
          hint: "Re-run once the server answers; an open `/api` is a fail."
        }

      true ->
        %Result{
          name: "anonymous /api access refused",
          status: :ok,
          detail: "a request without a bearer token gets 401"
        }
    end
  end

  # bd-3gycsz: the dashboard has no address bypass (a `tailscale serve` request
  # arrives from 127.0.0.1), so an anonymous browser request must be redirected
  # to the login page. Probe `GET /` without following redirects; a 2xx means
  # the dashboard is open. The auth mode comes from the authenticated
  # `/api/server/dashboard_auth` and is reported in the detail. An unreachable
  # or unrecognising server (older build, 500) is a `[warn]` "could not check".
  @doc false
  @spec check_dashboard_auth() :: Result.t()
  def check_dashboard_auth do
    result = %Result{
      name: "dashboard requires login",
      status: :warn,
      detail: "could not check: the anonymous dashboard probe was not answered by the server",
      blocks_readiness: false
    }

    mode = dashboard_mode_info()

    if mode.trust_loopback do
      loopback_trusted_result(result, mode)
    else
      anonymous_probe_result(result, mode)
    end
  end

  defp anonymous_probe_result(result, mode) do
    case Client.anonymous(:get, "/", redirect: false, decode_body: false) do
      {:ok, _body} ->
        %{
          result
          | status: :fail,
            detail: "an anonymous browser request to / was served the dashboard",
            hint:
              "Anyone who can reach this server (a tailscale serve proxy arrives from " <>
                "127.0.0.1) gets the whole dashboard. Upgrade the server (bd-3gycsz); " <>
                "then `arb dashboard login` signs your browser in."
        }

      {:error, %Client.Error{kind: :http, status: s}} when s in 300..399 ->
        %{
          result
          | status: :ok,
            detail: "anonymous requests are redirected to login (#{mode.text})"
        }

      _ ->
        result
    end
  end

  # ARB_DASHBOARD_TRUST_LOOPBACK is on, so this probe (a direct request to
  # 127.0.0.1) is *meant* to be served. What must still hold is that a request
  # that looks proxied is redirected: that is the `tailscale serve` shape.
  defp loopback_trusted_result(result, mode) do
    probe =
      Client.anonymous(:get, "/",
        redirect: false,
        decode_body: false,
        headers: [{"x-forwarded-for", "100.64.0.1"}]
      )

    case probe do
      {:ok, _body} ->
        %{
          result
          | status: :fail,
            detail: "a request carrying X-Forwarded-For was served the dashboard (#{mode.text})",
            hint:
              "Loopback trust must never apply to proxied requests (tailscale serve). " <>
                "Unset ARB_DASHBOARD_TRUST_LOOPBACK and upgrade the server."
        }

      {:error, %Client.Error{kind: :http, status: s}} when s in 300..399 ->
        %{
          result
          | status: :ok,
            detail:
              "loopback trusted (opt-in); forwarded requests are redirected to login (#{mode.text})"
        }

      _ ->
        result
    end
  end

  defp dashboard_mode_info do
    case Client.get("/api/server/dashboard_auth") do
      {:ok, %{"impl" => impl, "mode" => mode} = body} ->
        %{text: "impl #{impl}, mode #{mode}", trust_loopback: body["trust_loopback"] == true}

      _ ->
        %{text: "mode unknown", trust_loopback: false}
    end
  end

  # What a no-token probe came to: `{:accepted, status}` (it got past auth),
  # `:refused` (401/403), or `{:unknown, why}` (the server could not be asked
  # or answered 5xx — which says nothing about auth).
  defp probe_verdict({:ok, _body}), do: {:accepted, 200}

  defp probe_verdict({:error, %Client.Error{kind: :http, status: s}}) when s in [401, 403],
    do: :refused

  defp probe_verdict({:error, %Client.Error{kind: :http, status: s}}) when s in 200..499,
    do: {:accepted, s}

  defp probe_verdict({:error, %Client.Error{kind: :http, status: s}}),
    do: {:unknown, "HTTP #{s}"}

  defp probe_verdict({:error, %Client.Error{message: message}}),
    do: {:unknown, to_string(message)}

  # bd-9fgg04: "is it safe to restart?" is the question doctor is reached for.
  # It reports `[ ok ]` only when a restart is safe right now (a paused,
  # quiescent scheduler). A running scheduler is normal operation but not a
  # safe restart point, and a paused scheduler still draining would lose live
  # work: both are `[warn]` carrying the command that gets to a safe point.
  # Never a fail (a deploy's own wait must not hang on a drain, so it never
  # blocks readiness), and an unreadable state is a `[warn]` too — never
  # `[ ok ]` on a guess.
  defp check_restart_safety do
    case SchedulerState.fetch() do
      {:ok, body} -> restart_safety_result(SchedulerState.state(body), body)
      {:error, _} = err -> unknown_result("safe to restart", err)
    end
  end

  defp restart_safety_result("draining", body) do
    lines = Enum.map(SchedulerState.entry_lines(body), &("\n          " <> &1))

    restart_safety(
      :warn,
      "scheduler " <> SchedulerState.headline(body) <> Enum.join(lines),
      "Wait for it to drain: `arb scheduler wait`, then restart promptly."
    )
  end

  defp restart_safety_result("running", body) do
    restart_safety(
      :warn,
      "scheduler #{SchedulerState.headline(body)}",
      "To reach a safe restart point: `arb scheduler pause && arb scheduler wait`."
    )
  end

  defp restart_safety_result("quiescent", body),
    do: restart_safety(:ok, "scheduler " <> SchedulerState.headline(body), nil)

  defp restart_safety_result(_state, _body) do
    restart_safety(
      :warn,
      "could not check: the scheduler reported a state this CLI does not recognise",
      "Upgrade the CLI (`arb self-update`), or read `arb scheduler status`."
    )
  end

  defp restart_safety(status, detail, hint) do
    %Result{
      name: "safe to restart",
      status: status,
      detail: detail,
      hint: hint,
      blocks_readiness: false
    }
  end

  # A server-backed check whose answer is missing or unusable is a `[warn]`
  # saying so, never `[ ok ]` or "skipping": an all-clear on a check that did
  # not run is how a broken install read as healthy (bd-8rvkqd, bd-34a0b4).
  # `other` is the raw `Client` result.
  defp unknown_result(name, other) do
    %Result{
      name: name,
      status: :warn,
      detail: "could not check: " <> unknown_reason(other),
      hint: "Re-run `arb server doctor`; if it persists, check the server log and `arb server version`.",
      blocks_readiness: false
    }
  end

  defp unknown_reason({:error, %Client.Error{kind: :connection_refused}}),
    do: "the server is unreachable"

  defp unknown_reason({:error, %Client.Error{kind: :http, status: 404}}),
    do: "the server does not expose this check (HTTP 404; it may predate it)"

  defp unknown_reason({:error, %Client.Error{kind: :http, status: status} = err}),
    do: "the server returned HTTP #{status}: #{error_detail(err)}"

  defp unknown_reason({:error, %Client.Error{message: message}}), do: to_string(message)
  defp unknown_reason({:ok, _body}), do: "the server answered in a shape this CLI does not read"
  defp unknown_reason(_other), do: "no usable answer from the server"
end
