defmodule Mix.Tasks.Arbiter.BackfillAttentionSpans do
  @shortdoc "Rebuild ticket_attention_spans from the paper trail and typed escalations"
  @moduledoc """
  Backfill `ticket_attention_spans` (bd-cq1wsp) for the attention that
  happened before live capture shipped: stored causes and their owner moves
  replayed from `issues_versions`, plus typed escalations that name a cause.
  See `Arbiter.Tasks.AttentionSpanBackfill` for the rules.

  ## Usage

      mix arbiter.backfill_attention_spans                     # dry-run (default)
      mix arbiter.backfill_attention_spans --apply             # write the rows
      mix arbiter.backfill_attention_spans --since 2026-09-15  # window start

  Idempotent: a span already in the table — written by an earlier run or by
  live capture — is skipped, so a second `--apply` inserts nothing.

  ## Release installs

  A thin CLI wrapper over `Arbiter.Release.backfill/2`:

      bin/arbiter eval 'Arbiter.Release.backfill(:attention_spans)'             # dry-run
      bin/arbiter eval 'Arbiter.Release.backfill(:attention_spans, apply?: true)'
  """

  use Mix.Task

  @switches [apply: :boolean, since: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")

    backfill_opts =
      [apply?: opts[:apply] == true, hint: "--apply"]
      |> put_since(opts[:since])

    Arbiter.Release.backfill(:attention_spans, backfill_opts)
  end

  defp put_since(opts, nil), do: opts

  defp put_since(opts, value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        Keyword.put(opts, :since, DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC"))

      {:error, _} ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> Keyword.put(opts, :since, dt)
          {:error, _} -> Mix.raise("--since must be an ISO8601 date or datetime, got: #{value}")
        end
    end
  end
end
