defmodule ArbiterWeb.QuotaFixtures do
  @moduledoc """
  Quota rows for the LiveView tests that render the top bar and `/usage` rate
  limits (bd-gukyy1).
  """

  alias Arbiter.Quota

  @doc "The `message` `CloudCode.antigravity/1` sets when `agy` isn't on PATH."
  def agy_missing_message,
    do:
      "Antigravity CLI (agy) is not installed on this host (or not on PATH); install it and " <>
        "run it once to authenticate before checking quota."

  @doc """
  Upserts an antigravity `GoogleQuota` row on `ws`'s antigravity account with
  bd-7mro0t's 4-bucket snapshot: Gemini Models 25% (5h) / 60% (weekly) used,
  Claude and GPT models 10% / 20% used.

  Options: `:gemini_5h_remaining` (default `75.0`), `:models` (replaces the
  whole list — `[]` for an unparseable snapshot), `:message`.
  """
  def antigravity_quota!(ws, opts \\ []) do
    {:ok, account_id} = Quota.ensure_account_id(ws.id, "antigravity")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reset = fn secs -> now |> DateTime.add(secs) |> DateTime.to_iso8601() end

    models =
      Keyword.get_lazy(opts, :models, fn ->
        [
          bucket("gemini_models_5h", Keyword.get(opts, :gemini_5h_remaining, 75.0), reset.(3600)),
          bucket("gemini_models_weekly", 40.0, reset.(3 * 86_400)),
          bucket("claude_and_gpt_models_5h", 90.0, reset.(3600)),
          bucket("claude_and_gpt_models_weekly", 80.0, reset.(3 * 86_400))
        ]
      end)

    Quota.GoogleQuota
    |> Ash.Changeset.for_create(:upsert, %{
      provider_account_id: account_id,
      provider: "antigravity",
      plan: "Unknown",
      message: Keyword.get(opts, :message),
      used_percent: 60.0,
      reset_at: DateTime.add(now, 3600),
      snapshot: %{"provider" => "antigravity", "models" => models},
      captured_at: now
    })
    |> Ash.create!()
  end

  @doc """
  Upserts a Codex `CodexQuota` row on `ws`'s Codex account. By default includes
  both session and weekly windows. Options: `:session_used_percent` (default 30.0),
  `:weekly_used_percent` (default 0.0). Set `:weekly_used_percent` to nil for a
  session-only snapshot (no weekly window).
  """
  def codex_quota!(ws, opts \\ []) do
    {:ok, account_id} = Quota.ensure_account_id(ws.id, "codex")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    weekly_pct = Keyword.get(opts, :weekly_used_percent, 0.0)

    Quota.CodexQuota
    |> Ash.Changeset.for_create(:upsert, %{
      provider_account_id: account_id,
      provider: "codex",
      plan: "free",
      limit_reached: false,
      session_used_percent: Keyword.get(opts, :session_used_percent, 30.0),
      session_reset_at: DateTime.add(now, 3600),
      weekly_used_percent: weekly_pct,
      weekly_reset_at: if(is_number(weekly_pct), do: DateTime.add(now, 604_800), else: nil),
      captured_at: now
    })
    |> Ash.create!()
  end

  @doc """
  Overrides `Arbiter.Quota.hidden_providers/0` for the rest of the test.
  Restores the previous value on exit.
  """
  def with_hidden_providers(providers) do
    previous = Application.fetch_env(:arbiter, :quota_hidden_providers)
    Application.put_env(:arbiter, :quota_hidden_providers, providers)
    Arbiter.Quota.QuotaCache.invalidate_all()

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbiter, :quota_hidden_providers, value)
        :error -> Application.delete_env(:arbiter, :quota_hidden_providers)
      end
    end)
  end

  defp bucket(model_id, remaining, reset_at),
    do: %{"model_id" => model_id, "remaining_percentage" => remaining, "reset_at" => reset_at}
end
