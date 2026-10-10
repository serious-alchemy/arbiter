defmodule Mix.Tasks.Arbiter.BudgetCalibration do
  @shortdoc "Shadow report: draw per seat-hour per (account, pool, window)"
  @moduledoc """
  Prints the seat-hour calibration (bd-c1dief, DC2 of
  `docs/design/provider-dynamic-concurrency.md` §3.4): for each account, pool
  and window in the append-only quota history, the share of the window one seat
  draws in an hour, fitted by non-negative least squares as
  `Δu = ρ·seat_hours + b·hours`, the rung of the fallback ladder it lands on
  (own fit, other accounts, or the prior), the floor, and the horizon `H`
  (`Arbiter.Quota.BudgetCalibration`).

  **Read-only and shadow only.** It writes nothing and no admission path reads
  it. A fit the data doesn't pin down says which rung it passed over and why.

  ## Usage

      mix arbiter.budget_calibration              # last 30 days
      mix arbiter.budget_calibration --since 14d
      mix arbiter.budget_calibration --since 2026-09-01 --until 2026-10-01

  On a release install, which has no Mix toolchain, run
  `Arbiter.Release.budget_calibration/1` through `bin/arbiter eval` instead.
  """

  use Mix.Task

  alias Arbiter.Quota.BudgetCalibration

  @switches [since: :string, until: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    # Same read-only startup as `mix arbiter.draw_calibration`: the database
    # layer only, never the worker fleet or endpoint.
    Mix.Task.run("app.config")
    repo_config = Application.get_env(:arbiter, Arbiter.Repo, [])
    Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo_config, :log, false))
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = Arbiter.Repo.start_link()

    until = parse_dt(opts[:until]) || DateTime.utc_now()
    since = parse_since(opts[:since], until)

    [since: since, until: until]
    |> BudgetCalibration.calibrate()
    |> BudgetCalibration.format()
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
