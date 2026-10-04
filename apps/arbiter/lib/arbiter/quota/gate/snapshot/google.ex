defmodule Arbiter.Quota.Gate.Snapshot.Google do
  @moduledoc "`Arbiter.Quota.Gate.Snapshot.Source` for `Arbiter.Quota.GoogleQuota` rows (Gemini and Antigravity)."

  @behaviour Arbiter.Quota.Gate.Snapshot.Source

  alias Arbiter.Quota.CloudCode
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.GoogleQuota

  # Antigravity's `/usage` groups slug to these prefixes (see
  # `Arbiter.Quota.CloudCode`'s `agy_bucket_id/2`): "Gemini Models" ->
  # "gemini_models", "Claude and GPT models" -> "claude_and_gpt_models", each
  # combined with a `_5h` / `_weekly` window suffix into the model id
  # persisted in `GoogleQuota.snapshot["models"]`.
  @antigravity_gemini_group "gemini_models"
  @antigravity_claude_gpt_group "claude_and_gpt_models"

  @impl true
  def normalize(%GoogleQuota{provider: "antigravity"} = q, opts) do
    case antigravity_windows(q, Keyword.get(opts, :model)) do
      {primary, secondary} ->
        %Snapshot{
          provider: q.provider,
          utilization: primary.utilization,
          status: nil,
          reset_at: primary.reset_at,
          captured_at: q.captured_at,
          window_label: "5h",
          secondary_utilization: secondary.utilization,
          secondary_status: nil,
          secondary_reset_at: secondary.reset_at,
          secondary_window_label: "weekly"
        }

      nil ->
        normalize_google(q)
    end
  end

  def normalize(%GoogleQuota{} = q, _opts), do: normalize_google(q)
  def normalize(_other, _opts), do: nil

  # The pre-bd-7qj58o representative-used-percent projection: a single
  # collapsed "worst of everything" figure with no secondary window. Still
  # the fallback for an `"antigravity"` row whose stored snapshot carries no
  # parseable per-bucket models (stale schema, transient fetch error
  # preserved via `preserve_last_good/3`, etc).
  defp normalize_google(%GoogleQuota{} = q) do
    %Snapshot{
      provider: q.provider,
      utilization: Snapshot.fraction(q.used_percent),
      # Google's Cloud Code Assist API reports no allowed/rejected verdict — the
      # representative used-percent is the only gating signal.
      status: nil,
      reset_at: q.reset_at,
      captured_at: q.captured_at,
      window_label: "used"
    }
  end

  # Resolve the Antigravity 5h + weekly readings to gate on, from the
  # per-bucket `models` list persisted in `GoogleQuota.snapshot` (bd-7qj58o
  # AC3/AC4). Returns `{primary, secondary}` — each `%{utilization:, reset_at:}`
  # — or `nil` when the snapshot carries no matching buckets (falls back to
  # `normalize_google/1`'s single collapsed figure).
  #
  # `model` picks the sub-bucket group: `claude-*` / `gpt-*` gates on "Claude
  # and GPT models" (AC4), anything else (a `gemini-*` model, or `nil` when
  # the caller doesn't know the model yet) gates on "Gemini Models" — the
  # worst reading across *both* groups for that window when the group-exact
  # bucket isn't found, so an unclassified dispatch still holds rather than
  # silently reading an empty/headroom bucket.
  defp antigravity_windows(%GoogleQuota{snapshot: snapshot}, model) do
    models = models_from(snapshot)
    group = bucket_group(model)

    with [_ | _] <- models,
         %{} = primary <- bucket_reading(models, group, "5h"),
         %{} = secondary <- bucket_reading(models, group, "weekly") do
      {primary, secondary}
    else
      _ -> nil
    end
  end

  defp bucket_group(model) when is_binary(model) do
    if String.starts_with?(model, "claude-") or String.starts_with?(model, "gpt-") do
      @antigravity_claude_gpt_group
    else
      @antigravity_gemini_group
    end
  end

  defp bucket_group(_model), do: nil

  # Delegates the exact {group, window} match to the shared reader
  # (`CloudCode.antigravity_bucket/3`, also used by `CloudCode.view/1`), then
  # falls back to the worst reading across both groups for that window — via
  # the same shared per-bucket formula (`CloudCode.antigravity_bucket_reading/1`)
  # — when no group is known or no exact bucket exists.
  defp bucket_reading(models, group, window) do
    case CloudCode.antigravity_bucket(models, group, window) do
      %{} = found -> found
      nil -> models |> window_candidates(window) |> CloudCode.antigravity_bucket_reading()
    end
  end

  defp window_candidates(models, window) do
    Enum.filter(models, fn m ->
      case Map.get(m, "model_id") do
        id when is_binary(id) -> String.ends_with?(id, "_#{window}")
        _ -> false
      end
    end)
  end

  defp models_from(%{"models" => models}) when is_list(models), do: models
  defp models_from(_), do: []
end
