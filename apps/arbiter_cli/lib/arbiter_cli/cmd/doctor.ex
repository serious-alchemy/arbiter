defmodule ArbiterCli.Cmd.Doctor do
  @moduledoc """
  `arb server doctor [--all|-v] [--json]` — health checks.

  Every check has a severity:

    * `ok` — healthy.
    * `warn` — should be fixed, nothing is broken: a policy advisory (the
      account/workspace quota policy), a scheduler that is not at a safe restart
      point, a failed last deploy, an off-loopback bind, a check that could not
      run (`could not check: <reason>` — an unreachable, erroring or older
      server is never read as healthy).
    * `fail` — broken now: server unreachable, migrations pending, CLI/server
      version mismatch, no workspace or repo, an enabled provider's credential
      unusable, an open `/api`, a `:strict` workspace the host cannot jail, a
      podman backend the host cannot run.
    * `n/a` — does not apply to this install (a provider no workspace uses or
      that is paused, podman when no workspace uses it, an egress jail when no
      workspace enforces an allowlist, no nodes enrolled). It is not probed.

  Exit code is 1 when at least one check is `fail`, else 0 — `warn` never
  fails a script. `--json` carries every check (with `id`, `group`, `severity`)
  plus `result` (`ok`/`warn`/`fail`), `exit_code` and `summary`, and `ok` is
  false exactly when the exit code is 1.

  Default output is the header, a summary line (`27 ok · 1 warn · 0 fail`) and
  only the `warn`/`fail` checks with their hint. `--all` (alias `-v`) prints
  every check grouped as core, auth & providers, sandboxes and security
  posture; the agy jail's six sub-checks collapse to one line while they pass.

  Checks, by group:

    * core — Phoenix reachable, a workspace exists, the active workspace
      resolves, repos resolve, CLI and server versions match, the last deploy,
      migrations are applied, safe to restart (the scheduler drain state), merge
      routing, nodes.
    * auth & providers — Claude worker credentials, grok auth, provider
      accounts, tmux (the dashboard login relay), account/workspace quota policy.
    * sandboxes — the agy jail (write jail, escape vectors, hidden reads,
      network, keyring proxy, ssh transport), the egress jail, podman readiness,
      the worker temp dir and the worker memory cap.
    * security posture — bind address, anonymous `/api` refused, dashboard
      login, Erlang distribution loopback-only with an owner-only cookie,
      workspace safe-default categories, guardrail profiles.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.Cmd.Doctor.{Checks, Formatter}
  alias ArbiterCli.Output

  def run(argv) do
    ArgParser.unless_help(argv, @moduledoc, fn ->
      {opts, _rest, mode} =
        ArgParser.parse(argv,
          command: "arb server doctor",
          switches: [all: :boolean, verbose: :boolean],
          aliases: [v: :verbose]
        )

      results = checks()

      case mode do
        :json -> Formatter.emit_json(results)
        :text -> Formatter.emit_text(results, all: opts[:all] == true or opts[:verbose] == true)
      end

      if Formatter.overall(results) == :fail, do: Output.halt(1)
    end)
  end

  @doc """
  Run every health check and return the result structs, in display order.
  Shared by `arb doctor` and `arb start` so "green" has one definition.
  """
  @spec checks() :: [Checks.Result.t()]
  def checks, do: Checks.run()

  @doc """
  True when Phoenix's HTTP API is reachable — the first health check on its
  own. This is the "is the stack already running?" signal `arb start` uses to
  stay a no-op.
  """
  @spec reachable?() :: boolean()
  def reachable?, do: Checks.phoenix().status == :ok

  @doc """
  True when no readiness-blocking health check fails. A `fail` alone can't gate
  this: it also drives `arb doctor`'s exit code, and some checks (like
  workspace resolution) are operator-actionable failures worth a non-zero
  exit without saying anything about whether the deployed server is healthy.
  `blocks_readiness` is the narrower signal `arb server deploy`'s
  auto-rollback wait actually needs. A `warn` never blocks.
  """
  @spec green?() :: boolean()
  def green?, do: green?(checks())

  @doc """
  Same as `green?/0`, but against a result list the caller already fetched —
  lets a caller that needs both the raw checks and the green verdict (e.g. to
  render a report from the same probe) do so from a single `checks()` call
  instead of one HTTP round-trip per use.
  """
  @spec green?([Checks.Result.t()]) :: boolean()
  def green?(results) do
    Enum.all?(results, fn r -> r.status != :fail or not r.blocks_readiness end)
  end

  @doc """
  Print the full, grouped health report (every check, as `arb server doctor
  --all`) to stdout and return whether no check failed (a `[warn]` is not a
  failure). Lets `arb start`, `arb restart`, `arb update` and `arb server
  deploy` show the same status block `arb doctor` does without duplicating the
  formatting.
  """
  @spec report() :: boolean()
  def report, do: report(checks())

  @doc """
  Same as `report/0`, but against a result list the caller already fetched —
  see `green?/1`.
  """
  @spec report([Checks.Result.t()]) :: boolean()
  def report(results) do
    Formatter.emit_text(results, all: true)
    Formatter.overall(results) != :fail
  end
end
