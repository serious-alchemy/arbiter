defmodule Arbiter.Quota.Headroom do
  @moduledoc """
  How much quota an account has **left against its pace** (bd-40pzpj) — the
  number provider routing ranks implementer accounts by.

  ## The formula

  For each window of the account's snapshot (primary 5h / session, long 7d /
  weekly):

      threshold_now = the gate's ceiling for that window, right now
      headroom      = threshold_now − used

  and the account's headroom is the **binding** window's — the smallest.
  `threshold_now` is exactly what `Arbiter.Quota.Gate` holds at, read
  through `Arbiter.Quota.Gate.pace/6` (so through `Arbiter.Quota.Pace`),
  never re-derived here:

    * flat mode: the fixed ceiling (`throttle_threshold` / `weekly_threshold`);
    * paced mode: `max(floor, elapsed)`, where `elapsed` is the fraction of
      the window gone;
    * each side (account `quota_config`, workspace `config["quota"]`) turned
      into its number for now and composed `min(account, workspace)`.

  A window is left out when the gate itself would not trust it — the
  primary one when `Gate.stale?/1`, the long one when
  `Gate.long_window_stale?/1` — or when it carries no utilization reading.
  With no window left (or no snapshot at all) the headroom is **unknown**,
  `nil`, not zero: the gate fails open on missing data, and so does routing,
  which ranks unknown accounts after every known one rather than dropping
  them.

  Antigravity keeps two pools on one row; `opts[:model]` picks which one
  (`Arbiter.Quota.Gate.Snapshot.normalize/2`), so an agy account's headroom
  is the pool of the model it would actually run.

  Headroom can be negative for a window past its ceiling. Such an account is
  quota-held and routing drops it before ranking; the number is still
  reported for the record.
  """

  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  @type t :: %{
          headroom: float(),
          window: String.t(),
          threshold: float(),
          used: float(),
          mode: :paced | :flat
        }

  @doc """
  The binding window's headroom for `quota` under `policy` (see
  `t:Arbiter.Quota.Gate.policy/0`), or `nil` when unknown.

  Options: `:model` (the agy pool selector) and `:now`.
  """
  @spec binding(Gate.quota_source(), Gate.policy(), keyword()) :: t() | nil
  def binding(quota, policy, opts \\ []) do
    case Snapshot.normalize(quota, Keyword.take(opts, [:model])) do
      nil ->
        nil

      %Snapshot{} = s ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

        s
        |> windows()
        |> Enum.map(fn {window, label, used, reset_at} ->
          window_headroom(policy, window, label, used, reset_at, now)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.min_by(& &1.headroom, fn -> nil end)
    end
  end

  defp windows(%Snapshot{} = s) do
    primary =
      if Gate.stale?(s), do: [], else: [{:primary, s.window_label, s.utilization, s.reset_at}]

    long =
      if is_nil(s.secondary_window_label) or Gate.long_window_stale?(s),
        do: [],
        else: [{:long, s.secondary_window_label, s.secondary_utilization, s.secondary_reset_at}]

    primary ++ long
  end

  defp window_headroom(_policy, _window, _label, nil, _reset_at, _now), do: nil

  defp window_headroom(policy, window, label, used, reset_at, now) when is_number(used) do
    pace = Gate.pace(policy, window, label, used, reset_at, now: now)

    %{
      headroom: pace.ceiling - used,
      window: label,
      threshold: pace.ceiling,
      used: used * 1.0,
      mode: pace.mode
    }
  end
end
