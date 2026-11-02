defmodule Mix.Tasks.Arbiter.BurnReport do
  @shortdoc "Report: p50/p90/p99 of the historical rolling-24h burn per account, and what a cap would hold"
  @moduledoc """
  Prints the burn report (bd-cklotu): per account, the p50 / p90 / p99 of the
  historical rolling-24h burn of the 7d window (`Arbiter.Quota.Burn`), and for an
  account with a `daily_burn_cap`, or a `--cap` given here, how many hourly
  readings the cap would have held. Use it to pick `daily_burn_cap` from data.

  **Read-only.** It writes nothing.

  ## Usage

      mix arbiter.burn_report                  # last 30 days
      mix arbiter.burn_report --since 14d
      mix arbiter.burn_report --cap 0.25       # replay a cap no account has yet
      mix arbiter.burn_report --since 2026-09-01 --until 2026-10-01

  On a release install, run `Arbiter.Release.burn_report/1` through `bin/arbiter eval`.
  """

  use Mix.Task

  alias Arbiter.Quota.BurnReport

  @switches [since: :string, until: :string, cap: :float]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    cap = opts[:cap]

    if cap && (cap <= 0 or cap > 1), do: Mix.raise("--cap must be a number in (0, 1]")

    # Read-only startup, as the other report tasks do: database layer only.
    Mix.Task.run("app.config")
    repo_config = Application.get_env(:arbiter, Arbiter.Repo, [])
    Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo_config, :log, false))
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = Arbiter.Repo.start_link()

    until = parse_dt(opts[:until]) || DateTime.utc_now()

    [since: parse_since(opts[:since], until), until: until]
    |> BurnReport.collect()
    |> BurnReport.build(cap: cap)
    |> BurnReport.format()
    |> Mix.shell().info()
  end

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
