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

  test "ensure_unpaused refuses a provider- or account-paused pass with the hold phrase" do
    ws =
      Ash.create!(Arbiter.Tasks.Workspace, %{
        name: "pz-#{System.unique_integer([:positive])}",
        prefix: "pz#{System.unique_integer([:positive])}",
        config: %{}
      })

    alias Arbiter.Agents.ProviderRouting
    assert :ok = ProviderRouting.ensure_unpaused(:codex, ws.id)
    assert {:ok, _} = Pause.pause("codex", reason: "jail escape", by: "cli")

    assert {:error, {:provider_paused, :codex, "held — codex paused: jail escape"}} =
             ProviderRouting.ensure_unpaused(:codex, ws.id)

    assert :ok = ProviderRouting.ensure_unpaused(:claude, ws.id)
  end

  describe "quota holds — a pause that lifts itself (bd-a6vh2x)" do
    defp in_secs(n), do: DateTime.add(DateTime.utc_now(), n, :second)

    test "an account hold blocks that account until its reset, then is gone" do
      a = account!(:claude, "a")
      b = account!(:claude, "b")

      assert {:ok, %{target: target, until: until}} =
               Pause.quota_hold(:claude, a, in_secs(600), reason: "usage limit reached")

      assert target == "account:#{a.id}"
      assert DateTime.compare(until, DateTime.utc_now()) == :gt
      assert %{reason: "usage limit reached", kind: :quota} = Pause.for_account(a)
      assert Pause.for_account(b) == nil
      refute Pause.provider_paused?(:claude)
      assert [%{target: ^target, until: %DateTime{}}] = Pause.list()

      # Time passes: the same stored entry no longer blocks anything.
      {:ok, _} =
        Arbiter.Settings.set_provider_pauses(%{
          target => %{
            "reason" => "usage limit reached",
            "kind" => "quota",
            "until" => DateTime.to_iso8601(in_secs(-5)),
            "at" => DateTime.to_iso8601(in_secs(-600))
          }
        })

      assert Pause.for_account(a) == nil
      assert Pause.list() == []
    end

    test "providers/0 is derived from the agent registry and normalize accepts each" do
      assert "grok" in Pause.providers()
      assert "antigravity" in Pause.providers()

      for code <- Pause.providers(), do: assert(Pause.normalize(code) == code)
      assert {:ok, %{target: "grok"}} = Pause.pause("grok", reason: "x", by: "cli")
      assert Pause.provider_paused?(:grok)
      assert {:ok, _} = Pause.resume("grok")
      refute Pause.provider_paused?(:grok)
    end

    test "with no account the hold is provider-wide, and grok is a holdable provider" do
      assert {:ok, %{target: "antigravity"}} =
               Pause.quota_hold(:gemini, nil, in_secs(60), reason: "quota reached")

      assert Pause.provider_paused?(:gemini)

      assert {:ok, %{target: "grok"}} =
               Pause.quota_hold(:grok, nil, in_secs(60), reason: "free usage limit")

      assert Pause.provider_paused?(:grok)
    end

    test "an operator pause is never replaced or shortened by a quota hold" do
      a = account!(:claude, "a")
      assert {:ok, _} = Pause.pause(a.id, reason: "jail escape", by: "cli")

      assert {:ok, %{reason: "jail escape", until: nil}} =
               Pause.quota_hold(:claude, a, in_secs(60), reason: "usage limit reached")

      assert %{reason: "jail escape", until: nil} = Pause.for_account(a)
    end

    test "a second quota hold only ever extends the first" do
      a = account!(:claude, "a")
      assert {:ok, %{until: first}} = Pause.quota_hold(:claude, a, in_secs(3600), reason: "x")
      assert {:ok, %{until: kept}} = Pause.quota_hold(:claude, a, in_secs(60), reason: "y")
      assert DateTime.compare(kept, first) == :eq
      assert {:ok, %{until: later}} = Pause.quota_hold(:claude, a, in_secs(7200), reason: "z")
      assert DateTime.compare(later, first) == :gt
    end

    test "the operator can resume a quota hold early" do
      a = account!(:claude, "a")
      assert {:ok, _} = Pause.quota_hold(:claude, a, in_secs(3600), reason: "x")
      assert {:ok, _} = Pause.resume(a.id, by: "cli")
      assert Pause.for_account(a) == nil
    end

    test "to_json carries the reset time and the kind" do
      a = account!(:claude, "a")
      assert {:ok, _} = Pause.quota_hold(:claude, a, in_secs(3600), reason: "x")
      assert [%{"kind" => "quota", "until" => until}] = Pause.to_json()
      assert is_binary(until)
    end
  end
end
