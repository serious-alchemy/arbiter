defmodule Arbiter.Quota.BudgetBootSmokeTest do
  @moduledoc """
  bd-1p8cxk boot smoke test. v0.2.42 crash-looped on its first
  `Budget.Server` recompute after boot: a quota row with no `reset_at`
  (Antigravity's `claude_and_gpt_models` 5h bucket) raised `BadBooleanError`
  and the application went down with it.

  This starts the release-like shadow tree (`ShadowSupervisor` ->
  `Budget.Server` with its default `Inputs.gather/1`) against a DB seeded with
  real-shaped quota rows -- both Antigravity pools, a Claude row and a Codex
  `session` row, each with windows that have a nil `reset_at` -- and runs one
  recompute. Every pool must publish a budget, none an `:error`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.GoogleQuota
  alias Arbiter.Quota.ShadowSupervisor

  defp account!(provider) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "boot-#{provider}-#{System.unique_integer([:positive])}"
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # The shape `CloudCode.persist` stores: a bucket's `reset_at` is nil when the
  # API sent none.
  defp agy_models(reset) do
    for {id, remaining} <- [
          {"claude_and_gpt_models_5h", 100.0},
          {"claude_and_gpt_models_weekly", 100.0},
          {"gemini_models_5h", 62.0},
          {"gemini_models_weekly", 80.0}
        ] do
      %{"model_id" => id, "remaining_percentage" => remaining, "reset_at" => reset}
    end
  end

  setup do
    claude = account!(:claude)
    agy = account!(:antigravity)
    codex = account!(:codex)

    Ash.create!(AnthropicQuota, %{
      provider_account_id: claude.id,
      provider: "claude",
      utilization_5h: 0.2,
      reset_5h_at: nil,
      status_5h: "allowed",
      utilization_7d: nil,
      status_7d: "allowed",
      captured_at: now(),
      capture_source: "oauth_poll"
    })

    Ash.create!(GoogleQuota, %{
      provider_account_id: agy.id,
      provider: "antigravity",
      plan: "Pro",
      used_percent: 38.0,
      snapshot: %{"models" => agy_models(nil)},
      captured_at: now()
    })

    Ash.create!(CodexQuota, %{
      provider_account_id: codex.id,
      provider: "codex",
      session_used_percent: 30.0,
      session_reset_at: nil,
      captured_at: now()
    })

    %{claude: claude, agy: agy, codex: codex}
  end

  test "one recompute over seeded real-shaped snapshots publishes every pool", ctx do
    name = :"boot_server_#{System.unique_integer([:positive])}"
    table = :"boot_table_#{System.unique_integer([:positive])}"

    sup =
      start_supervised!(
        {ShadowSupervisor,
         server_opts: [
           name: name,
           table: table,
           enabled: true,
           tick_ms: :never,
           calibration: :never
         ]}
      )

    assert :ok = Server.recompute(name)
    assert Process.alive?(sup)

    ids = [ctx.claude.id, ctx.agy.id, ctx.codex.id]
    published = table |> Server.all() |> Enum.filter(&(&1.account in ids))

    assert [
             "antigravity:claude_and_gpt_models",
             "antigravity:gemini_models",
             "claude",
             "codex"
           ] == published |> Enum.map(& &1.pool) |> Enum.sort()

    for %Budget{} = b <- published do
      refute b.binding == :error, "#{b.pool}: #{b.reason}"
      assert is_integer(b.budget) or b.budget == :unlimited
    end
  end
end
