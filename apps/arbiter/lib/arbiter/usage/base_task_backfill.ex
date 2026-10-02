defmodule Arbiter.Usage.BaseTaskBackfill do
  @moduledoc """
  One-off backfill of `usage_events.base_task_id` and `role` for task rows
  written before migration `20260820000000` stamped them live (reports design
  v2 §9 row 3, bd-7o4h44).

  Reports read `base_task_id` directly instead of folding synthetic ids per
  request, so the old rows need it filled in:

    * `base_task_id` = `Arbiter.Usage.Estimate.fold_task_id/1` of `task_id`
      (the same fold `Budget.spend_so_far/2` applies to un-stamped rows, so
      per-ticket totals do not move).
    * `role` is derived from the id suffix, the inverse of the writer's
      `Worker.role_to_usage_step/1`: `#review` / `#r<N>` → `review`,
      `#impl<N>` → `impl` (the last of those in a chain wins), `:fixpass` /
      `fix_pass` → `fix_pass`, `:conflict` → `conflict`, anything else
      `base`. An existing `role` is never overwritten.

  Only `source: :task` rows with a null `base_task_id` are touched. `ext:*`
  ids (`Reviews.ExternalReview`) are not tickets and stay null. Idempotent.

  Plain SQL, grouped by distinct `task_id`, so the ledger's wide `raw` column
  is never read. Dry-run by default.
  """

  alias Arbiter.Repo
  alias Arbiter.Usage.Estimate

  @type report :: %{
          scanned: non_neg_integer(),
          backfilled: non_neg_integer(),
          would_backfill: non_neg_integer(),
          skipped_ext: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Backfill (`apply?: true`) or count (default). Returns a report."
  @spec backfill(keyword()) :: report()
  def backfill(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)

    %{rows: rows} =
      Repo.query!("""
      SELECT task_id, COUNT(*) FROM usage_events
      WHERE source = 'task' AND task_id IS NOT NULL AND base_task_id IS NULL
      GROUP BY task_id
      """)

    {ext, tasks} = Enum.split_with(rows, fn [id, _] -> String.starts_with?(id, "ext:") end)

    empty = %{scanned: 0, backfilled: 0, would_backfill: 0, skipped_ext: sum(ext), failed: 0}

    Enum.reduce(tasks, empty, fn [task_id, count], acc ->
      acc = %{acc | scanned: acc.scanned + count}

      if apply? do
        case update(task_id) do
          {:ok, n} -> %{acc | backfilled: acc.backfilled + n}
          :error -> %{acc | failed: acc.failed + count}
        end
      else
        %{acc | would_backfill: acc.would_backfill + count}
      end
    end)
  end

  @doc "The `role` an id's suffix implies."
  @spec role_for(String.t()) :: String.t()
  def role_for(task_id) when is_binary(task_id) do
    cond do
      Regex.match?(~r/[:#_-]fix_?pass$/, task_id) -> "fix_pass"
      String.ends_with?(task_id, ":conflict") -> "conflict"
      true -> task_id |> String.split("#") |> tl() |> chain_role()
    end
  end

  defp chain_role(segments) do
    segments
    |> Enum.reverse()
    |> Enum.find_value("base", fn seg ->
      cond do
        String.starts_with?(seg, "impl") -> "impl"
        seg == "review" or Regex.match?(~r/^r\d+$/, seg) -> "review"
        true -> nil
      end
    end)
  end

  defp update(task_id) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE usage_events SET base_task_id = ?1, role = COALESCE(role, ?2)
        WHERE source = 'task' AND task_id = ?3 AND base_task_id IS NULL
        """,
        [Estimate.fold_task_id(task_id), role_for(task_id), task_id]
      )

    {:ok, n}
  rescue
    _ -> :error
  end

  defp sum(rows), do: rows |> Enum.map(fn [_, c] -> c end) |> Enum.sum()
end
