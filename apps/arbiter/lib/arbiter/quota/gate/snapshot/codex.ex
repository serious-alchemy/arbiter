defmodule Arbiter.Quota.Gate.Snapshot.Codex do
  @moduledoc "`Arbiter.Quota.Gate.Snapshot.Source` for `Arbiter.Quota.CodexQuota` rows."

  @behaviour Arbiter.Quota.Gate.Snapshot.Source

  alias Arbiter.Quota.CodexPlanWindows
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.Gate.Snapshot

  @impl true
  def normalize(%CodexQuota{} = q, _opts) do
    %Snapshot{
      provider: q.provider,
      utilization: Snapshot.fraction(q.session_used_percent),
      status: if(q.limit_reached == true, do: "limit_reached"),
      reset_at: q.session_reset_at,
      captured_at: q.captured_at,
      window_label: Snapshot.codex_window_label(codex_minutes(q, :session), "session"),
      secondary_utilization: Snapshot.fraction(q.weekly_used_percent),
      # Codex reports one `limit_reached` flag for the account, not per window;
      # it is already carried on the primary window, so the weekly window gates
      # on utilization alone.
      secondary_status: nil,
      secondary_reset_at: q.weekly_reset_at,
      secondary_window_label: Snapshot.codex_window_label(codex_minutes(q, :weekly), "weekly")
    }
  end

  def normalize(_other, _opts), do: nil

  # A window's length: the one `wham/usage` reported (stored on the row), else
  # the per-plan table (bd-afvsnc) — but only for a window the row actually
  # carries, so a free plan's `weekly: nil` never grows a phantom weekly length.
  # `nil` (unknown plan, no reported length) keeps the legacy label, whose
  # length `Gate.window_seconds/2` cannot resolve: pacing off for that window.
  defp codex_minutes(%CodexQuota{} = q, :session),
    do: q.session_window_minutes || plan_minutes(q.plan, :session, q.session_reset_at)

  defp codex_minutes(%CodexQuota{} = q, :weekly),
    do: q.weekly_window_minutes || plan_minutes(q.plan, :weekly, q.weekly_reset_at)

  defp plan_minutes(_plan, _window, nil), do: nil
  defp plan_minutes(plan, window, _reset_at), do: CodexPlanWindows.minutes(plan, window)
end
