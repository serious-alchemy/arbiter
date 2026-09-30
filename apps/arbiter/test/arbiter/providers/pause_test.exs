defmodule Arbiter.Providers.PauseTest do
  @moduledoc """
  bd-5ef587: first-class pause/resume per provider and per provider account —
  the persisted flag every router consults.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Providers.Pause

  defp account!(provider, slug) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "#{slug}-#{System.unique_integer([:positive])}"
    })
  end

  test "nothing is paused by default" do
    acct = account!(:claude, "a")
    assert Pause.for_account(acct) == nil
    assert Pause.list() == []
    refute Pause.provider_paused?(:claude)
  end

  test "pausing a provider pauses every account on it, with who/when/why" do
    acct = account!(:codex, "a")
    other = account!(:claude, "b")

    assert {:ok, %{target: "codex", reason: "jail escape", by: "cli"}} =
             Pause.pause("codex", reason: "jail escape", by: "cli")

    assert %{reason: "jail escape", by: "cli", at: %DateTime{}} = Pause.for_account(acct)
    assert Pause.for_account(other) == nil
    assert Pause.provider_paused?(:codex)
    assert [%{target: "codex"}] = Pause.list()
  end

  test "pausing one account leaves siblings and the provider alone" do
    a = account!(:claude, "a")
    b = account!(:claude, "b")
    assert {:ok, %{target: target}} = Pause.pause(a.id, reason: "x", by: "mcp")
    assert target == "account:#{a.id}"
    assert Pause.for_account(a)
    assert Pause.for_account(b) == nil
    refute Pause.provider_paused?(:claude)
  end

  test "an account ref (provider:slug) resolves" do
    a = account!(:claude, "a")
    assert {:ok, %{target: t}} = Pause.pause("claude:#{a.slug}", reason: "x", by: "cli")
    assert t == "account:#{a.id}"
    assert {:ok, _} = Pause.resume("claude:#{a.slug}", by: "cli")
    assert Pause.for_account(a) == nil
  end

  test "resume clears it and is an error when nothing was paused" do
    assert {:ok, _} = Pause.pause("claude", reason: "x", by: "cli")
    assert {:ok, %{reason: "x"}} = Pause.resume("claude", by: "cli")
    refute Pause.provider_paused?(:claude)
    assert {:error, :not_paused} = Pause.resume("claude", by: "cli")
  end

  test "the gemini agent type maps to antigravity" do
    assert {:ok, _} = Pause.pause("antigravity", reason: "x", by: "cli")
    assert Pause.provider_paused?(:gemini)
    assert Pause.provider_paused?(:antigravity)
  end

  test "unknown refs are rejected" do
    assert {:error, :not_found} = Pause.pause("nope", reason: "x", by: "cli")
  end

  test "hold_phrase names the provider and reason" do
    assert {:ok, _} = Pause.pause("codex", reason: "bad", by: "cli")
    assert Pause.hold_phrase(:codex) == "held — codex paused: bad"
  end

  test "a paused provider is unhealthy, unavailable, and never picked by the pool" do
    assert Arbiter.Agents.ProviderPool.healthy?(:codex)
    assert {:ok, _} = Pause.pause("codex", reason: "x", by: "cli")
    refute Arbiter.Agents.ProviderPool.healthy?(:codex)
    refute Arbiter.Agents.provider_available?(:codex)
    assert Arbiter.Agents.ProviderPool.pick([:codex, :claude]) == :claude
    assert Arbiter.Agents.ProviderPool.pick([:codex]) == nil
  end

  test "pause and resume broadcast provider_paused / provider_resumed" do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "events:system")
    assert {:ok, _} = Pause.pause("claude", reason: "r", by: "cli")
    assert_receive {:event, %{topic: "provider_paused", target: "claude", reason: "r"}}
    assert {:ok, _} = Pause.resume("claude", by: "cli")
    assert_receive {:event, %{topic: "provider_resumed", target: "claude"}}
  end
end
