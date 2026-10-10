defmodule Mix.Tasks.Arbiter.AdmissionShadowReport do
  @shortdoc "Report: the scheduler walk's shadow admission vs today's, and the gate to enforce"
  @moduledoc """
  Prints the admission shadow report (bd-6cuqcf, DC7 of
  `docs/design/provider-dynamic-concurrency.md` §10.3-§10.4): under
  `scheduler_admission: shadow`, the agreement between the scheduler walk's
  recorded decision and the one that dispatched (by cause and pool), the
  minutes each side would have placed a card the other held, pace safety
  (`u − line` at captures, ahead-of-pace admissions, projected exhaustion),
  calibration bias per rung, published-budget stability, the neighbourhood of
  each reset, and each §10.4 criterion for the gate to `enforce`.

  **Read-only.** It writes nothing.

  ## Usage

      mix arbiter.admission_shadow_report                # last 30 days
      mix arbiter.admission_shadow_report --since 14d
      mix arbiter.admission_shadow_report --since 2026-09-01 --until 2026-10-01

  On a release install, which has no Mix toolchain, run
  `Arbiter.Release.admission_shadow_report/1` through `bin/arbiter eval` instead.
  """

  use Mix.Task

  alias Arbiter.Board.AdmissionShadowReport

  @switches [since: :string, until: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    # Read-only startup, as the other report tasks do: the database
    # layer only, never the worker fleet or endpoint.
    Mix.Task.run("app.config")
    repo_config = Application.get_env(:arbiter, Arbiter.Repo, [])
    Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo_config, :log, false))
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = Arbiter.Repo.start_link()

    until = parse_dt(opts[:until]) || DateTime.utc_now()

    [since: parse_since(opts[:since], until), until: until]
    |> AdmissionShadowReport.collect()
    |> AdmissionShadowReport.build()
    |> AdmissionShadowReport.format()
    |> Mix.shell().info()
  end

  # `Nd` (days back from `until`) or an ISO date/datetime; default 30 days.
  defp parse_since(nil, until), do: DateTime.add(until, -30 * 86_400, :second)

  defp parse_since(str, until) do
    case Regex.run(~r/^(\d+)d$/, str) do
      [_, n] -> DateTime.add(until, -String.to_integer(n) * 86_400, :second)
      _ -> parse_dt(str) || Mix.raise("bad --since: #{str} (use `Nd` or an ISO date)")
    end
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(str) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end
end
