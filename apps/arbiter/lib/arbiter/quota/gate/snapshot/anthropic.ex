defmodule Arbiter.Quota.Gate.Snapshot.Anthropic do
  @moduledoc """
  `Arbiter.Quota.Gate.Snapshot.Source` for `Arbiter.Quota.AnthropicQuota` rows.

  Anthropic retired the 5h window (bd-9v8psv), so a row can carry no primary
  reading at all. Then the snapshot has **no primary window**: `window_label`
  and every primary field are `nil`, and the 7d window is the whole story
  ("7d binds"). Absent is never encoded as `0.0`: a `0.0` primary with a nil
  reset reads as a live window downstream and would create a phantom cap.
  """

  @behaviour Arbiter.Quota.Gate.Snapshot.Source

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate.Snapshot

  @impl true
  def normalize(%AnthropicQuota{} = q, _opts) do
    %Snapshot{
      provider: q.provider,
      captured_at: q.captured_at,
      capture_source: q.capture_source,
      overage_status: q.overage_status,
      secondary_utilization: q.utilization_7d,
      secondary_status: q.status_7d,
      secondary_reset_at: q.reset_7d_at,
      secondary_window_label: "7d",
      burn_24h: q.burn_24h,
      burn_24h_at: q.burn_24h_at,
      scoped: Snapshot.scoped_windows(q.scoped_limits)
    }
    |> put_primary(q)
  end

  def normalize(_other, _opts), do: nil

  defp put_primary(%Snapshot{} = snapshot, %AnthropicQuota{} = q) do
    if no_primary_window?(q) do
      %Snapshot{snapshot | window_label: nil}
    else
      %Snapshot{
        snapshot
        | utilization: q.utilization_5h,
          status: q.status_5h,
          reset_at: q.reset_5h_at,
          window_label: "5h"
      }
    end
  end

  # No reset to key a window on, no usage, and no refusal. `0.0` with a nil
  # reset is the phantom window older polls wrote (bd-93zaej); a non-allowed
  # status is a real signal and is kept.
  defp no_primary_window?(%AnthropicQuota{reset_5h_at: nil} = q),
    do: q.utilization_5h in [nil, 0, 0.0] and q.status_5h in [nil, "allowed"]

  defp no_primary_window?(_q), do: false
end
