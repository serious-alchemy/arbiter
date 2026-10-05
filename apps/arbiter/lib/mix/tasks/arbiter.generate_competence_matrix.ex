defmodule Mix.Tasks.Arbiter.GenerateCompetenceMatrix do
  @shortdoc "Generate and propose hand competence matrix rows from measured baseline queries"
  @moduledoc """
  Generates and proposes hand competence matrix rows from measured historical tasks
  (bd-biycyw, R6 of `docs/design/paced-quota-routing-signals.md` §3.3, §3.6, and Appendix A).

  Runs the Appendix A queries, groups tasks by `(provider, model, difficulty)`, applies
  90th percentile winsorising to time to close, and outputs a Markdown table matching §3.6.

  With `--seed`, commits the proposed rows to installation settings (`Arbiter.Settings.competence_matrix`).

  ## Usage

      mix arbiter.generate_competence_matrix
      mix arbiter.generate_competence_matrix --min-n 5
      mix arbiter.generate_competence_matrix --from 2026-08-24T00:00:00Z --until 2026-10-01T12:00:00Z
      mix arbiter.generate_competence_matrix --seed
  """

  use Mix.Task

  alias Arbiter.Loop.CompetenceGenerator

  @switches [from: :string, until: :string, min_n: :integer, seed: :boolean, workspace: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")
    repo_config = Application.get_env(:arbiter, Arbiter.Repo, [])
    Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo_config, :log, false))
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = Arbiter.Repo.start_link()

    gen_opts =
      []
      |> maybe_put(:from, parse_dt(opts[:from]))
      |> maybe_put(:until, parse_dt(opts[:until]))
      |> maybe_put(:min_n, opts[:min_n])
      |> maybe_put(:workspace_id, opts[:workspace])

    if opts[:seed] do
      {:ok, rows} = CompetenceGenerator.seed_installation!(gen_opts)

      Mix.shell().info(
        "Successfully seeded #{length(rows)} competence matrix rows to installation settings.\n"
      )

      Mix.shell().info(CompetenceGenerator.format(rows))
    else
      rows = CompetenceGenerator.generate(gen_opts)
      Mix.shell().info(CompetenceGenerator.format(rows))
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp parse_dt(nil), do: nil

  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        case Date.from_iso8601(str) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> Mix.raise("bad datetime: #{str} (use an ISO datetime or YYYY-MM-DD)")
        end
    end
  end
end
