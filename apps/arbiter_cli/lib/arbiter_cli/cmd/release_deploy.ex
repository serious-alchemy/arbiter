defmodule ArbiterCli.Cmd.ReleaseDeploy do
  @moduledoc """
  `arb server deploy [--version vX.Y.Z] [--timeout SECONDS] [--json] [--force]
  [--no-self-update]` — deploy the Arbiter server from a **GitHub Release** (the OTP release tarball
  published by `.github/workflows/release.yml`), rather than a `git pull` + Mix
  rebuild of a working checkout.

  `arb server deploy --local <tarball|dir>` deploys a **locally built**
  release instead — the tarball or unpacked `_build/prod/rel/arbiter`
  directory produced by `scripts/build-local-release.sh` from a fast-forwarded
  `main`. It shares every step below (unpack, atomic swap, restart,
  health-check, auto-rollback, prune) with the GitHub flow; the only
  difference is where the release tree comes from, and that a local build has
  no published tag or checksum to verify against, so it is assigned a
  synthetic `local-<timestamp>` tag and skips the post-swap version-string
  comparison (which only makes sense against a version GitHub told us to
  expect). `--force`, `--timeout`, `--json`, and
  `--allow-cross-migration-rollback` all work the same with `--local`;
  `--version` is a GitHub-flow-only option and is ignored when `--local` is
  given.

  This is the production deploy path: the box that runs Arbiter no longer needs
  a source checkout or a Mix/Elixir toolchain — only the prebuilt, self-contained
  OTP release. The legacy `git pull` deploy runs only on an explicit
  `arb server deploy --git-pull` (see `ArbiterCli.Cmd.Update`); this command never
  falls back to it. The dashboard's "Update to vX.Y.Z" button launches this same
  command in its own systemd unit (`Arbiter.Release.SelfDeploy`); see
  `docs/self-update.md`.

  ## What it does

    1. **Resolve the target release.** Query the GitHub Releases API for
       `latest` (or the tag named by `--version`). The `owner/repo` comes from
       `ArbiterCli.ReleaseRepo` — `ARB_RELEASE_REPO`, else the running server's
       own release metadata, else the repo this arb was built from — and the
       output names which; a `GITHUB_TOKEN`, if set, authenticates the request
       (required for private repos, and lifts the anonymous rate limit).
    2. **Download the asset + checksum.** Fetch `arbiter-<tag>-linux.tar.gz`
       and its `arbiter-<tag>-linux.tar.gz.sha256` sidecar.
    3. **Verify sha256.** Recompute the tarball's SHA-256 and compare it to the
       published checksum. A mismatch aborts before anything touches disk state.
    4. **Unpack** to `<data-home>/releases/<tag>/` (the OTP release tree, so
       `<data-home>/releases/<tag>/bin/arbiter` is the runnable binary).
    5. **Back up the database** (`ArbiterCli.Cmd.ReleaseDeploy.Backup`): an
       online, integrity-checked snapshot into `<data-home>/snapshots/`, taken
       before the swap; a failure aborts the deploy with nothing changed.
       **Atomically swap** the `<data-home>/current` symlink to the new release
       (symlink-then-rename, so readers never observe a missing/partial link).
    6. **Restart + health-check.** Bounce the service (via systemd when the
       `arbiter.service` user unit is present) and poll `arb doctor` until
       green. Migrations run *here*, inside the new release's own boot — see
       "Migration ordering" below.
    7. **Auto-rollback on failure.** If the stack does not come back green
       within the timeout, re-point `current` at the prior release and restart,
       leaving the server on the last-known-good version. The command then exits
       non-zero so the operator knows the new version was rejected. **When this
       deploy crossed a migration** the backup is restored first (stop → restore
       → swap → restart) — see "Cross-migration rollback".
       **Unless the server was already down before this deploy began** — see
       "Cold deploy" below.
    8. **Prune.** Retain the current release plus the 3 most-recent prior
       releases under `<data-home>/releases/`, and the newest
       `ARB_DEPLOY_BACKUP_RETAIN` (default 5) database snapshots; delete older.
    9. **Install the matching CLI.** After a green deploy, update the arb
       escript to the same tag (`ArbiterCli.Cmd.SelfUpdate.install_from_release/3`)
       so doctor's `version` check agrees; a failure there is reported, never
       fatal. Skipped by `--no-self-update` and for `--local`.

  Throughout, the deploy records itself in `<data-home>/deploy-status.json`
  (`ArbiterCli.Cmd.ReleaseDeploy.Status`) — what `arb doctor`'s "last deploy"
  line and the dashboard banner read after the server restarts.

  ## Cold deploy (bd-5zvux5)

  Step 7's auto-rollback assumes there was a healthy server to protect. Two
  cases break that assumption: a first-ever deploy to a fresh host (no
  `current` yet — the runbook's bootstrap step), and a planned-downtime
  deploy like moving the SQLite database into place, which requires the
  server *stopped* while the file is copied (SQLite allows exactly one
  writer). In both, the pre-flight doctor snapshot (step 1 of "What it does")
  finds the stack down before this command has touched anything.

  This is detected automatically — no flag needed — from the same
  `Doctor.reachable?()` sample `Restart.perform/2` takes right before it
  stops/starts anything. When that sample is false, a subsequent green-wait
  timeout skips auto-rollback entirely: there is nothing healthy to roll back
  to, so `current` stays on the new release (already unpacked, swapped, and
  started) and the command reports that release's own doctor result as the
  outcome, not "the stack is down" framed as this deploy's fault. When the
  sample is true — the ordinary case — auto-rollback behaves exactly as
  before.

  ## Migration ordering (bd-bksulf)

  This command does **not** run migrations. It used to `eval
  Arbiter.Release.migrate` out of the freshly-unpacked release between steps 4
  and 5 — which put a second SQLite *writer* on the database while the old
  server was still serving from it. SQLite allows exactly one writer, and the
  coordinator's own guidance (#754) is that a separate migrate must never run
  against a live server.

  Migration is instead the new release's own boot step:
  `Arbiter.Boot.Migrator` is a synchronous child that migrates to head before
  `ArbiterWeb.Endpoint` binds its port, and it is gated on
  `Arbiter.SingleInstance.primary?/0` so only one node ever migrates. So the
  real ordering is **stop old → (new boots) migrate → serve**, with exactly one
  writer at every instant, and it is the same path dev mode, `arb start`,
  `arb restart` and `arb update` already take. The `Arbiter.Release.migrate`
  eval remains available for an operator who wants to migrate by hand with the
  service stopped.

  ## Cross-migration rollback (bd-bksulf)

  Rolling `current` back to the prior release after the new one has already
  migrated the database puts old code on a schema it has never seen. Before
  swapping, the deploy therefore compares the migrations packaged into the new
  release tree against those in the release it would roll back to
  (`ReleaseFiles.crossed_migrations/2` — a pure filesystem comparison, no DB
  connection). If the new release adds any:

    * the deploy **refuses** to auto-roll back on a health-check failure,
      leaves `current` on the new release, names the crossed migrations, and
      exits non-zero; and
    * `--allow-cross-migration-rollback` overrides that, rolling back anyway
      with a loud warning that the prior release is now on a newer schema.

  **Backup restore (bd-6umf7z).** With a pre-deploy backup in hand, a release
  that added migrations *and booted* (its green-wait timed out) no longer needs
  that refusal: the rollback stops the service, replaces the database with the
  backup (the database the failed release left behind is moved aside, never
  deleted), re-points `current` and restarts — beating
  `--allow-cross-migration-rollback`, which would leave old code on the migrated
  schema. A failed swap (`/api/version` still on the old version) never
  restores: the old release is still serving and its writes would be lost. With
  no backup (no database file existed) the refusal above applies unchanged.

  A deploy that adds no migrations keeps the automatic rollback exactly as it
  was, and never touches the database.

  ## Layout

  All deploy state lives under a data home (default `~/.arbiter`, override with
  `ARB_DATA_HOME`):

      <data-home>/
        current -> releases/v0.1.0      # atomically-swapped symlink
        releases/
          v0.1.0/bin/arbiter
          v0.0.2/bin/arbiter
          …

  The systemd unit is expected to exec `<data-home>/current/bin/arbiter start`,
  so swapping the symlink + restarting is all that's needed to change versions.

  ## Configuration

    * `ARB_RELEASE_REPO` — `owner/repo` to pull releases from (optional; see
      step 1).
    * `DATABASE_PATH` / `ARB_DEPLOY_BACKUP_RETAIN` — the database to back up,
      and how many snapshots to keep.
    * `GITHUB_TOKEN` — optional; authenticates the Releases API request.
    * `ARB_DATA_HOME` — deploy root (default `~/.arbiter`).
    * `ARB_GITHUB_API` — Releases API base (default `https://api.github.com`).

  ## Exit codes

    * `0` — the target release was deployed and the stack is green (or it was
      already the current release).
    * `1` — a precondition failed (missing config, API/download error, checksum
      mismatch, unpack failure) **or** the new release failed its health check
      and was rolled back (or had its rollback refused because the deploy
      crossed a migration).
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Cmd.Doctor, Cmd.InstallService, Cmd.Restart, Cmd.Start}
  alias ArbiterCli.Cmd.ReleaseDeploy.{Backup, Formatter, Github, ReleaseFiles, Status}
  alias ArbiterCli.{Cmd.SelfUpdate, Output, ReleaseRepo}

  @default_timeout_s 60

  @switches [
    version: :string,
    timeout: :integer,
    json: :boolean,
    force: :boolean,
    local: :string,
    allow_cross_migration_rollback: :boolean,
    no_self_update: :boolean
  ]

  @doc "Entry point for `arb server deploy` (release-based path)."
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    ArgParser.unless_help(argv, @moduledoc, fn -> do_deploy(argv) end)
  end

  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp do_deploy(argv) do
    {opts, _rest, mode} = ArgParser.parse_strict!(argv, "arb server deploy", strict: @switches)
    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000
    force = opts[:force] || false

    # A worker must never bounce the orchestrating server, and an in-flight
    # deploy must not abandon active workers. Same guards as `arb restart`.
    Restart.guard_worker_session!()

    if opts[:local] && opts[:version] do
      Output.die(
        "--version and --local are mutually exclusive",
        "--local deploys whatever release tree is at that path — there is no tag to select."
      )
    end

    run = %{mode: mode, force: force, timeout_ms: timeout_ms, opts: opts}

    # Until `begin_status/2` takes over, a halt (repo resolution, the active-worker
    # guard, the release lookup) must still leave a record: a deploy launched from
    # the dashboard has no terminal, and the UI reads this file for the outcome.
    early_tag = opts[:version] || if(opts[:local], do: "local", else: "latest")
    Output.on_halt(fn _code, message -> Status.fail_early(early_tag, message) end)

    case opts[:local] do
      nil -> deploy_from_github(run)
      path -> deploy_from_local(path, run)
    end
  end

  # ---- source: published GitHub release ------------------------------------

  defp deploy_from_github(%{opts: opts, force: force} = run) do
    # Resolve the repo first so a misconfiguration fails fast, before we reach
    # for the (HTTP-backed) active-worker check.
    {repo, repo_source} = Github.release_repo()
    Restart.guard_active_workers!(force)

    release = Github.fetch_release(repo, opts[:version])
    tag = Github.release_tag(release)

    populate = fn target_dir ->
      {tarball_url, sha_url} = Github.release_assets(release, tag)

      log("Downloading #{Github.asset_name(tag)} from #{repo}@#{tag}…")
      tarball = Github.download_binary(tarball_url)
      expected_sha = Github.parse_sha256(Github.download_binary(sha_url))

      Github.verify_sha256!(tarball, expected_sha)
      log("Checksum verified (sha256 #{String.slice(expected_sha, 0, 12)}…).")

      ReleaseFiles.unpack!(tarball, target_dir)
      ReleaseFiles.retain_tarball!(target_dir, tarball, expected_sha)
    end

    extras = %{
      release_repo: repo,
      release_repo_source: to_string(repo_source),
      release_repo_source_text: ReleaseRepo.describe(repo_source)
    }

    self_update = if opts[:no_self_update], do: nil, else: {repo, release}
    deploy(tag, populate, Map.merge(run, %{extras: extras, self_update: self_update}))
  end

  # ---- source: locally-built release (bd-bbgw7k) ----------------------------

  # A locally-built release has no GitHub tag, so it gets a synthetic one:
  # `local-<timestamp>`, unique per invocation so two local deploys never
  # collide on the same release directory (and the idempotency short-circuit
  # below is effectively a no-op for this source — every local deploy is
  # treated as a new release).
  defp deploy_from_local(path, %{force: force} = run) do
    Restart.guard_active_workers!(force)

    unless File.exists?(path) do
      Output.die("--local path does not exist: #{path}")
    end

    tag = "local-" <> Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

    populate = fn target_dir ->
      if File.dir?(path) do
        log("Installing local release directory #{path}…")
        ReleaseFiles.install_dir!(path, target_dir)
      else
        log("Installing local release tarball #{path}…")
        bytes = File.read!(path)
        ReleaseFiles.unpack!(bytes, target_dir)

        ReleaseFiles.retain_tarball!(
          target_dir,
          bytes,
          :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        )
      end

      unless File.exists?(Path.join(target_dir, "bin/arbiter")) do
        # Nothing has swapped or pruned yet, but unpack!/install_dir! already
        # wrote this tree — leaving it behind would waste one of the limited
        # @retain_prior slots a real rollback candidate would otherwise use.
        _ = File.rm_rf(target_dir)

        Output.die(
          "#{path} does not look like an OTP release",
          "expected #{Path.join(target_dir, "bin/arbiter")} to exist after install."
        )
      end
    end

    # A local build has no published release, so there is no matching `arb` to
    # install afterwards.
    deploy(tag, populate, Map.merge(run, %{extras: %{}, self_update: nil}))
  end

  # ---- shared install/swap/rollback path ------------------------------------
  #
  # Both sources share every step from here on — the unpack/swap/prune/rollback
  # machinery has exactly one implementation regardless of where the release
  # tree came from. `populate.(target_dir)` is the only source-specific step:
  # it must leave a fully-formed release under `target_dir` (or raise/die).
  defp deploy(
         tag,
         populate,
         %{mode: mode, force: force, timeout_ms: timeout_ms, opts: opts} = run
       ) do
    releases_dir = ReleaseFiles.releases_dir()
    target_dir = Path.join(releases_dir, tag)
    current_link = ReleaseFiles.current_link()

    # Idempotency: if `current` already points at this tag, there's nothing to
    # do unless the operator forces a redeploy.
    if not force and ReleaseFiles.current_target_basename(current_link) == tag do
      Formatter.emit_already_current(mode, tag)
    else
      begin_status(tag, run)

      # Snapshot doctor state before touching anything, so a readiness-blocking
      # check that's already red (pre-existing condition) is distinguishable from
      # one caused by the release being deployed. Without this, a timed-out
      # green-wait reads identically whether the new release is unhealthy or
      # the stack was already broken before this deploy started. Deferred
      # until after the idempotency check so a no-op `arb server deploy`
      # doesn't pay for it or warn about a deploy that never happens.
      pre_deploy_fails = preflight_blocking_fails()

      if pre_deploy_fails != [] do
        log(preflight_warning(pre_deploy_fails, tag))
      end

      Status.phase("downloading")
      populate.(target_dir)

      # Refresh the PATH in arbiter.env from the deploying shell before
      # restarting the service. The EnvironmentFile= directive loads this file,
      # so any stale or test-corrupted PATH= line here would break every worker
      # spawn after the restart. Writing now ensures the service always boots
      # with the same PATH the operator used to invoke this deploy.
      refresh_env_path()
      preflight_claude_path()

      prior_target = ReleaseFiles.current_target(current_link)

      # Decide the rollback policy *before* the swap, while both release trees
      # are still on disk and nothing has migrated yet.
      rollback_plan =
        rollback_plan(target_dir, prior_target, opts[:allow_cross_migration_rollback] || false)

      case migration_notice(rollback_plan, tag) do
        nil -> :ok
        notice -> log(notice)
      end

      # The database safety net, taken as late as possible so a restore loses as
      # little as possible, and before the swap so a failure here changes nothing.
      backup = take_backup(target_dir, tag)

      Status.phase("swapping")
      ReleaseFiles.atomic_symlink_swap!(current_link, target_dir)
      log("Swapped #{current_link} -> #{target_dir}")

      # Bundled once so the post-restart step (split out below to stay under
      # Credo's complexity threshold) doesn't need a double-digit arity to
      # carry everything the swap decided forward.
      ctx = %{
        mode: mode,
        tag: tag,
        releases_dir: releases_dir,
        target_dir: target_dir,
        prior_target: prior_target,
        current_link: current_link,
        rollback_plan: rollback_plan,
        timeout_ms: timeout_ms,
        backup: backup,
        extras: Map.put(run.extras, :backup, backup),
        self_update: run.self_update
      }

      Status.phase("restarting")

      case Restart.perform(ReleaseFiles.restart_root(current_link), timeout_ms) do
        {:ok, actions, was_running} ->
          handle_restart_ok(ctx, actions, was_running)

        {:timeout, actions, was_running} ->
          handle_restart_timeout(ctx, actions, was_running, pre_deploy_fails)
      end
    end
  end

  # Record this deploy in the status file, and make sure a halt anywhere below
  # (a failed download, a checksum mismatch, a failed backup) leaves a `failed`
  # record rather than a `running` one that never ends.
  defp begin_status(tag, run) do
    Status.start(tag, %{
      "source" => if(run.opts[:local], do: "local", else: "github"),
      "release_repo" => run.extras[:release_repo]
    })

    Output.on_halt(fn _code, message ->
      Status.finish("failed", %{message: message || "the deploy stopped before finishing"})
    end)
  end

  # `nil` when there is no database to protect (a fresh host). A failed backup or
  # integrity check aborts the deploy before the swap.
  defp take_backup(target_dir, tag) do
    Status.phase("backup")

    case Backup.take(target_dir, tag) do
      :skipped ->
        log("No database at #{Backup.db_path()} — skipping the pre-deploy backup.")
        nil

      {:ok, info} ->
        log("Backed up #{info.db} to #{info.path} (integrity_check ok).")
        info

      {:error, message} ->
        Output.die(
          message,
          "Aborted before the swap — nothing was changed and the running release is untouched. " <>
            "Fix the database or the backup location (#{Backup.snapshots_dir()}) and re-run."
        )
    end
  end

  # Split out of `deploy/3` purely to keep that function's cyclomatic
  # complexity under the Credo threshold — this is the "restart succeeded,
  # now decide whether the new release is actually healthy" half of the
  # deploy, and reads as one contiguous step, so it stays adjacent rather
  # than being folded into `verify_deployed_version/1`.
  defp handle_restart_ok(ctx, actions, was_running) do
    case verify_deployed_version(ctx.tag) do
      :ok ->
        finish_deployed(ctx, actions, was_running)

      {:mismatch, server_vsn} ->
        outcome = auto_rollback(ctx, :version_mismatch)
        finish_failed(ctx, outcome)
        Formatter.emit_swap_failed(ctx.mode, ctx.tag, server_vsn, outcome, ctx.extras)

      :inconclusive ->
        # Doctor already confirmed Phoenix is reachable (a fatal check), so a
        # failure here is a transient /api/version hiccup, not evidence the
        # swap failed — don't roll back a healthy deploy on a flaky read of a
        # non-fatal endpoint.
        finish_deployed(ctx, actions, was_running)
    end
  end

  defp finish_deployed(ctx, actions, was_running) do
    pruned = ReleaseFiles.prune_old_releases(ctx.releases_dir, ctx.target_dir, ctx.prior_target)
    Backup.prune(Backup.snapshots_dir(), ctx.backup && ctx.backup.path)

    cli_update = self_update_cli(ctx)
    extras = Map.put(ctx.extras, :cli_update, cli_update)

    Status.finish("succeeded", %{
      backup_path: ctx.backup && ctx.backup.path,
      previous_version: ReleaseFiles.prior_basename(ctx.prior_target)
    })

    Formatter.emit_deployed(
      ctx.mode,
      ctx.tag,
      ReleaseFiles.prior_basename(ctx.prior_target),
      actions,
      was_running,
      pruned,
      extras
    )
  end

  # Install the `arb` escript for the same tag, so the CLI and the server it
  # just deployed agree (doctor's `version` check). The server is already
  # healthy by now, so a failure here is reported, never fatal.
  defp self_update_cli(%{self_update: nil}), do: nil

  defp self_update_cli(%{self_update: {repo, release}, tag: tag}) do
    Status.phase("updating cli")

    case SelfUpdate.install_from_release(repo, release, tag) do
      {:ok, %{updated: true} = info} ->
        # This process now *is* (logically) the new CLI: doctor's version check
        # in the report below must compare the installed version, not the one
        # this escript was started as.
        Process.put(:bd2_app_version, String.trim_leading(tag, "v"))
        info

      {:ok, info} ->
        info

      {:error, message} ->
        %{updated: false, version: tag, error: message}
    end
  end

  defp finish_failed(ctx, outcome) do
    {state, extra} = failure_status(outcome, ctx)
    Status.finish(state, extra)
  end

  defp failure_status({:rolled_back, prior_tag, _crossed}, ctx),
    do: {"rolled_back", status_extra(ctx, %{rolled_back_to: prior_tag, restored_database: false})}

  defp failure_status({:restored, prior_tag, _crossed, info}, ctx) do
    {"rolled_back",
     status_extra(ctx, %{
       rolled_back_to: prior_tag,
       restored_database: true,
       failed_database_path: info.failed_database_path
     })}
  end

  defp failure_status({:no_prior, _, _}, ctx),
    do: {"failed", status_extra(ctx, %{message: "no prior release to roll back to"})}

  defp failure_status(_refused, ctx),
    do: {"refused", status_extra(ctx, %{message: "rollback refused: left on #{ctx.tag}"})}

  defp status_extra(ctx, extra),
    do: Map.merge(%{backup_path: ctx.backup && ctx.backup.path}, extra)

  # `Restart.perform/2` samples `Doctor.reachable?()` itself, right before it
  # stops/starts anything — the same reading `was_running` in
  # `handle_restart_ok/3` already carries for display. Reusing it here is what
  # distinguishes "this deploy broke a healthy server" (roll back, as today)
  # from "the stack was already down before this deploy touched anything"
  # (bd-5zvux5: a first-ever bootstrap, or a planned-downtime deploy like a DB
  # move where the operator stops the server on purpose). In the latter case
  # there is no healthy prior state to protect, so rolling back — or even
  # framing the still-red doctor result as this deploy's fault — is wrong:
  # the new release stays current, already started, and whatever doctor says
  # about it now is reported as-is.
  defp handle_restart_timeout(ctx, actions, false, pre_deploy_fails) do
    if "phoenix reachable" in pre_deploy_fails do
      Status.finish("succeeded", %{
        backup_path: ctx.backup && ctx.backup.path,
        message: "cold deploy: the server was down before the deploy; not rolled back"
      })

      Formatter.emit_cold_deploy(
        ctx.mode,
        ctx.tag,
        actions,
        ctx.timeout_ms,
        pre_deploy_fails,
        ctx.extras
      )
    else
      # `was_running` came back false, but the pre-flight snapshot (taken
      # moments earlier, before anything was touched) still saw Phoenix
      # reachable. That disagreement means the single `Restart.perform/2`
      # sample — one GET with no retry — landed on a transient blip (a GC
      # pause, a busy DB), not a genuinely cold stack. Trusting it alone
      # would skip auto-rollback on what AC2 requires still roll back.
      do_rollback(ctx, pre_deploy_fails)
    end
  end

  defp handle_restart_timeout(ctx, _actions, true, pre_deploy_fails) do
    do_rollback(ctx, pre_deploy_fails)
  end

  @spec do_rollback(map(), [String.t()]) :: no_return()
  defp do_rollback(ctx, pre_deploy_fails) do
    outcome = auto_rollback(ctx, :green_timeout)
    finish_failed(ctx, outcome)

    Formatter.emit_rollback(
      ctx.mode,
      ctx.tag,
      outcome,
      ctx.timeout_ms,
      pre_deploy_fails,
      ctx.extras
    )
  end

  # ---- post-swap version verification --------------------------------------

  # Distinguishes the two mismatch cases from bd-a3t4ao: a stale local CLI is
  # normal and must never gate rollback (that's `Doctor`'s non-fatal `version`
  # check); but here, right after a swap we just performed ourselves, we know
  # exactly which version *should* be running — so a server that reports
  # anything else is a failed swap, and that must roll back.
  # Local builds carry whatever version `mix.exs` derives at build time (the
  # nearest git tag, per its `@version` fallback) — not a version stamped
  # after the tag we made up in `deploy_from_local/5`. There is nothing
  # meaningful to compare, so skip straight to trusting the health check that
  # already gated this call.
  defp verify_deployed_version("local-" <> _), do: :ok

  defp verify_deployed_version(tag) do
    expected_vsn = String.trim_leading(tag, "v")

    case ArbiterCli.Client.get("/api/version") do
      {:ok, %{"version" => server_vsn}} when server_vsn == expected_vsn ->
        :ok

      {:ok, %{"version" => server_vsn}} ->
        {:mismatch, server_vsn}

      {:error, _} ->
        :inconclusive
    end
  end

  # ---- pre-flight -----------------------------------------------------------

  # Names of every currently-red readiness-blocking doctor check, queried
  # against whatever is running *before* this deploy touches anything. Uses
  # `blocks_readiness`, not `fatal` — `fatal` also drives `arb doctor`'s exit
  # code and includes checks (like workspace resolution) that are
  # operator-actionable but have no bearing on whether the green-wait below
  # will time out. Flagging those here would reintroduce a milder version of
  # bd-8ix2tw: a misleading "pre-existing condition" note on a deploy that
  # was never at risk of it.
  defp preflight_blocking_fails do
    Doctor.checks()
    |> Enum.filter(&(&1.status == :fail and &1.blocks_readiness))
    |> Enum.map(& &1.name)
  end

  @doc false
  # Extracted (rather than inlined at the call site) and left public so its
  # content is directly assertable in tests — the `log/1` call it feeds is a
  # no-op whenever `:bd2_sleep` is stubbed, which every deploy test does.
  #
  # When "phoenix reachable" is among the pre-existing failures, the deploy
  # ahead is a cold one (bd-5zvux5) — the server being down is the expected,
  # planned starting point (a first bootstrap or a deliberate DB-move
  # downtime window), not a warning sign to caveat a rollback against.
  def preflight_warning(pre_deploy_fails, tag) do
    if "phoenix reachable" in pre_deploy_fails do
      "server is not running; performing a cold deploy (no auto-rollback)."
    else
      "warning: #{length(pre_deploy_fails)} readiness-blocking health check(s) already " <>
        "failing before this deploy started (#{Enum.join(pre_deploy_fails, ", ")}). Run " <>
        "`arb doctor` to investigate — if this deploy times out waiting for green, " <>
        "that pre-existing condition, not release #{tag}, may be why."
    end
  end

  # ---- rollback -----------------------------------------------------------

  @typedoc """
  What an automatic rollback would do, decided before the symlink swap:

    * `:prior_target` — the release dir to fall back to, or `nil` when there is
      none (a failed first-ever deploy).
    * `:crossed` — migrations the new release ships that `prior_target` does
      not, i.e. the ones a rollback would strand. Always `[]` when
      `prior_target` is `nil`.
    * `:detected` — we actually found migrations packaged in the new release
      tree. An arbiter release always ships some (72 and counting), so an empty
      set means the detection globs no longer match the release layout, not
      that the deploy is migration-free. `crossed: []` is only trustworthy when
      this is true.
    * `:allow_crossed` — the operator passed `--allow-cross-migration-rollback`.
  """
  @type rollback_plan :: %{
          prior_target: String.t() | nil,
          crossed: [String.t()],
          detected: boolean(),
          allow_crossed: boolean()
        }

  @spec rollback_plan(String.t(), String.t() | nil, boolean()) :: rollback_plan()
  defp rollback_plan(target_dir, prior_target, allow_crossed) do
    %{
      prior_target: prior_target,
      crossed: ReleaseFiles.crossed_migrations(target_dir, prior_target),
      detected: ReleaseFiles.migrations(target_dir) != %{},
      allow_crossed: allow_crossed
    }
  end

  @doc false
  # The pre-swap notice for this plan, or nil when there is nothing to say.
  # Public for the same reason as `cross_migration_notice/2`.
  @spec migration_notice(rollback_plan(), String.t()) :: String.t() | nil
  def migration_notice(%{crossed: crossed} = plan, tag) when crossed != [],
    do: cross_migration_notice(plan, tag)

  def migration_notice(%{detected: false} = plan, tag),
    do: undetected_migrations_notice(plan, tag)

  def migration_notice(_plan, _tag), do: nil

  @doc false
  @spec undetected_migrations_notice(rollback_plan(), String.t()) :: String.t()
  def undetected_migrations_notice(%{allow_crossed: allow_crossed}, tag) do
    head =
      "warning: found no migrations packaged in release #{tag} " <>
        "(#{Enum.join(ReleaseFiles.migration_globs(), ", ")}). An arbiter release always " <>
        "ships migrations, so this almost certainly means the release layout moved and " <>
        "cross-migration detection is broken — not that this deploy is migration-free."

    if allow_crossed do
      head <>
        " --allow-cross-migration-rollback was passed, so a health-check failure will still " <>
        "roll back, possibly onto a migrated schema."
    else
      head <> " Automatic rollback is therefore disabled for this deploy."
    end
  end

  @doc false
  # Extracted and left public so its content is directly assertable — the
  # `log/1` call it feeds is a no-op whenever `:bd2_sleep` is stubbed, which
  # every deploy test does.
  @spec cross_migration_notice(rollback_plan(), String.t()) :: String.t()
  def cross_migration_notice(%{crossed: crossed, allow_crossed: allow_crossed}, tag) do
    head =
      "note: release #{tag} adds #{length(crossed)} migration(s) the current release does " <>
        "not ship (#{Enum.join(crossed, ", ")}). They apply during the new release's boot."

    if allow_crossed do
      head <>
        " --allow-cross-migration-rollback was passed, so a health-check failure will still " <>
        "roll back — onto the migrated schema."
    else
      head <> " Automatic rollback is therefore disabled for this deploy."
    end
  end

  # Re-point `current` at the prior release and restart.
  #
  # Returns one of:
  #
  #   * `{:rolled_back, prior_tag, crossed}` — `current` is back on the prior
  #     release. `crossed` is non-empty only when the operator forced it.
  #   * `{:no_prior, nil, []}` — nothing to roll back to.
  #   * `{:refused, prior_tag, crossed}` — the deploy crossed migrations, so
  #     `current` was deliberately left on the new release (bd-bksulf). Booting
  #     `prior_tag` now would run its code against a schema it has never seen,
  #     which is a data-safety decision an operator has to make explicitly.
  #   * `{:undetected, prior_tag, []}` — we could not read the new release's
  #     migrations at all, so the rollback cannot be *proven* safe. Fails closed
  #     the same way as `:refused`, because a detection glob that stopped
  #     matching reports "nothing crossed" for every deploy forever.
  @spec auto_rollback(map(), Formatter.failure_context()) :: Formatter.rollback_outcome()
  defp auto_rollback(%{rollback_plan: %{prior_target: nil}}, _context), do: {:no_prior, nil, []}

  defp auto_rollback(ctx, context) do
    %{rollback_plan: plan, current_link: current_link, timeout_ms: timeout_ms} = ctx
    %{prior_target: prior_target, crossed: crossed, allow_crossed: allow_crossed} = plan
    prior_tag = Path.basename(prior_target)

    case {rollback_decision(plan), allow_crossed, context, ctx.backup} do
      # The new release added migrations and has booted (so they ran): put the
      # pre-deploy database back, then the prior release. Wins over
      # `--allow-cross-migration-rollback`, which would leave old code on the
      # migrated schema. Only after a green-wait timeout — on a version mismatch
      # the OLD release is still serving, and a restore would throw its writes away.
      {:crossed, _, :green_timeout, %{} = backup} ->
        restore_and_roll_back(ctx, prior_tag, crossed, backup)

      {:safe, _, _, _} ->
        perform_rollback(current_link, prior_target, timeout_ms)
        {:rolled_back, prior_tag, []}

      {:crossed, true, _, _} ->
        log(
          "Health check failed and this deploy crossed #{length(crossed)} migration(s) — " <>
            "rolling back anyway because --allow-cross-migration-rollback was passed."
        )

        perform_rollback(current_link, prior_target, timeout_ms)
        {:rolled_back, prior_tag, crossed}

      {:crossed, false, _, _} ->
        log(
          "Health check failed, but this deploy crossed #{length(crossed)} migration(s) — " <>
            "refusing to roll back to #{prior_tag} automatically."
        )

        {:refused, prior_tag, crossed}

      {:undetected, true, _, _} ->
        log(
          "Health check failed and the new release's migrations could not be read — " <>
            "rolling back anyway because --allow-cross-migration-rollback was passed."
        )

        perform_rollback(current_link, prior_target, timeout_ms)
        {:rolled_back, prior_tag, []}

      {:undetected, false, _, _} ->
        log(
          "Health check failed, but the new release's migrations could not be read — " <>
            "refusing to roll back to #{prior_tag} automatically (cannot prove the " <>
            "rollback would not strand a migration)."
        )

        {:undetected, prior_tag, []}
    end
  end

  # Stop → restore → swap → restart. The stop comes first because SQLite has one
  # writer: replacing the file under a running server corrupts it. If the stop
  # fails nothing is touched.
  defp restore_and_roll_back(ctx, prior_tag, crossed, backup) do
    log(
      "Health check failed and this deploy crossed #{length(crossed)} migration(s) — stopping " <>
        "the server and restoring the pre-deploy database backup #{backup.path}…"
    )

    case Restart.stop(ReleaseFiles.restart_root(ctx.current_link)) do
      :ok ->
        {:ok, %{failed_db: failed_db}} = Backup.restore!(backup.path, backup.db, ctx.tag)
        perform_rollback(ctx.current_link, ctx.rollback_plan.prior_target, ctx.timeout_ms)

        {:restored, prior_tag, crossed,
         %{backup_path: backup.path, failed_database_path: failed_db}}

      {:error, reason} ->
        log("Could not stop the server to restore the backup: #{reason}")
        {:restore_failed, prior_tag, crossed, reason}
    end
  end

  # What the automatic rollback is allowed to do, from the plan alone:
  #
  #   * `:safe` — the prior release ships every migration the new one does.
  #   * `:crossed` — the new release adds migrations the prior lacks.
  #   * `:undetected` — the new release's migration set came back empty, which
  #     for arbiter means detection broke. Never report that as `:safe`: a
  #     silent detection failure re-arms exactly the mixed-schema rollback this
  #     guard exists to prevent.
  @spec rollback_decision(rollback_plan()) :: :safe | :crossed | :undetected
  defp rollback_decision(%{crossed: [], detected: true}), do: :safe
  defp rollback_decision(%{crossed: []}), do: :undetected
  defp rollback_decision(_plan), do: :crossed

  defp perform_rollback(current_link, prior_target, timeout_ms) do
    log("Health check failed — rolling back to #{Path.basename(prior_target)}…")
    ReleaseFiles.atomic_symlink_swap!(current_link, prior_target)
    # Best-effort: bring the prior release back up. We report whatever doctor
    # says afterwards rather than gating the rollback on a fresh green wait.
    _ = Restart.perform(ReleaseFiles.restart_root(current_link), timeout_ms)
    :ok
  end

  # ---- env refresh --------------------------------------------------------

  # Write the deploying shell's PATH into arbiter.env so the restarted service
  # inherits a working PATH (one that finds claude, arb, mise shims, etc.).
  # Idempotent: uses the same read/merge/write logic as `arb install service`.
  defp refresh_env_path do
    home = ReleaseFiles.data_home()

    case InstallService.capture_path(home) do
      :written -> log("Refreshed PATH in #{home}/arbiter.env.")
      :skipped -> :ok
    end
  end

  # Verify that `claude` is resolvable after the deploy.  The check runs against
  # the PATH visible to the deploy process — the same PATH that was just written
  # into arbiter.env — so a missing claude is caught before callers block on a
  # failing dispatch.
  defp preflight_claude_path do
    case System.find_executable("claude") do
      nil ->
        log(
          "warning: `claude` not found on PATH (#{System.get_env("PATH", "")}). " <>
            "Worker spawns will fail. Add claude's directory to your shell PATH " <>
            "and re-run `arb install service` to persist it."
        )

        false

      _path ->
        true
    end
  end

  # Progress chatter, routed through the same seam as `arb start`/`arb restart`
  # so it stays quiet under test and on `--json`.
  defp log(msg), do: Start.log_text(msg)
end
