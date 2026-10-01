defmodule Arbiter.Tasks.Issue.Changes.RecordAttentionSpan do
  @moduledoc """
  Records what an Issue write did to the ticket's attention as
  `ticket_attention_spans` rows (bd-cq1wsp), inside the write's transaction:
  `Arbiter.Tasks.AttentionSpans.record_write/3` compares the row the write
  started from with the row it wrote.

  On every action that writes the attention: `ClearAttention.clear/2` adds it
  (so every transition, `:clear_attention` and `:clear_review_park`), and the
  actions that raise or move a cause declare it (`:raise_attention`,
  `:park_review`, `:pr_closed`, `:await_verification`,
  `:set_attention_owner`). Added once per write however many of those a write
  goes through.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.AttentionSpans
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context), do: record(changeset)

  @doc "Record `changeset`'s attention spans once it writes. Idempotent per changeset."
  @spec record(Changeset.t()) :: Changeset.t()
  def record(%Changeset{context: %{attention_span_recorded?: true}} = changeset), do: changeset

  def record(changeset) do
    changeset
    |> Changeset.set_context(%{attention_span_recorded?: true})
    |> Changeset.after_action(fn changeset, issue ->
      AttentionSpans.record_write(changeset.data, issue, action_name(changeset))
      {:ok, issue}
    end)
  end

  defp action_name(%Changeset{action: %{name: name}}), do: name
  defp action_name(_changeset), do: nil
end
