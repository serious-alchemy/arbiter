defmodule Arbiter.Tasks.Utf8TextBackfill do
  @moduledoc """
  Repairs `issues` rows whose free-text columns hold invalid UTF-8 (written
  before `Arbiter.Tasks.Issue.Changes.ScrubText` existed, e.g. a commit-gate
  note cut mid-codepoint). Invalid sequences become U+FFFD. Writes go straight
  to the table so no lifecycle side effects fire.
  """

  alias Arbiter.Repo
  alias Arbiter.Text

  @columns ~w(title description acceptance notes qa_notes deployment_notes)

  @type report :: %{
          scanned: non_neg_integer(),
          repaired: non_neg_integer(),
          would_repair: non_neg_integer()
        }

  @doc "Options: `:apply?` (default `false`, dry-run)."
  @spec backfill(keyword()) :: report()
  # Interpolated names come only from the compile-time `@columns` literal,
  # never user input.
  # sobelow_skip ["SQL.Query"]
  def backfill(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)

    %{rows: rows} =
      Repo.query!("SELECT id, #{Enum.join(@columns, ", ")} FROM issues", [])

    Enum.reduce(rows, %{scanned: 0, repaired: 0, would_repair: 0}, fn [id | values], acc ->
      acc = %{acc | scanned: acc.scanned + 1}

      bad =
        Enum.zip(@columns, values)
        |> Enum.filter(fn {_, v} -> is_binary(v) and not String.valid?(v) end)

      cond do
        bad == [] ->
          acc

        apply? ->
          Enum.each(bad, fn {col, v} ->
            Repo.query!("UPDATE issues SET #{col} = ?1 WHERE id = ?2", [Text.scrub(v), id])
          end)

          %{acc | repaired: acc.repaired + 1}

        true ->
          %{acc | would_repair: acc.would_repair + 1}
      end
    end)
  end
end
