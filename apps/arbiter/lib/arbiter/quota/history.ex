defmodule Arbiter.Quota.History do
  @moduledoc """
  Writes and reads the append-only `Arbiter.Quota.QuotaSnapshot` history
  (bd-5kt9sk).

  `record/2` is called by each quota poll right after it upserts the latest
  row; it appends one snapshot per window that carries a utilization. It is
  best effort — a history failure must never lose the live snapshot.
  """

  require Logger
  require Ash.Query

  alias Arbiter.Accounts.Resolver
  alias Arbiter.Quota
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.QuotaSnapshot

  @doc "Append one row per window of the freshly written quota `row`."
  @spec record(String.t(), struct()) :: :ok
  def record(account_id, row) do
    with %Snapshot{} = snap <- Snapshot.normalize(row) do
      account = Resolver.get(account_id)
      workspace = account_id |> Resolver.workspaces() |> List.first()
      effective = Quota.policy_fields(account, workspace).effective
      captured_at = snap.captured_at || DateTime.truncate(DateTime.utc_now(), :second)

      [
        {snap.window_label, snap.utilization, snap.reset_at, effective.throttle_threshold},
        {snap.secondary_window_label, snap.secondary_utilization, snap.secondary_reset_at,
         effective.weekly_threshold}
      ]
      |> Enum.filter(fn {label, util, _, _} -> is_binary(label) and is_number(util) end)
      |> Enum.each(fn {label, util, reset_at, ceiling} ->
        QuotaSnapshot
        |> Ash.Changeset.for_create(:record, %{
          provider_account_id: account_id,
          provider: snap.provider,
          window: label,
          utilization: util / 1,
          ceiling: ceiling,
          resets_at: reset_at,
          captured_at: captured_at
        })
        |> Ash.create!()
      end)
    end

    :ok
  rescue
    e ->
      Logger.warning("Arbiter.Quota.History: write failed: #{Exception.message(e)}")
      :ok
  end

  @doc "History rows for `account_id`, oldest first; optional `:since` cutoff."
  @spec list(String.t(), keyword()) :: [QuotaSnapshot.t()]
  def list(account_id, opts \\ []) do
    query = Ash.Query.filter(QuotaSnapshot, provider_account_id == ^account_id)

    query =
      case Keyword.get(opts, :since) do
        nil -> query
        since -> Ash.Query.filter(query, captured_at >= ^since)
      end

    query |> Ash.Query.sort(captured_at: :asc, inserted_at: :asc) |> Ash.read!()
  end
end
