defmodule Arbiter.Quota.History do
  @moduledoc """
  Writes and reads the append-only `Arbiter.Quota.QuotaSnapshot` history
  (bd-5kt9sk).

  `record/2` is called by each quota poll right after it upserts the latest
  row; it appends one snapshot per window that carries a utilization. It is
  best effort — a history failure must never lose the live snapshot.

  This is the one append-only quota history (bd-3qfc81, R2): each row carries
  the `bucket` its window meters — the provider, or an Antigravity model group
  — and `prune/1` enforces retention (`config :arbiter, :quota_history,
  retention_days:`, default #{90} days).
  """

  require Logger
  require Ash.Query

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Quota
  alias Arbiter.Quota.CloudCode
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.GoogleQuota
  alias Arbiter.Quota.QuotaSnapshot

  @default_retention_days 90
  @antigravity_groups ["gemini_models", "claude_and_gpt_models"]

  @doc "Configured retention in days (default #{@default_retention_days})."
  @spec retention_days() :: pos_integer()
  def retention_days do
    :arbiter
    |> Application.get_env(:quota_history, [])
    |> Keyword.get(:retention_days, @default_retention_days)
  end

  @doc """
  Append one row per (bucket, window) of the freshly written quota `row`, then
  drop the account's rows past retention.
  """
  @spec record(String.t(), struct()) :: :ok
  def record(account_id, row) do
    do_record(account_id, row, seats_now(account_id))
    prune(provider_account_id: account_id)
  rescue
    e ->
      Logger.warning("Arbiter.Quota.History: write failed: #{Exception.message(e)}")
      :ok
  end

  # The seats the account holds right now (bd-c1dief, DC2): the one live
  # occupancy count the admission path already uses. Read, never written, and a
  # failed read stores `nil` ("unknown"), not 0. It is the account's whole count,
  # not a per-pool one; per-pool seats arrive with DC4, and an Antigravity
  # account's two pools both carry the account figure until then.
  defp seats_now(account_id) do
    Concurrency.live_count(account_id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Antigravity meters two model groups, each with its own 5h and weekly
  # window; one row per (group, window) the snapshot carries.
  defp do_record(account_id, %GoogleQuota{provider: "antigravity"} = row, seats) do
    models =
      case row.snapshot do
        %{"models" => models} when is_list(models) -> models
        _ -> []
      end

    captured_at = row.captured_at || DateTime.truncate(DateTime.utc_now(), :second)

    readings =
      for group <- @antigravity_groups,
          window <- ["5h", "weekly"],
          reading = CloudCode.antigravity_bucket(models, group, window),
          is_number(reading.utilization) do
        {group, window, reading.utilization, reading.reset_at}
      end

    if readings == [] do
      append_normalized(account_id, row, seats)
    else
      Enum.each(readings, fn {group, window, util, reset_at} ->
        append(account_id, "antigravity", group, window, util, reset_at, nil, captured_at, seats)
      end)
    end
  end

  defp do_record(account_id, row, seats), do: append_normalized(account_id, row, seats)

  defp append(account_id, provider, bucket, window, util, reset_at, ceiling, captured_at, seats) do
    QuotaSnapshot
    |> Ash.Changeset.for_create(:record, %{
      provider_account_id: account_id,
      provider: provider,
      bucket: bucket,
      window: window,
      utilization: util / 1,
      ceiling: ceiling,
      resets_at: reset_at,
      captured_at: captured_at,
      seats: seats
    })
    |> Ash.create!()
  end

  defp append_normalized(account_id, row, seats) do
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
        append(
          account_id,
          snap.provider,
          snap.provider,
          label,
          util,
          reset_at,
          ceiling,
          captured_at,
          seats
        )
      end)
    end
  end

  @doc """
  Delete rows older than `:retention_days` (default `retention_days/0`);
  scoped to `:provider_account_id` when given. Best effort.
  """
  @spec prune(keyword()) :: :ok
  def prune(opts \\ []) do
    days = Keyword.get(opts, :retention_days, retention_days())
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now, -days * 86_400, :second)
    query = Ash.Query.filter(QuotaSnapshot, captured_at < ^cutoff)

    query =
      case Keyword.get(opts, :provider_account_id) do
        id when is_binary(id) -> Ash.Query.filter(query, provider_account_id == ^id)
        _ -> query
      end

    Ash.bulk_destroy!(query, :destroy, %{}, strategy: :stream, return_errors?: true)
    :ok
  rescue
    e ->
      Logger.warning("Arbiter.Quota.History: prune failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  History rows for `account_id`, oldest first; optional `:since` / `:until`
  bounds and `:bucket` / `:window` filters.
  """
  @spec list(String.t(), keyword()) :: [QuotaSnapshot.t()]
  def list(account_id, opts \\ []) do
    QuotaSnapshot
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> filter_opt(:since, Keyword.get(opts, :since))
    |> filter_opt(:until, Keyword.get(opts, :until))
    |> filter_opt(:bucket, Keyword.get(opts, :bucket))
    |> filter_opt(:window, Keyword.get(opts, :window))
    |> Ash.Query.sort(captured_at: :asc, inserted_at: :asc)
    |> Ash.read!()
  end

  defp filter_opt(query, _key, nil), do: query
  defp filter_opt(query, :since, since), do: Ash.Query.filter(query, captured_at >= ^since)
  defp filter_opt(query, :until, until), do: Ash.Query.filter(query, captured_at <= ^until)
  defp filter_opt(query, :bucket, bucket), do: Ash.Query.filter(query, bucket == ^bucket)
  defp filter_opt(query, :window, window), do: Ash.Query.filter(query, window == ^window)
end
