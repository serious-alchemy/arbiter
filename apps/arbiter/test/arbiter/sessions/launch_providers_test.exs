defmodule Arbiter.Sessions.LaunchProvidersTest do
  @moduledoc """
  Which session providers the launch form offers, and which of those it greys
  out (bd-8qoxst): derived from the `:session_provider` registry, the provider
  accounts joined to the chosen workspace, the CLI on `PATH`, credential
  health (`AuthHold` / `CredentialWatchdog`) and, for a `:strict` workspace,
  write confinement.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Agents.{AuthHold, Claude, CredentialWatchdog, Gemini}
  alias Arbiter.Sessions.LaunchProviders
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.StopReason

  defp workspace!(name, config \\ %{}),
    do: Ash.create!(Workspace, %{name: name, prefix: "lp", config: config})

  defp account!(provider, slug, attrs \\ %{}),
    do: Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))

  # Both CLIs "installed" unless a test says otherwise.
  defp found(_name), do: "/usr/bin/true"

  defp opts(extra \\ []), do: Keyword.merge([find_executable: &found/1], extra)

  defp entry(entries, provider), do: Enum.find(entries, &(&1.provider == provider))

  # A private AuthHold + CredentialWatchdog pair, so nothing here touches the
  # application singletons (same shape as `Arbiter.Accounts.OverviewTest`).
  defp private_health do
    {:ok, watchdog} =
      start_supervised(%{
        id: make_ref(),
        start:
          {CredentialWatchdog, :start_link,
           [[name: nil, enabled: false, adapters: [Claude, Gemini]]]}
      })

    {:ok, hold} =
      start_supervised(%{
        id: make_ref(),
        start: {AuthHold, :start_link, [[name: nil, credential_watchdog: watchdog]]}
      })

    :ok = CredentialWatchdog.set_auth_hold(hold, watchdog)
    {hold, watchdog}
  end

  defp auth_reason do
    %StopReason{
      category: :auth_expired,
      summary: "API Error: 401",
      remediation: "Re-authenticate",
      exit_status: 1,
      signal: nil
    }
  end

  describe "list/2 — which providers are offered" do
    test "is derived from the registry: every registered provider with an account is offered" do
      account!(:claude, "lp-claude")
      account!(:antigravity, "lp-agy")

      providers = nil |> LaunchProviders.list(opts()) |> Enum.map(& &1.provider)

      assert providers == Enum.map(Arbiter.Sessions.Session.providers(), &Atom.to_string/1)
      assert "claude_code" in providers and "agy" in providers
    end

    test "a provider with no account is not listed" do
      account!(:claude, "lp-only-claude")

      assert [%{provider: "claude_code"}] = LaunchProviders.list(nil, opts())
    end

    test "a soft-deleted account does not count" do
      account!(:claude, "lp-live")
      gone = account!(:antigravity, "lp-gone")
      {:ok, _} = Accounts.delete_account(gone.id)

      assert [%{provider: "claude_code"}] = LaunchProviders.list(nil, opts())
    end

    test "a parked (disabled) account does not count" do
      account!(:claude, "lp-live")
      account!(:antigravity, "lp-parked", %{enabled: false})

      assert [%{provider: "claude_code"}] = LaunchProviders.list(nil, opts())
    end

    test "for a workspace, the account must be joined to that workspace" do
      ws = workspace!("lp-joined")
      other = workspace!("lp-other")
      claude = account!(:claude, "lp-claude")
      agy = account!(:antigravity, "lp-agy")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, claude.id)
      {:ok, _} = Accounts.attach_workspace(other.id, :antigravity, agy.id)

      assert [%{provider: "claude_code"}] = LaunchProviders.list(ws.id, opts())
      assert [%{provider: "agy"}] = LaunchProviders.list(other.id, opts())
    end

    test "a provider whose CLI is not on this host is not listed" do
      account!(:claude, "lp-claude")
      account!(:antigravity, "lp-agy")

      finder = fn
        "agy" -> nil
        _ -> "/usr/bin/true"
      end

      assert [%{provider: "claude_code"}] =
               LaunchProviders.list(nil, opts(find_executable: finder))
    end

    test "nothing is listed on an install with no accounts" do
      assert LaunchProviders.list(nil, opts()) == []
    end
  end

  describe "list/2 — which offered providers are disabled, and why" do
    test "a healthy provider is enabled with no reason" do
      account!(:claude, "lp-claude")

      assert [%{provider: "claude_code", disabled?: false, reason: nil, label: label}] =
               LaunchProviders.list(nil, opts())

      assert label == "Claude Code"
    end

    test "an open auth hold disables the provider and says so" do
      account!(:claude, "lp-claude")
      account!(:antigravity, "lp-agy")
      {hold, watchdog} = private_health()
      :counted = AuthHold.record_death(Claude, auth_reason(), hold)
      :opened = AuthHold.record_death(Claude, auth_reason(), hold)

      entries = LaunchProviders.list(nil, opts(auth_hold: hold, watchdog: watchdog))

      assert %{disabled?: true, reason: reason} = entry(entries, "claude_code")
      assert reason =~ "auth hold"
      assert %{disabled?: false} = entry(entries, "agy")
    end

    test "a credential-watchdog expiry disables the provider and says so" do
      account!(:antigravity, "lp-agy")
      {hold, watchdog} = private_health()
      CredentialWatchdog.mark_expired(Gemini, auth_reason(), watchdog, :periodic_probe)

      assert [%{provider: "agy", disabled?: true, reason: reason}] =
               LaunchProviders.list(nil, opts(auth_hold: hold, watchdog: watchdog))

      assert reason =~ "expired"
    end

    test "agy in a :strict workspace is disabled when write confinement is :none" do
      ws =
        workspace!("lp-strict", %{
          "agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}
        })

      claude = account!(:claude, "lp-claude")
      agy = account!(:antigravity, "lp-agy")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, claude.id)
      {:ok, _} = Accounts.attach_workspace(ws.id, :antigravity, agy.id)

      confinement = fn
        Gemini, _policy -> :none
        _adapter, _policy -> :permission_layer
      end

      entries = LaunchProviders.list(ws.id, opts(write_confinement: confinement))

      assert %{disabled?: true, reason: reason} = entry(entries, "agy")
      assert reason =~ "strict"
      assert %{disabled?: false} = entry(entries, "claude_code")
    end

    test "write confinement is not asked of a non-strict workspace" do
      ws = workspace!("lp-lax")
      agy = account!(:antigravity, "lp-agy")
      {:ok, _} = Accounts.attach_workspace(ws.id, :antigravity, agy.id)

      assert [%{provider: "agy", disabled?: false}] =
               LaunchProviders.list(ws.id, opts(write_confinement: fn _, _ -> :none end))
    end
  end

  describe "default/1 and selectable?/3" do
    test "default is claude_code when it is enabled, else the first enabled provider" do
      claude = %{provider: "claude_code", disabled?: false}
      agy = %{provider: "agy", disabled?: false}

      assert LaunchProviders.default([claude, agy]) == "claude_code"
      assert LaunchProviders.default([%{claude | disabled?: true}, agy]) == "agy"
      assert LaunchProviders.default([%{claude | disabled?: true}]) == nil
      assert LaunchProviders.default([]) == nil
    end

    test "only an enabled, listed provider is selectable" do
      account!(:claude, "lp-claude")

      assert LaunchProviders.selectable?("claude_code", nil, opts())
      refute LaunchProviders.selectable?("agy", nil, opts())
      refute LaunchProviders.selectable?("not_a_provider", nil, opts())
      refute LaunchProviders.selectable?(nil, nil, opts())
    end
  end
end
