defmodule Arbiter.AccountsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota, GoogleQuota, Rekey}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event

  require Ash.Query

  defp create_workspace!(name) do
    {:ok, ws} = Ash.create(Workspace, %{name: name, prefix: "ac"})
    ws
  end

  defp create_account!(attrs) do
    {:ok, account} = Ash.create(ProviderAccount, attrs)
    account
  end

  defp create_anthropic_quota!(account_id, attrs \\ []) do
    base = %{
      provider_account_id: account_id,
      provider: "claude",
      captured_at: DateTime.utc_now()
    }

    {:ok, quota} =
      Ash.create(AnthropicQuota, Map.merge(base, Map.new(attrs)), action: :record_oauth_snapshot)

    quota
  end

  defp create_codex_quota!(account_id, attrs) do
    base = %{
      provider_account_id: account_id,
      provider: "codex",
      captured_at: DateTime.utc_now()
    }

    {:ok, quota} = Ash.create(CodexQuota, Map.merge(base, Map.new(attrs)), action: :upsert)
    quota
  end

  defp create_cloud_code_quota!(account_id, provider, attrs) do
    base = %{
      provider_account_id: account_id,
      provider: provider,
      captured_at: DateTime.utc_now()
    }

    {:ok, quota} = Ash.create(GoogleQuota, Map.merge(base, Map.new(attrs)), action: :upsert)
    quota
  end

  defp create_event!(attrs) do
    base = %{
      task_id: "bd-acct-#{System.unique_integer([:positive])}",
      source: :task,
      repo: "arbiter",
      workspace_id: "ws-acct",
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "list_accounts/1" do
    test "lists accounts sorted by provider then slug, excluding merged-away rows" do
      create_account!(%{provider: :claude, slug: "b-account"})
      create_account!(%{provider: :claude, slug: "a-account"})
      merged = create_account!(%{provider: :claude, slug: "merged-away"})
      into = create_account!(%{provider: :claude, slug: "survivor"})

      merged
      |> Ash.Changeset.for_update(:update, %{merged_into_id: into.id, enabled: false})
      |> Ash.update!()

      slugs = Accounts.list_accounts() |> Enum.map(& &1.slug)

      assert slugs == ["a-account", "b-account", "survivor"]
    end

    test "filters by provider" do
      create_account!(%{provider: :claude, slug: "only-claude"})
      create_account!(%{provider: :codex, slug: "only-codex"})

      assert [%{slug: "only-claude"}] = Accounts.list_accounts(provider: :claude)
    end

    test "include_merged: true also returns merged-away rows" do
      into = create_account!(%{provider: :claude, slug: "include-merged-survivor"})
      merged = create_account!(%{provider: :claude, slug: "include-merged-away"})

      merged
      |> Ash.Changeset.for_update(:update, %{merged_into_id: into.id, enabled: false})
      |> Ash.update!()

      slugs = Accounts.list_accounts(include_merged: true) |> Enum.map(& &1.slug)

      assert "include-merged-away" in slugs
      assert "include-merged-survivor" in slugs
    end
  end

  describe "get_account/1" do
    test "resolves by uuid id" do
      account = create_account!(%{provider: :claude, slug: "by-id"})
      assert {:ok, found} = Accounts.get_account(account.id)
      assert found.id == account.id
    end

    test "resolves by provider:slug" do
      create_account!(%{provider: :claude, slug: "shared"})
      codex = create_account!(%{provider: :codex, slug: "shared"})

      assert {:ok, found} = Accounts.get_account("codex:shared")
      assert found.id == codex.id
    end

    test "a 16-character ref is not mistaken for a raw UUID" do
      # `Ecto.UUID.cast/1` accepts a raw 16-*byte* binary as well as the
      # 36-character hyphenated form, so any ref that happens to be exactly 16
      # characters long ("claude:ceil-refs", "sixteen-char-abc") used to be
      # routed to the id lookup and 404 — including from `arb account set`.
      account = create_account!(%{provider: :claude, slug: "ceil-refs"})
      assert byte_size("claude:ceil-refs") == 16

      assert {:ok, found} = Accounts.get_account("claude:ceil-refs")
      assert found.id == account.id

      bare = create_account!(%{provider: :codex, slug: "sixteen-char-abc"})
      assert byte_size("sixteen-char-abc") == 16
      assert {:ok, found} = Accounts.get_account("sixteen-char-abc")
      assert found.id == bare.id
    end

    test "resolves an unambiguous bare slug" do
      account = create_account!(%{provider: :claude, slug: "unique-slug"})
      assert {:ok, found} = Accounts.get_account("unique-slug")
      assert found.id == account.id
    end

    test "a bare slug shared across providers is ambiguous" do
      create_account!(%{provider: :claude, slug: "dup"})
      create_account!(%{provider: :codex, slug: "dup"})

      assert {:error, :ambiguous} = Accounts.get_account("dup")
    end

    test "unknown ref is not found" do
      assert {:error, :not_found} = Accounts.get_account("nope")
    end
  end

  describe "create_account/1" do
    test "creates a new account with no credential required" do
      assert {:ok, account} = Accounts.create_account(%{provider: :claude, slug: "fresh"})
      assert account.provider == :claude
      assert account.slug == "fresh"
      assert account.enabled == true
    end

    # bd-ac53wz: the upstream Gemini CLI provider is dropped; agy stays.
    test "rejects the removed gemini_cli provider" do
      assert {:error, _} = Accounts.create_account(%{provider: :gemini_cli, slug: "gone"})

      assert {:error, _} =
               Ash.create(ProviderAccount, %{provider: :gemini_cli, slug: "gone-too"})

      assert {:ok, %{provider: :antigravity}} =
               Accounts.create_account(%{provider: :antigravity, slug: "agy-stays"})
    end
  end

  describe "parse_provider/1" do
    test "knows every live provider and not the removed gemini_cli (bd-ac53wz)" do
      for p <- ~w(claude codex antigravity),
          do: assert(Accounts.parse_provider(p) == {:ok, String.to_existing_atom(p)})

      assert Accounts.parse_provider("gemini_cli") == :error
    end
  end

  describe "set_max_concurrent/2 (P8 §4.2)" do
    test "sets the ceiling by slug" do
      create_account!(%{provider: :claude, slug: "ceil-set"})

      assert {:ok, account} = Accounts.set_max_concurrent("ceil-set", 4)
      assert account.max_concurrent == 4
    end

    test "nil clears it — the ceiling is opt-in (§4.4)" do
      create_account!(%{provider: :claude, slug: "ceil-clear", max_concurrent: 4})

      assert {:ok, account} = Accounts.set_max_concurrent("ceil-clear", nil)
      assert account.max_concurrent == nil
    end

    test "resolves the same refs every other verb does" do
      account = create_account!(%{provider: :claude, slug: "ceil-refs"})

      assert {:ok, _} = Accounts.set_max_concurrent(account.id, 1)
      assert {:ok, _} = Accounts.set_max_concurrent("claude:ceil-refs", 2)
      assert {:error, :not_found} = Accounts.set_max_concurrent("no-such-account", 2)
    end
  end

  describe "set_quota_config/2 (bd-c7ll4t)" do
    test "sets threshold_mode" do
      create_account!(%{provider: :claude, slug: "policy-set"})

      assert {:ok, account} =
               Accounts.set_quota_config("policy-set", %{"threshold_mode" => "paced"})

      assert account.quota_config["threshold_mode"] == "paced"
    end

    test "merges into the existing quota_config rather than replacing it" do
      create_account!(%{
        provider: :claude,
        slug: "policy-merge",
        quota_config: %{"throttle_threshold" => 0.8}
      })

      assert {:ok, account} =
               Accounts.set_quota_config("policy-merge", %{"weekly_threshold" => 0.95})

      assert account.quota_config["weekly_threshold"] == 0.95
      assert account.quota_config["throttle_threshold"] == 0.8
    end

    test "rejects an invalid threshold_mode without writing anything" do
      account = create_account!(%{provider: :claude, slug: "policy-bad-mode"})

      assert {:error, {:invalid_quota_config, _}} =
               Accounts.set_quota_config("policy-bad-mode", %{"threshold_mode" => "bogus"})

      assert {:ok, unchanged} = Accounts.get_account(account.id)
      assert unchanged.quota_config == %{}
    end

    test "rejects an out-of-range float" do
      create_account!(%{provider: :claude, slug: "policy-bad-float"})

      assert {:error, {:invalid_quota_config, _}} =
               Accounts.set_quota_config("policy-bad-float", %{"weekly_threshold" => 1.5})
    end

    test "rejects an unknown key" do
      create_account!(%{provider: :claude, slug: "policy-bad-key"})

      assert {:error, {:invalid_quota_config, _}} =
               Accounts.set_quota_config("policy-bad-key", %{"not_a_real_key" => "x"})
    end

    test "resolves the same refs every other verb does" do
      account = create_account!(%{provider: :claude, slug: "policy-refs"})

      assert {:ok, _} =
               Accounts.set_quota_config(account.id, %{"threshold_mode" => "paced"})

      assert {:ok, _} =
               Accounts.set_quota_config("claude:policy-refs", %{"threshold_mode" => "flat"})

      assert {:error, :not_found} =
               Accounts.set_quota_config("no-such-account", %{"threshold_mode" => "flat"})
    end
  end

  describe "set_quota_config/2 — a nil value clears the key (bd-8vkqd3)" do
    test "drops only the named key, leaving siblings alone" do
      create_account!(%{
        provider: :claude,
        slug: "policy-clear",
        quota_config: %{
          "weekly_threshold" => 0.8,
          "paced_floor" => 0.3,
          "throttle_threshold" => 0.7
        }
      })

      assert {:ok, account} =
               Accounts.set_quota_config("policy-clear", %{
                 "weekly_threshold" => nil,
                 "threshold_mode" => "paced"
               })

      refute Map.has_key?(account.quota_config, "weekly_threshold")
      assert account.quota_config["paced_floor"] == 0.3
      assert account.quota_config["throttle_threshold"] == 0.7
      assert account.quota_config["threshold_mode"] == "paced"
    end

    test "clearing a key that is not set is a no-op, not an error" do
      create_account!(%{provider: :claude, slug: "policy-clear-unset"})

      assert {:ok, account} =
               Accounts.set_quota_config("policy-clear-unset", %{"paced_floor" => nil})

      assert account.quota_config == %{}
    end

    test "an unknown key is still rejected even when nil" do
      create_account!(%{provider: :claude, slug: "policy-clear-bad"})

      assert {:error, {:invalid_quota_config, _}} =
               Accounts.set_quota_config("policy-clear-bad", %{"nope" => nil})
    end
  end

  describe "update_account/2 (bd-8vkqd3)" do
    test "sets label, plan and enabled; the identity and cap are untouched" do
      create_account!(%{provider: :claude, slug: "upd-all", max_concurrent: 3})

      assert {:ok, account} =
               Accounts.update_account("upd-all", %{
                 "label" => "Work Max",
                 "plan" => "max_20x",
                 "enabled" => false
               })

      assert account.label == "Work Max"
      assert account.plan == "max_20x"
      assert account.enabled == false
      assert account.slug == "upd-all"
      assert account.max_concurrent == 3
    end

    test "only the given keys change" do
      create_account!(%{provider: :claude, slug: "upd-part", label: "Keep", plan: "pro"})

      assert {:ok, account} = Accounts.update_account("upd-part", %{"plan" => "team"})
      assert account.label == "Keep"
      assert account.plan == "team"
      assert account.enabled == true
    end

    test "a blank label or plan clears it" do
      create_account!(%{provider: :claude, slug: "upd-blank", label: "L", plan: "pro"})

      assert {:ok, account} = Accounts.update_account("upd-blank", %{label: "  ", plan: nil})
      assert account.label == nil
      assert account.plan == nil
    end

    test "accepts atom keys and the string forms of enabled" do
      create_account!(%{provider: :claude, slug: "upd-forms"})

      assert {:ok, %{enabled: false}} = Accounts.update_account("upd-forms", %{enabled: "false"})

      assert {:ok, %{enabled: true}} =
               Accounts.update_account("upd-forms", %{"enabled" => "true"})
    end

    test "rejects a non-boolean enabled and an unknown key without writing" do
      create_account!(%{provider: :claude, slug: "upd-bad", label: "Before"})

      assert {:error, {:invalid_account, msg}} =
               Accounts.update_account("upd-bad", %{"enabled" => "maybe", "label" => "After"})

      assert msg =~ "enabled"

      assert {:error, {:invalid_account, msg}} =
               Accounts.update_account("upd-bad", %{"slug" => "renamed"})

      assert msg =~ "slug"
      assert {:ok, %{label: "Before", slug: "upd-bad"}} = Accounts.get_account("upd-bad")
    end

    test "resolves the same refs every other verb does" do
      account = create_account!(%{provider: :claude, slug: "upd-refs"})

      assert {:ok, _} = Accounts.update_account(account.id, %{"label" => "a"})
      assert {:ok, _} = Accounts.update_account("claude:upd-refs", %{"label" => "b"})
      assert {:error, :not_found} = Accounts.update_account("no-such-account", %{"label" => "c"})
    end
  end

  describe "share is a cap, not a reservation (§4.3)" do
    test "shares may sum to more than the account ceiling" do
      account = create_account!(%{provider: :claude, slug: "oversubscribed", max_concurrent: 4})

      # 3 + 3 + 3 = 9 against a ceiling of 4. Deliberately allowed: it lets a
      # quiet workspace's slots be taken by a busy one while still bounding
      # any single workspace. A reservation would have to reject this.
      for name <- ~w(over-a over-b over-c) do
        ws = create_workspace!(name)
        assert {:ok, link} = Accounts.attach_workspace(ws.id, :claude, account.id, share: 3)
        assert link.share == 3
      end

      {:ok, reloaded} = Accounts.get_account(account.id)
      assert reloaded.max_concurrent == 4
      assert length(Arbiter.Accounts.Resolver.workspace_ids(account.id)) == 3
    end
  end

  describe "attach_workspace/4" do
    test "creates a workspace_provider_accounts row" do
      ws = create_workspace!("attach-ws-1")
      account = create_account!(%{provider: :claude, slug: "attach-acct"})

      assert {:ok, link} = Accounts.attach_workspace(ws.id, :claude, account.id, share: 2)
      assert link.workspace_id == ws.id
      assert link.provider == :claude
      assert link.provider_account_id == account.id
      assert link.share == 2
    end

    test "re-attaching the same workspace+provider updates the existing row" do
      ws = create_workspace!("attach-ws-2")
      account_a = create_account!(%{provider: :claude, slug: "attach-a"})
      account_b = create_account!(%{provider: :claude, slug: "attach-b"})

      assert {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account_a.id)
      assert {:ok, updated} = Accounts.attach_workspace(ws.id, :claude, account_b.id, share: 5)

      assert updated.provider_account_id == account_b.id
      assert updated.share == 5

      assert [_one] =
               WorkspaceProviderAccount
               |> Ash.Query.filter(workspace_id == ^ws.id and provider == :claude)
               |> Ash.read!()
    end

    test "rejects attaching to an account of a different provider" do
      ws = create_workspace!("attach-ws-3")
      account = create_account!(%{provider: :codex, slug: "codex-only"})

      assert {:error, {:provider_mismatch, :codex}} =
               Accounts.attach_workspace(ws.id, :claude, account.id)
    end

    test "a non-uuid workspace-id is rejected with a plain error tuple, not a raise" do
      account = create_account!(%{provider: :claude, slug: "attach-bad-ws"})

      assert {:error, :not_found} =
               Accounts.attach_workspace("ws-does-not-exist", :claude, account.id)
    end

    test "rejects attaching to an account that has been merged away" do
      ws = create_workspace!("attach-ws-merged")
      from_account = create_account!(%{provider: :claude, slug: "attach-merge-from"})
      into_account = create_account!(%{provider: :claude, slug: "attach-merge-into"})

      assert {:ok, _} = Accounts.merge_accounts(from_account.id, into_account.id)

      assert {:error, {:merged_away, survivor_id}} =
               Accounts.attach_workspace(ws.id, :claude, from_account.id)

      assert survivor_id == into_account.id
    end

    test "rejects attaching to an account that has been soft-deleted" do
      ws = create_workspace!("attach-ws-deleted")
      account = create_account!(%{provider: :claude, slug: "attach-deleted"})
      assert {:ok, _} = Accounts.delete_account(account.id)

      assert {:error, :already_deleted} = Accounts.attach_workspace(ws.id, :claude, account.id)
    end
  end

  describe "detach_workspace/2" do
    test "deletes the workspace's link to the account for the account's provider" do
      ws = create_workspace!("detach-ws-1")
      account = create_account!(%{provider: :claude, slug: "detach-acct"})
      {:ok, link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      assert {:ok, detached} = Accounts.detach_workspace(ws.id, "claude:detach-acct")
      assert detached.id == link.id

      assert [] =
               WorkspaceProviderAccount
               |> Ash.Query.filter(workspace_id == ^ws.id)
               |> Ash.read!()
    end

    test "leaves the workspace's links for other providers alone" do
      ws = create_workspace!("detach-ws-2")
      claude = create_account!(%{provider: :claude, slug: "detach-claude"})
      codex = create_account!(%{provider: :codex, slug: "detach-codex"})
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, claude.id)
      {:ok, codex_link} = Accounts.attach_workspace(ws.id, :codex, codex.id)

      assert {:ok, _} = Accounts.detach_workspace(ws.id, claude.id)

      assert [%{id: id}] =
               WorkspaceProviderAccount
               |> Ash.Query.filter(workspace_id == ^ws.id)
               |> Ash.read!()

      assert id == codex_link.id
    end

    test "refuses to delete a link that points at a different account" do
      ws = create_workspace!("detach-ws-3")
      a = create_account!(%{provider: :claude, slug: "detach-a"})
      b = create_account!(%{provider: :claude, slug: "detach-b"})
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, b.id)

      assert {:error, :not_attached} = Accounts.detach_workspace(ws.id, a.id)
      assert Arbiter.Accounts.Resolver.account_id(ws.id, :claude) == b.id
    end

    test "an unattached workspace or unknown account is a plain error tuple" do
      ws = create_workspace!("detach-ws-4")
      account = create_account!(%{provider: :claude, slug: "detach-none"})

      assert {:error, :not_attached} = Accounts.detach_workspace(ws.id, account.id)
      assert {:error, :not_found} = Accounts.detach_workspace(ws.id, "claude:nope")
      assert {:error, :not_found} = Accounts.detach_workspace("ws-does-not-exist", account.id)
    end
  end

  describe "rotate_credential/2" do
    test "inserts a new active credential and retires the previous one, never returning the secret in a loggable form" do
      account = create_account!(%{provider: :claude, slug: "rotate-acct"})

      assert {:ok, first} =
               Accounts.rotate_credential(account.id, %{
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 secret: "sk-first-secret"
               })

      assert first.active == true

      assert {:ok, second} =
               Accounts.rotate_credential(account.id, %{
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 secret: "sk-second-secret"
               })

      assert second.active == true
      assert second.id != first.id

      {:ok, reloaded_first} = Ash.get(ProviderCredential, first.id)
      assert reloaded_first.active == false
      assert reloaded_first.retired_at != nil

      # The struct never carries the plaintext secret back out.
      refute Map.has_key?(second, :secret) and is_binary(Map.get(second, :secret))
      inspected = inspect(second)
      refute inspected =~ "sk-first-secret"
      refute inspected =~ "sk-second-secret"
    end

    test "rotating a different kind does not retire the other kind's active credential" do
      account = create_account!(%{provider: :claude, slug: "rotate-multi-kind"})

      {:ok, oauth} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-oauth"
        })

      {:ok, _api_key} =
        Accounts.rotate_credential(account.id, %{
          kind: :api_key,
          env_var: "ANTHROPIC_API_KEY",
          secret: "sk-api-key"
        })

      {:ok, reloaded_oauth} = Ash.get(ProviderCredential, oauth.id)
      assert reloaded_oauth.active == true
    end

    test "an unrecognised kind is rejected with a plain error tuple, not a raise" do
      account = create_account!(%{provider: :claude, slug: "rotate-bad-kind"})

      assert {:error, {:invalid_kind, "not_a_kind"}} =
               Accounts.rotate_credential(account.id, %{
                 kind: "not_a_kind",
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 secret: "sk-secret"
               })
    end

    test "persists scopes passed with string keys — the only shape the CLI/controller send" do
      account = create_account!(%{provider: :claude, slug: "rotate-scopes-string-keys"})

      assert {:ok, credential} =
               Accounts.rotate_credential(account.id, %{
                 "kind" => "oauth_token",
                 "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
                 "secret" => "sk-scoped-secret",
                 "scopes" => ["user:inference", "user:profile"]
               })

      assert credential.scopes == ["user:inference", "user:profile"]
    end

    test "rejects rotating a credential on an account that has been merged away" do
      from_account = create_account!(%{provider: :claude, slug: "rotate-merge-from"})
      into_account = create_account!(%{provider: :claude, slug: "rotate-merge-into"})

      assert {:ok, _} = Accounts.merge_accounts(from_account.id, into_account.id)

      assert {:error, {:merged_away, survivor_id}} =
               Accounts.rotate_credential(from_account.id, %{
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 secret: "sk-should-not-be-written"
               })

      assert survivor_id == into_account.id
    end

    test "rejects rotating a credential on an account that has been soft-deleted" do
      account = create_account!(%{provider: :claude, slug: "rotate-deleted"})
      assert {:ok, _} = Accounts.delete_account(account.id)

      assert {:error, :already_deleted} =
               Accounts.rotate_credential(account.id, %{
                 kind: :oauth_token,
                 env_var: "CLAUDE_CODE_OAUTH_TOKEN",
                 secret: "sk-should-not-be-written"
               })
    end
  end

  describe "merge_accounts/2 — §2.5 end-to-end" do
    setup do
      from_account = create_account!(%{provider: :claude, slug: "merge-from"})
      into_account = create_account!(%{provider: :claude, slug: "merge-into"})

      ws_from = create_workspace!("merge-ws-from")
      ws_into = create_workspace!("merge-ws-into")

      {:ok, _} = Accounts.attach_workspace(ws_from.id, :claude, from_account.id)
      {:ok, _} = Accounts.attach_workspace(ws_into.id, :claude, into_account.id)

      {:ok, from_cred} =
        Accounts.rotate_credential(from_account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-from-secret"
        })

      event_from =
        create_event!(%{
          provider_account_id: from_account.id,
          provider_credential_id: from_cred.id,
          cost_usd: 3.00,
          occurred_at: ~U[2026-01-01 00:00:00Z]
        })

      event_into =
        create_event!(%{
          provider_account_id: into_account.id,
          cost_usd: 5.00,
          occurred_at: ~U[2026-01-02 00:00:00Z]
        })

      %{
        from_account: from_account,
        into_account: into_account,
        ws_from: ws_from,
        ws_into: ws_into,
        from_cred: from_cred,
        event_from: event_from,
        event_into: event_into
      }
    end

    test "re-points usage_events, moves credentials distinctly, re-points workspace links, and soft-deletes the from row",
         %{
           from_account: from_account,
           into_account: into_account,
           ws_from: ws_from,
           ws_into: ws_into,
           from_cred: from_cred,
           event_from: event_from
         } do
      assert {:ok, result} = Accounts.merge_accounts(from_account.id, into_account.id)
      assert result.id == into_account.id

      # usage_events re-pointed from -> into
      {:ok, reloaded_event} = Ash.get(Event, event_from.id)
      assert reloaded_event.provider_account_id == into_account.id

      # provider_credentials moved across, staying distinct rows
      {:ok, reloaded_cred} = Ash.get(ProviderCredential, from_cred.id)
      assert reloaded_cred.provider_account_id == into_account.id

      # workspace_provider_accounts re-pointed
      {:ok, link_from} =
        WorkspaceProviderAccount
        |> Ash.Query.filter(workspace_id == ^ws_from.id and provider == :claude)
        |> Ash.read_one()

      assert link_from.provider_account_id == into_account.id

      {:ok, link_into} =
        WorkspaceProviderAccount
        |> Ash.Query.filter(workspace_id == ^ws_into.id and provider == :claude)
        |> Ash.read_one()

      assert link_into.provider_account_id == into_account.id

      # the from row is soft-deleted with merged_into_id set
      {:ok, reloaded_from} = Ash.get(ProviderAccount, from_account.id)
      assert reloaded_from.merged_into_id == into_account.id
      assert reloaded_from.enabled == false
    end

    test "historical usage_events cost rollups become correct retroactively, from a plain read-time aggregation",
         %{from_account: from_account, into_account: into_account} do
      # Before the merge: each account's own total only sees its own events.
      before_from = sum_cost(from_account.id)
      before_into = sum_cost(into_account.id)
      assert_in_delta before_from, 3.00, 0.001
      assert_in_delta before_into, 5.00, 0.001

      assert {:ok, _} = Accounts.merge_accounts(from_account.id, into_account.id)

      # After the merge: a plain read-time sum over usage_events for the
      # surviving account id now sees both, with no re-derivation step and no
      # stored rollup involved.
      after_into = sum_cost(into_account.id)
      assert_in_delta after_into, 8.00, 0.001
    end

    test "rejects merging accounts of different providers" do
      other = create_account!(%{provider: :codex, slug: "codex-other"})
      claude_account = create_account!(%{provider: :claude, slug: "claude-solo"})

      assert {:error, :provider_mismatch} = Accounts.merge_accounts(claude_account.id, other.id)
    end

    test "rejects merging an account into itself", %{from_account: from_account} do
      assert {:error, :same_account} = Accounts.merge_accounts(from_account.id, from_account.id)
    end

    test "rejects a merge before touching anything when the into ref does not resolve",
         %{from_account: from_account} do
      assert {:error, :not_found} = Accounts.merge_accounts(from_account.id, "does-not-exist")

      before = sum_cost(from_account.id)
      assert_in_delta before, 3.00, 0.001

      {:ok, reloaded_from} = Ash.get(ProviderAccount, from_account.id)
      assert reloaded_from.merged_into_id == nil
      assert reloaded_from.enabled == true
    end

    test "is transactional: an error midway through the transaction rolls back every table",
         %{
           from_account: from_account,
           into_account: into_account,
           ws_from: ws_from,
           from_cred: from_cred,
           event_from: event_from
         } do
      # Both accounts hold a quota row, so the merge's quota-collapse step
      # (which runs after usage_events and provider_credentials have already
      # been re-pointed inside the same transaction) actually executes.
      create_anthropic_quota!(from_account.id)
      create_anthropic_quota!(into_account.id)

      # Inject a real failure *inside* the transaction, past the two steps
      # that already ran — proving all-or-nothing, not just the up-front
      # ref-resolution guard.
      :meck.new(Rekey, [:passthrough])
      :meck.expect(Rekey, :collapse_anthropic, fn _rows -> raise "injected mid-merge failure" end)

      try do
        assert {:error, _reason} = Accounts.merge_accounts(from_account.id, into_account.id)
      after
        :meck.unload(Rekey)
      end

      # usage_events: still pointed at from
      {:ok, reloaded_event} = Ash.get(Event, event_from.id)
      assert reloaded_event.provider_account_id == from_account.id

      # provider_credentials: still owned by from
      {:ok, reloaded_cred} = Ash.get(ProviderCredential, from_cred.id)
      assert reloaded_cred.provider_account_id == from_account.id

      # anthropic_quotas: both rows survive, uncollapsed
      quota_rows =
        AnthropicQuota
        |> Ash.Query.filter(provider_account_id in [^from_account.id, ^into_account.id])
        |> Ash.read!()

      assert length(quota_rows) == 2

      # workspace_provider_accounts: still pointed at from
      {:ok, link_from} =
        WorkspaceProviderAccount
        |> Ash.Query.filter(workspace_id == ^ws_from.id and provider == :claude)
        |> Ash.read_one()

      assert link_from.provider_account_id == from_account.id

      # the from row: not soft-deleted
      {:ok, reloaded_from} = Ash.get(ProviderAccount, from_account.id)
      assert reloaded_from.merged_into_id == nil
      assert reloaded_from.enabled == true
    end

    test "rejects merging an already-merged-away account", %{
      from_account: from_account,
      into_account: into_account
    } do
      other = create_account!(%{provider: :claude, slug: "merge-probe-other"})
      assert {:ok, _} = Accounts.merge_accounts(from_account.id, into_account.id)

      # from_account is now merged away — merging it again must be rejected,
      # not silently re-point live data off a disabled row.
      assert {:error, :already_merged} = Accounts.merge_accounts(from_account.id, other.id)
    end

    test "rejects merging into an already-merged-away account", %{
      from_account: from_account,
      into_account: into_account
    } do
      other = create_account!(%{provider: :claude, slug: "merge-probe-other-2"})
      assert {:ok, _} = Accounts.merge_accounts(from_account.id, into_account.id)

      assert {:error, :into_already_merged} =
               Accounts.merge_accounts(other.id, from_account.id)
    end

    test "rejects merging a soft-deleted account into another one" do
      deleted = create_account!(%{provider: :claude, slug: "merge-from-deleted"})
      other = create_account!(%{provider: :claude, slug: "merge-from-deleted-into"})
      assert {:ok, _} = Accounts.delete_account(deleted.id)

      assert {:error, :already_deleted} = Accounts.merge_accounts(deleted.id, other.id)
    end

    test "rejects merging another account into a soft-deleted account" do
      other = create_account!(%{provider: :claude, slug: "merge-into-deleted-from"})
      deleted = create_account!(%{provider: :claude, slug: "merge-into-deleted"})
      assert {:ok, _} = Accounts.delete_account(deleted.id)

      assert {:error, :already_deleted} = Accounts.merge_accounts(other.id, deleted.id)
    end

    test "re-points a stale merge chain onto the current survivor", %{
      from_account: from_account,
      into_account: into_account
    } do
      third = create_account!(%{provider: :claude, slug: "merge-chain-third"})

      # a -> from_account, then from_account -> into_account (third -> into).
      assert {:ok, _} = Accounts.merge_accounts(third.id, from_account.id)
      assert {:ok, _} = Accounts.merge_accounts(from_account.id, into_account.id)

      {:ok, reloaded_third} = Ash.get(ProviderAccount, third.id)
      assert reloaded_third.merged_into_id == into_account.id
    end
  end

  describe "merge_accounts/2 — quota collapse (§6)" do
    test "anthropic_quotas: collapses per column group, header cols from the newest captured_at, oauth cols from the newest oauth_captured_at" do
      from = create_account!(%{provider: :claude, slug: "quota-merge-from"})
      into = create_account!(%{provider: :claude, slug: "quota-merge-into"})

      # `from` has the fresher oauth block but the staler header.
      create_anthropic_quota!(from.id,
        captured_at: ~U[2026-01-01 00:00:00Z],
        utilization_5h: 0.1,
        oauth_captured_at: ~U[2026-01-05 00:00:00Z],
        oauth_utilization_5h: 0.9
      )

      create_anthropic_quota!(into.id,
        captured_at: ~U[2026-01-03 00:00:00Z],
        utilization_5h: 0.5,
        oauth_captured_at: ~U[2026-01-02 00:00:00Z],
        oauth_utilization_5h: 0.2
      )

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               AnthropicQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "claude")
               |> Ash.read_one()

      # header columns come from the newest `captured_at` row (into's)
      assert_in_delta merged.utilization_5h, 0.5, 0.001
      assert DateTime.compare(merged.captured_at, ~U[2026-01-03 00:00:00Z]) == :eq

      # oauth columns come from the newest `oauth_captured_at` row (from's)
      assert_in_delta merged.oauth_utilization_5h, 0.9, 0.001
      assert DateTime.compare(merged.oauth_captured_at, ~U[2026-01-05 00:00:00Z]) == :eq

      # exactly one row survives on (into.id, "claude")
      assert [_one] =
               AnthropicQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "claude")
               |> Ash.read!()
    end

    test "codex_quotas: collapses to the single newest row" do
      from = create_account!(%{provider: :codex, slug: "codex-merge-from"})
      into = create_account!(%{provider: :codex, slug: "codex-merge-into"})

      create_codex_quota!(from.id, captured_at: ~U[2026-01-05 00:00:00Z], plan: "from-plan")
      create_codex_quota!(into.id, captured_at: ~U[2026-01-01 00:00:00Z], plan: "into-plan")

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               CodexQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "codex")
               |> Ash.read_one()

      assert merged.plan == "from-plan"

      assert [_one] =
               CodexQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "codex")
               |> Ash.read!()
    end

    test "cloud_code_quotas (antigravity): collapses to the single newest row" do
      from = create_account!(%{provider: :antigravity, slug: "agy-merge-from"})
      into = create_account!(%{provider: :antigravity, slug: "agy-merge-into"})

      create_cloud_code_quota!(from.id, "antigravity",
        captured_at: ~U[2026-01-01 00:00:00Z],
        plan: "from-plan"
      )

      create_cloud_code_quota!(into.id, "antigravity",
        captured_at: ~U[2026-01-05 00:00:00Z],
        plan: "into-plan"
      )

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               GoogleQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "antigravity")
               |> Ash.read_one()

      assert merged.plan == "into-plan"

      assert [_one] =
               GoogleQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "antigravity")
               |> Ash.read!()
    end

    test "re-points a single quota row when only the from account has one" do
      from = create_account!(%{provider: :claude, slug: "quota-solo-from"})
      into = create_account!(%{provider: :claude, slug: "quota-solo-into"})

      create_anthropic_quota!(from.id, utilization_5h: 0.42)

      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:ok, merged} =
               AnthropicQuota
               |> Ash.Query.filter(provider_account_id == ^into.id and provider == "claude")
               |> Ash.read_one()

      assert_in_delta merged.utilization_5h, 0.42, 0.001
    end
  end

  describe "delete_account/2" do
    test "soft-deletes: hides from list_accounts/1, keeps the row and usage attribution" do
      account = create_account!(%{provider: :claude, slug: "delete-plain"})
      create_event!(%{provider_account_id: account.id, model: "claude-3", cost_usd: 1.0})

      assert {:ok, deleted} = Accounts.delete_account(account.id)

      assert %DateTime{} = deleted.deleted_at
      assert deleted.enabled == false
      refute account.id in Enum.map(Accounts.list_accounts(), & &1.id)
      assert {:ok, %{id: id}} = Accounts.get_account(account.id)
      assert id == account.id
      assert sum_cost(account.id) == 1.0
    end

    test "retires every active credential, never exposing the secret" do
      account = create_account!(%{provider: :claude, slug: "delete-retires-creds"})

      {:ok, credential} =
        Ash.create(ProviderCredential, %{
          provider_account_id: account.id,
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "super-secret-token",
          fingerprint: "fp-delete-1"
        })

      assert {:ok, _} = Accounts.delete_account(account.id)

      assert {:ok, retired} = Ash.get(ProviderCredential, credential.id)
      assert retired.active == false
      assert %DateTime{} = retired.retired_at
      # `secret` is a write-only, decrypt-on-demand calculation — not
      # selected by a plain `Ash.get/2`, so it never carries the plaintext
      # here.
      assert match?(%Ash.NotLoaded{}, retired.secret)
    end

    test "refused while attached to a workspace, without --detach" do
      account = create_account!(%{provider: :claude, slug: "delete-attached"})
      ws = create_workspace!("delete-attached-ws")
      {:ok, _link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      assert {:error, {:attached, [workspace_id]}} = Accounts.delete_account(account.id)
      assert workspace_id == ws.id

      assert {:ok, %{deleted_at: nil}} = Accounts.get_account(account.id)
    end

    test "with detach: true, detaches the plain link and deletes" do
      account = create_account!(%{provider: :claude, slug: "delete-with-detach"})
      ws = create_workspace!("delete-with-detach-ws")
      {:ok, _link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      assert {:ok, deleted} = Accounts.delete_account(account.id, detach: true)
      assert %DateTime{} = deleted.deleted_at

      assert [] =
               WorkspaceProviderAccount
               |> Ash.Query.filter(provider_account_id == ^account.id)
               |> Ash.read!()
    end

    test "refused when required by a workspace's implementer settings, even with --detach" do
      account = create_account!(%{provider: :claude, slug: "delete-implementer-required"})
      ws = create_workspace!("delete-implementer-ws")

      {:ok, link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      link
      |> Ash.Changeset.for_update(:update, %{implementer_position: 0})
      |> Ash.update!()

      assert {:error, {:required_by_workspace, workspace_id, [:implementer]}} =
               Accounts.delete_account(account.id, detach: true)

      assert workspace_id == ws.id
      assert {:ok, %{deleted_at: nil}} = Accounts.get_account(account.id)
    end

    test "refused when required by a workspace's reviewer settings" do
      account = create_account!(%{provider: :claude, slug: "delete-reviewer-required"})
      ws = create_workspace!("delete-reviewer-ws")

      {:ok, link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      link
      |> Ash.Changeset.for_update(:update, %{reviewer_position: 0})
      |> Ash.update!()

      assert {:error, {:required_by_workspace, _workspace_id, [:reviewer]}} =
               Accounts.delete_account(account.id)
    end

    test "refused when the account would drop a workspace's sole active-credential source" do
      account = create_account!(%{provider: :claude, slug: "delete-missing-credential-risk"})

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "delete-missing-credential-risk-ws",
          prefix: "mcr",
          worker_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "tok", "secret" => true}}
        })

      {:ok, _link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      assert {:error, {:missing_credential_risk, workspace_id}} =
               Accounts.delete_account(account.id, detach: true)

      assert workspace_id == ws.id
    end

    test "refused when pinned by a running task's provider routing" do
      account = create_account!(%{provider: :claude, slug: "delete-pinned"})
      ws = create_workspace!("delete-pinned-ws")

      {:ok, task} = Ash.create(Issue, %{title: "pinned work", workspace_id: ws.id})

      {:ok, _task} =
        task
        |> Ash.Changeset.for_update(:pin_implementer, %{implementer_account_id: account.id})
        |> Ash.update()

      assert {:error, {:pinned_by_task, task_id}} = Accounts.delete_account(account.id)
      assert task_id == task.id
    end

    test "not refused by a pin on a closed task" do
      account = create_account!(%{provider: :claude, slug: "delete-pin-closed"})
      ws = create_workspace!("delete-pin-closed-ws")

      {:ok, task} = Ash.create(Issue, %{title: "done work", workspace_id: ws.id})

      {:ok, task} =
        task
        |> Ash.Changeset.for_update(:pin_implementer, %{implementer_account_id: account.id})
        |> Ash.update()

      {:ok, _task} = task |> Ash.Changeset.for_update(:close, %{}) |> Ash.update()

      assert {:ok, _deleted} = Accounts.delete_account(account.id)
    end

    test "refused a second time — already deleted" do
      account = create_account!(%{provider: :claude, slug: "delete-twice"})
      assert {:ok, _} = Accounts.delete_account(account.id)
      assert {:error, :already_deleted} = Accounts.delete_account(account.id)
    end

    test "refused on an already-merged-away account" do
      into = create_account!(%{provider: :claude, slug: "delete-merged-survivor"})
      from = create_account!(%{provider: :claude, slug: "delete-merged-away"})
      assert {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      assert {:error, {:merged_away, into_id}} = Accounts.delete_account(from.id)
      assert into_id == into.id
    end

    test "hard delete succeeds for an account with no usage rows and no credentials ever" do
      account = create_account!(%{provider: :claude, slug: "delete-hard-clean"})

      assert {:ok, _deleted} = Accounts.delete_account(account.id, hard: true)
      assert {:error, :not_found} = Accounts.get_account(account.id)
    end

    test "hard delete refused when the account has usage rows" do
      account = create_account!(%{provider: :claude, slug: "delete-hard-with-usage"})
      create_event!(%{provider_account_id: account.id, model: "claude-3", cost_usd: 0.5})

      assert {:error, :hard_delete_blocked} = Accounts.delete_account(account.id, hard: true)
      assert {:ok, %{deleted_at: nil}} = Accounts.get_account(account.id)
    end

    test "hard delete refused when the account has ever had a credential, even retired" do
      account = create_account!(%{provider: :claude, slug: "delete-hard-with-credential"})

      {:ok, _credential} =
        Ash.create(ProviderCredential, %{
          provider_account_id: account.id,
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "tok",
          fingerprint: "fp-hard-1",
          active: false
        })

      assert {:error, :hard_delete_blocked} = Accounts.delete_account(account.id, hard: true)
    end
  end

  # A plain read-time aggregation over usage_events — not Usage.summarize/1's
  # workspace-approximation path (that's P9's job to make exact), a direct
  # query against the column merge/2 re-points.
  defp sum_cost(account_id) do
    Event
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.read!()
    |> Enum.reduce(0.0, fn ev, acc -> acc + (ev.cost_usd || 0.0) end)
  end
end
