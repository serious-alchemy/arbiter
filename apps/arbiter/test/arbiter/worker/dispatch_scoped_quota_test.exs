defmodule Arbiter.Worker.DispatchScopedQuotaTest do
  @moduledoc """
  bd-e0b7so AC3: the dispatch quota gate reads the card's own model against a
  Claude account's per-model weekly windows. A Fable card is held while Fable's
  scoped limit is exhausted; a card pinned to another model on an account in
  the same state dispatches.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker.Dispatch

  @repo ResumeSlotFixture.repo()

  setup do
    ResumeSlotFixture.setup_repo!()
    Application.put_env(:arbiter, :conductor_system_max_concurrent, 10)
    :ok
  end

  defp workspace!(model) do
    n = System.unique_integer([:positive])

    Ash.create!(Workspace, %{
      name: "scoped-#{n}",
      prefix: "sc#{n}",
      config: %{"agent" => %{"type" => "claude", "config" => %{"model" => model}}}
    })
  end

  defp seed_quota!(ws, scoped_limits) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Ash.create!(
      AnthropicQuota,
      %{
        provider_account_id: quota_account_id!(ws.id),
        provider: "claude",
        utilization_7d: 0.30,
        status_7d: "allowed",
        reset_7d_at: DateTime.add(now, 3 * 86_400, :second),
        captured_at: now,
        capture_source: "oauth_poll",
        scoped_limits: scoped_limits
      },
      action: :record_oauth_snapshot
    )
  end

  defp exhausted_fable do
    reset = DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.to_iso8601()

    [
      %{
        "scope" => "Fable",
        "utilization" => 1.0,
        "status" => "rejected",
        "reset_at" => reset,
        "is_active" => true
      }
    ]
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- scoped fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  defp dispatch(issue), do: Dispatch.dispatch(issue.id, repo: @repo, start_driver: false)

  test "a card pinned to the scoped model is held, with the scoped window named" do
    ws = workspace!("claude-fable-5-1")
    seed_quota!(ws, exhausted_fable())
    issue = ready!(ws, "fable card")

    assert {:error, {:quota_held, _}} = dispatch(issue)
    assert Dispatch.quota_held_message(issue.id) =~ "7d (Fable)"
  end

  test "a card on another model is not held by the scoped window" do
    ws = workspace!("claude-opus-5-5")
    seed_quota!(ws, exhausted_fable())
    issue = ready!(ws, "opus card")

    assert {:ok, %{worker_pid: pid}} = dispatch(issue)
    assert is_pid(pid)
  end

  test "with no scoped limit the same Fable card dispatches" do
    ws = workspace!("claude-fable-5-1")
    seed_quota!(ws, [])
    issue = ready!(ws, "fable card, no scoped limit")

    assert {:ok, %{worker_pid: pid}} = dispatch(issue)
    assert is_pid(pid)
  end
end
