defmodule Mix.Tasks.Arbiter.RoutingShadowReport do
  @shortdoc "Report: scored routing's shadow picks vs the picks that dispatched"
  @moduledoc """
  Prints the routing shadow report (bd-adtnto, R5 of
  `docs/design/paced-quota-routing-signals.md`): under
  `routing.provider_selection: scored` with `routing.scoring.mode: shadow`,
  the agreement rate between the scorer's recorded choice and the choice that
  dispatched, and every disagreement with its reason. Read it before setting
  `enforce` on a workspace.

  **Read-only.** It writes nothing.

  ## Usage

      mix arbiter.routing_shadow_report                  # last 30 days
      mix arbiter.routing_shadow_report --since 14d
      mix arbiter.routing_shadow_report --since 2026-09-01 --workspace <id>

  On a release install, which has no Mix toolchain, run
  `Arbiter.Release.shadow_report/1` through `bin/arbiter eval` instead.
  """

  use Mix.Task

  alias Arbiter.Agents.Routing.ShadowReport

  @switches [since: :string, until: :string, workspace: :string]

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
    |> Keyword.merge(if opts[:workspace], do: [workspace_id: opts[:workspace]], else: [])
    |> ShadowReport.collect()
    |> ShadowReport.build()
    |> ShadowReport.format()
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
