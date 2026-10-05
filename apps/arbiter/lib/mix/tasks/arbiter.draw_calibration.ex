defmodule Mix.Tasks.Arbiter.DrawCalibration do
  @shortdoc "Shadow report: window share per weighted token per (pool, window, model)"
  @moduledoc """
  Prints the draw calibration (bd-3is1nz, R3 of
  `docs/design/paced-quota-routing-signals.md`): for each account, pool and
  window in the append-only quota history, how much of the window one weighted
  token of each model draws, fitted by non-negative least squares over
  `quota_snapshots` deltas against `usage_events`
  (`Arbiter.Loop.Scarcity.Draw`).

  **Read-only and shadow only.** It writes nothing and no routing path reads it.
  A pool or model the history can't support prints "insufficient data" with the
  reason, never `0`.

  ## Usage

      mix arbiter.draw_calibration              # last 30 days
      mix arbiter.draw_calibration --since 14d
      mix arbiter.draw_calibration --since 2026-09-01 --until 2026-10-01

  On a release install, which has no Mix toolchain, run
  `Arbiter.Release.draw_calibration/1` through `bin/arbiter eval` instead.
  """

  use Mix.Task

  @switches [since: :string, until: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    # Same read-only startup as `mix arbiter.loop.analyze`: the database layer
    # only, never the worker fleet or endpoint.
    Mix.Task.run("app.config")
    repo_config = Application.get_env(:arbiter, Arbiter.Repo, [])
    Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo_config, :log, false))
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = Arbiter.Repo.start_link()

    until = parse_dt(opts[:until]) || DateTime.utc_now()
    since = parse_since(opts[:since], until)

    Arbiter.Loop.Scarcity.Draw.calibrate(since: since, until: until)
    |> Arbiter.Loop.Scarcity.Draw.format()
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
