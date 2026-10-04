defmodule Arbiter.Quota.Gate.Snapshot.Anthropic do
  @moduledoc "`Arbiter.Quota.Gate.Snapshot.Source` for `Arbiter.Quota.AnthropicQuota` rows."

  @behaviour Arbiter.Quota.Gate.Snapshot.Source

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate.Snapshot

  @impl true
  def normalize(%AnthropicQuota{} = q, _opts) do
    %Snapshot{
      provider: q.provider,
      utilization: q.utilization_5h,
      status: q.status_5h,
      reset_at: q.reset_5h_at,
      captured_at: q.captured_at,
      capture_source: q.capture_source,
      overage_status: q.overage_status,
      window_label: "5h",
      secondary_utilization: q.utilization_7d,
      secondary_status: q.status_7d,
      secondary_reset_at: q.reset_7d_at,
      secondary_window_label: "7d"
    }
  end

  def normalize(_other, _opts), do: nil
end
