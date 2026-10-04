defmodule Arbiter.Quota.QuotaSample do
  @moduledoc """
  Append-only history of every quota capture across providers (bd-3qfc81, R2).

  Records `(provider_account_id, bucket, window, used, reset, captured_at)` for
  every quota capture so burn rates can be computed and window draws calibrated
  (R3).

  Old rows past retention are pruned on write and can be swept via `prune/1`.
  Indexed by `[:provider_account_id, :captured_at]` for time-range reads.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Quota,
    data_layer: AshSqlite.DataLayer

  require Ash.Query
  require Logger

  alias Arbiter.Quota.{AnthropicQuota, CloudCode, CodexPlanWindows, CodexQuota, GoogleQuota}
  alias Arbiter.Quota.Gate.Snapshot

  @default_retention_days 90

  sqlite do
    table "quota_samples"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      primary? true

      accept [
        :provider_account_id,
        :account_id,
        :account,
        :bucket,
        :window,
        :used,
        :reset_at,
        :reset,
        :captured_at
      ]

      change fn changeset, _context ->
        # Synchronize reset and reset_at, and allow account/account_id/provider_account_id aliases
        reset_at =
          Ash.Changeset.get_argument_or_attribute(changeset, :reset_at) ||
            Ash.Changeset.get_argument_or_attribute(changeset, :reset)

        account_id =
          Ash.Changeset.get_argument_or_attribute(changeset, :account_id) ||
            Ash.Changeset.get_argument_or_attribute(changeset, :provider_account_id) ||
            Ash.Changeset.get_argument_or_attribute(changeset, :account)

        changeset
        |> then(fn cs ->
          if account_id do
            cs
            |> Ash.Changeset.force_change_attribute(:provider_account_id, account_id)
            |> Ash.Changeset.force_change_attribute(:account_id, account_id)
            |> Ash.Changeset.force_change_attribute(:account, account_id)
          else
            cs
          end
        end)
        |> then(fn cs ->
          if reset_at do
            cs
            |> Ash.Changeset.force_change_attribute(:reset_at, reset_at)
            |> Ash.Changeset.force_change_attribute(:reset, reset_at)
          else
            cs
          end
        end)
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :provider_account_id, :uuid, allow_nil?: false, public?: true
    attribute :account_id, :uuid, public?: true
    attribute :account, :uuid, public?: true
    attribute :bucket, :string, allow_nil?: false, public?: true
    attribute :window, :string, allow_nil?: false, public?: true
    attribute :used, :float, allow_nil?: false, public?: true
    attribute :reset_at, :utc_datetime, public?: true
    attribute :reset, :utc_datetime, public?: true
    attribute :captured_at, :utc_datetime, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  @doc "Configured retention days for quota samples (default #{@default_retention_days})."
  @spec default_retention_days() :: pos_integer()
  def default_retention_days do
    case Application.get_env(:arbiter, :quota_samples, []) do
      days when is_integer(days) and days > 0 -> days
      opts when is_list(opts) -> Keyword.get(opts, :retention_days, @default_retention_days)
      _ -> @default_retention_days
    end
  end

  @doc """
  Record a single quota sample and best-effort prune old rows.
  """
  @spec record(map()) :: {:ok, t()} | {:error, term()}
  def record(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.put_new(attrs, :captured_at, now)

    result =
      __MODULE__
      |> Ash.Changeset.for_create(:record, attrs)
      |> Ash.create()

    with {:ok, sample} <- result do
      prune_on_write(sample.provider_account_id)
      {:ok, sample}
    end
  end

  @doc """
  Record multiple quota samples and prune old rows.
  """
  @spec record_samples([map()]) :: {:ok, [t()]} | {:error, term()}
  def record_samples(samples) when is_list(samples) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    results =
      Enum.reduce_while(samples, {:ok, []}, fn attrs, {:ok, acc} ->
        attrs = Map.put_new(attrs, :captured_at, now)

        case __MODULE__ |> Ash.Changeset.for_create(:record, attrs) |> Ash.create() do
          {:ok, sample} -> {:cont, {:ok, [sample | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, created} <- results do
      account_id = created |> List.first() |> then(&(&1 && &1.provider_account_id))
      if account_id, do: prune_on_write(account_id)
      {:ok, Enum.reverse(created)}
    end
  end

  @doc """
  Append samples extracted from a provider quota snapshot or row.
  """
  @spec record_capture(String.t(), term(), keyword()) :: :ok
  def record_capture(account_id, quota_or_row, opts \\ [])

  def record_capture(account_id, %AnthropicQuota{} = q, opts) do
    bucket = Keyword.get(opts, :bucket, "claude")

    now =
      q.captured_at ||
        Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end)

    samples =
      []
      |> maybe_add_sample(account_id, bucket, "7d", q.utilization_7d, q.reset_7d_at, now)
      |> maybe_add_sample(account_id, bucket, "5h", q.utilization_5h, q.reset_5h_at, now)

    do_record_samples(samples, account_id)
  end

  def record_capture(account_id, %CodexQuota{} = q, opts) do
    bucket = Keyword.get(opts, :bucket, "codex")

    now =
      q.captured_at ||
        Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end)

    session_label =
      case q.session_window_minutes || CodexPlanWindows.minutes(q.plan, :session) do
        mins when is_integer(mins) -> Snapshot.codex_window_label(mins, "session")
        _ -> "session"
      end

    weekly_label =
      case q.weekly_window_minutes || CodexPlanWindows.minutes(q.plan, :weekly) do
        mins when is_integer(mins) -> Snapshot.codex_window_label(mins, "weekly")
        _ -> "weekly"
      end

    samples =
      []
      |> maybe_add_sample(
        account_id,
        bucket,
        weekly_label,
        fraction(q.weekly_used_percent),
        q.weekly_reset_at,
        now
      )
      |> maybe_add_sample(
        account_id,
        bucket,
        session_label,
        fraction(q.session_used_percent),
        q.session_reset_at,
        now
      )

    do_record_samples(samples, account_id)
  end

  def record_capture(account_id, %GoogleQuota{provider: "antigravity"} = q, opts) do
    now =
      q.captured_at ||
        Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end)

    models = models_from(q.snapshot)

    groups = [
      "gemini_models",
      "claude_and_gpt_models"
    ]

    samples =
      for group <- groups,
          window <- ["5h", "weekly"],
          reading = CloudCode.antigravity_bucket(models, group, window),
          reading != nil and is_number(reading.utilization) do
        %{
          provider_account_id: account_id,
          bucket: group,
          window: window,
          used: reading.utilization,
          reset_at: reading.reset_at,
          captured_at: now
        }
      end

    samples =
      if samples == [] and q.used_percent != nil do
        [
          %{
            provider_account_id: account_id,
            bucket: Keyword.get(opts, :bucket, "default"),
            window: "used",
            used: fraction(q.used_percent),
            reset_at: q.reset_at,
            captured_at: now
          }
        ]
      else
        samples
      end

    do_record_samples(samples, account_id)
  end

  def record_capture(account_id, %GoogleQuota{} = q, opts) do
    now =
      q.captured_at ||
        Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end)

    samples =
      if q.used_percent != nil do
        [
          %{
            provider_account_id: account_id,
            bucket: Keyword.get(opts, :bucket, "default"),
            window: "used",
            used: fraction(q.used_percent),
            reset_at: q.reset_at,
            captured_at: now
          }
        ]
      else
        []
      end

    do_record_samples(samples, account_id)
  end

  def record_capture(account_id, samples, _opts) when is_list(samples) do
    do_record_samples(samples, account_id)
  end

  def record_capture(_account_id, _other, _opts), do: :ok

  defp maybe_add_sample(acc, _account_id, _bucket, _window, nil, _reset_at, _captured_at), do: acc

  defp maybe_add_sample(acc, account_id, bucket, window, used, reset_at, captured_at)
       when is_number(used) do
    [
      %{
        provider_account_id: account_id,
        bucket: bucket,
        window: window,
        used: used * 1.0,
        reset_at: reset_at,
        captured_at: captured_at
      }
      | acc
    ]
  end

  defp do_record_samples([], _account_id), do: :ok

  defp do_record_samples(samples, account_id) do
    Enum.each(samples, fn s ->
      __MODULE__
      |> Ash.Changeset.for_create(:record, s)
      |> Ash.create!()
    end)

    prune_on_write(account_id)
    :ok
  rescue
    e ->
      Logger.warning("Arbiter.Quota.QuotaSample: record_capture failed: #{Exception.message(e)}")
  end

  defp prune_on_write(account_id) do
    prune(provider_account_id: account_id)
  rescue
    _ -> :ok
  end

  @doc """
  Read persisted quota samples for `provider_account_id` within an optional
  time range, oldest first by default.

  Options:
    * `:since` or `:from` — include only samples with `captured_at >= since`
    * `:until` or `:to` — include only samples with `captured_at <= until`
    * `:bucket` — filter by bucket
    * `:window` — filter by window
    * `:order` — `:asc` (default) or `:desc`
    * `:limit` — max rows to return
  """
  @spec history(String.t() | nil, keyword()) :: [t()]
  def history(account_id, opts \\ [])

  def history(account_id, opts) when is_binary(account_id) do
    order = Keyword.get(opts, :order, :asc)
    since = Keyword.get(opts, :since) || Keyword.get(opts, :from)
    until = Keyword.get(opts, :until) || Keyword.get(opts, :to)

    __MODULE__
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.Query.sort(captured_at: order, inserted_at: order)
    |> apply_since_filter(since)
    |> apply_until_filter(until)
    |> apply_bucket_filter(Keyword.get(opts, :bucket))
    |> apply_window_filter(Keyword.get(opts, :window))
    |> apply_limit(Keyword.get(opts, :limit))
    |> Ash.read!()
  rescue
    e ->
      Logger.warning("Arbiter.Quota.QuotaSample.history failed: #{Exception.message(e)}")
      []
  end

  def history(_account_id, _opts), do: []

  @doc """
  Delete `QuotaSample` rows older than `:retention_days`.

  Options:
    * `:retention_days` — number of days (default `default_retention_days/0`)
    * `:now` — current DateTime reference (default `DateTime.utc_now/0`)
    * `:provider_account_id` or `:account_id` — optional account scope
  """
  @spec prune(keyword()) :: :ok
  def prune(opts \\ []) do
    retention_days = Keyword.get(opts, :retention_days, default_retention_days())
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now, -retention_days * 86_400, :second)

    query =
      __MODULE__
      |> Ash.Query.filter(captured_at < ^cutoff)

    query =
      case Keyword.get(opts, :provider_account_id) || Keyword.get(opts, :account_id) do
        account_id when is_binary(account_id) and account_id != "" ->
          Ash.Query.filter(query, provider_account_id == ^account_id)

        _ ->
          query
      end

    Ash.bulk_destroy!(query, :destroy, %{}, strategy: :stream, return_errors?: true)
    :ok
  rescue
    e ->
      Logger.warning("Arbiter.Quota.QuotaSample.prune failed: #{Exception.message(e)}")
      :ok
  end

  defp apply_since_filter(query, nil), do: query
  defp apply_since_filter(query, since), do: Ash.Query.filter(query, captured_at >= ^since)

  defp apply_until_filter(query, nil), do: query
  defp apply_until_filter(query, until), do: Ash.Query.filter(query, captured_at <= ^until)

  defp apply_bucket_filter(query, nil), do: query
  defp apply_bucket_filter(query, bucket), do: Ash.Query.filter(query, bucket == ^bucket)

  defp apply_window_filter(query, nil), do: query
  defp apply_window_filter(query, window), do: Ash.Query.filter(query, window == ^window)

  defp apply_limit(query, n) when is_integer(n) and n > 0, do: Ash.Query.limit(query, n)
  defp apply_limit(query, _), do: query

  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0
  defp fraction(_), do: nil

  defp models_from(%{"models" => models}) when is_list(models), do: models
  defp models_from(%{models: models}) when is_list(models), do: models
  defp models_from(_), do: []
end
