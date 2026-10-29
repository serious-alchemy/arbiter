defmodule Arbiter.Mergers.CIQueue do
  @moduledoc """
  The shared half of `c:Arbiter.Mergers.Merger.ci_queue/0` (#1126): both forges
  report the pipelines / workflow runs waiting for a runner with ISO-8601
  `created_at` stamps, and the gate wants the count plus the oldest.
  """

  @doc """
  `%{pending:, oldest_at:}` for `pending` waiting runs whose creation stamps are
  `timestamps`. A stamp that is missing or unparseable is skipped, so `oldest_at`
  is the oldest one that could be read (`nil` when none could).
  """
  @spec build(non_neg_integer(), [term()]) :: Arbiter.Mergers.Merger.ci_queue()
  def build(pending, timestamps) when is_integer(pending) and is_list(timestamps) do
    %{pending: pending, oldest_at: oldest(timestamps)}
  end

  defp oldest(timestamps) do
    timestamps
    |> Enum.flat_map(fn
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, at, _offset} -> [at]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.min(DateTime, fn -> nil end)
  end
end
