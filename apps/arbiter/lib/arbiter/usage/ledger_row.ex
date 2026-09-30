defmodule Arbiter.Usage.LedgerRow do
  @moduledoc """
  A read-only Ecto projection of `usage_events` (the same table
  `Arbiter.Usage.Event` owns as an Ash resource) used only for the ledger's
  hot read paths through `Ecto.Query` — the grouped `SUM(cost_usd) ...
  GROUP BY` aggregates behind `Arbiter.Usage.spend_by_account/1` and
  `spend_by_workspace/1`, and the slim column projection
  `Arbiter.Usage.summarize/1` rolls up (bd-5cevwg). Never written through;
  every insert/update still goes through the Ash resource.

  `raw` is mapped only so a query can reach into it with a SQL JSON function
  (`summarize/1`'s estimated-cost marker). It is `load_in_query: false` and
  typed as a plain string: nothing here should ever pull the whole JSON blob
  into the VM — decoding it is what made the full-row Ash read ~5× slower.
  """
  use Ecto.Schema

  @primary_key false
  schema "usage_events" do
    field :task_id, :string
    field :base_task_id, :string
    field :source, :string
    field :session_id, :string
    field :provider_account_id, Ecto.UUID
    field :workspace_id, :string
    field :repo, :string
    field :model, :string
    field :provider, :string
    field :step, :string
    field :cost_usd, :float
    field :tokens_in, :integer
    field :tokens_out, :integer
    field :thinking_tokens, :integer
    field :cache_creation_tokens, :integer
    field :cache_read_tokens, :integer
    field :duration_ms, :integer
    field :occurred_at, :utc_datetime_usec
    field :raw, :string, load_in_query: false
  end
end
