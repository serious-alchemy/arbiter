defmodule Arbiter.WorkerWeeklyResetTest do
  # bd-2z3ogf: the weekly reset from the account snapshot must resolve for a
  # `<task>#review` worker too (its State carries no workspace_id and its
  # task_id is not an Issue id) — production Codex review passes fell back to
  # the blind 1h backoff because this lookup returned nil.
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.State

  test "a #review worker resolves the weekly reset from its base task's workspace snapshot" do
    ws =
      Ash.create!(Workspace, %{
        name: "wr-#{System.unique_integer([:positive])}",
        prefix: "wr#{System.unique_integer([:positive])}",
        config: %{"agent" => %{"type" => ["codex"]}}
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :codex,
        slug: "codex-#{System.unique_integer([:positive])}"
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :codex,
      provider_account_id: account.id,
      implementer_position: 1
    })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    weekly = DateTime.add(now, 86_400 * 2, :second)

    Ash.create!(CodexQuota, %{
      provider_account_id: account.id,
      provider: "codex",
      session_used_percent: 100.0,
      session_reset_at: DateTime.add(now, 3_600, :second),
      weekly_used_percent: 100.0,
      weekly_reset_at: weekly,
      limit_reached: true,
      captured_at: now
    })

    issue = Ash.create!(Issue, %{title: "t", workspace_id: ws.id})

    state = %State{
      task_id: "#{issue.id}#review",
      workspace_id: nil,
      meta: %{routing_config: %{provider: "codex"}}
    }

    reason = %{category: :quota_exhausted, retry_after: nil}
    assert Worker.weekly_reset_for(state, reason) == weekly
  end
end
