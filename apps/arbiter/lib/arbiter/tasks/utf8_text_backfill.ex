defmodule Arbiter.Tasks.Utf8TextBackfill do
  @moduledoc """
  Repairs rows whose free-text columns hold invalid UTF-8 (written before the
  write-side scrubs existed, e.g. a commit-gate note cut mid-codepoint) in
  `issues`, `messages` and `worker_prepush_steps`. Invalid sequences become
  U+FFFD. Only rows failing `String.valid?/1` are touched; writes go straight
  to the table so no lifecycle side effects fire.
  """

  alias Arbiter.Repo
  alias Arbiter.Text

  @tables [
    {"issues", ~w(title description acceptance notes qa_notes deployment_notes)},
    {"messages", ~w(subject body)},
    {"worker_prepush_steps", ~w(name cmd output)}
  ]

  @type counts :: %{
          scanned: non_neg_integer(),
          repaired: non_neg_integer(),
          would_repair: non_neg_integer()
        }
  @type report :: %{
          scanned: non_neg_integer(),
          repaired: non_neg_integer(),
          would_repair: non_neg_integer(),
          tables: %{String.t() => counts()}
        }

  @doc """
  Options: `:apply?` (default `false`, dry-run). The top-level counts total
  every table; `:tables` breaks them down per table.
  """
  @spec backfill(keyword()) :: report()
  def backfill(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)

    tables = Map.new(@tables, fn {table, columns} -> {table, run(table, columns, apply?)} end)

    totals =
      Enum.reduce(Map.values(tables), %{scanned: 0, repaired: 0, would_repair: 0}, fn c, acc ->
        Map.merge(acc, c, fn _, a, b -> a + b end)
      end)

    Map.put(totals, :tables, tables)
  end

  # Interpolated names come only from the compile-time `@tables` literal,
  # never user input.
  # sobelow_skip ["SQL.Query"]
  defp run(table, columns, apply?) do
    %{rows: rows} = Repo.query!("SELECT id, #{Enum.join(columns, ", ")} FROM #{table}", [])

    Enum.reduce(rows, %{scanned: 0, repaired: 0, would_repair: 0}, fn [id | values], acc ->
      acc = %{acc | scanned: acc.scanned + 1}

      bad =
        Enum.zip(columns, values)
        |> Enum.filter(fn {_, v} -> is_binary(v) and not String.valid?(v) end)

      cond do
        bad == [] ->
          acc

        apply? ->
          Enum.each(bad, fn {col, v} ->
            Repo.query!("UPDATE #{table} SET #{col} = ?1 WHERE id = ?2", [Text.scrub(v), id])
          end)

          %{acc | repaired: acc.repaired + 1}

        true ->
          %{acc | would_repair: acc.would_repair + 1}
      end
    end)
  end
end
