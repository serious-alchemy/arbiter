defmodule Arbiter.MCP.ReadGapsTest do
  @moduledoc """
  P-17: the MCP read tools that were REST/CLI-only — `account_list`,
  `account_show`, `provider_list`, `usage_events_list`, `usage_calibration` —
  plus the `account` argument on `quota_get` and `usage_summarize`.

  Their output reuses the shared serializers (`Arbiter.Accounts.Serializer`,
  `Arbiter.Usage.Serializer`) that the REST controllers render through, and no
  response may carry secret material: the key sets are asserted exactly.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Providers.Pause
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  @coordinator %Scope{tier: :coordinator, workspace_id: nil}
  @secret "sk-super-secret-value-0123456789"

  @account_keys ~w(deleted_at enabled id identity_source identity_verified_at inserted_at label
                   max_concurrent merged_into_id plan provider provider_account_ref
                   provider_org_ref quota_config slug updated_at)a
  @credential_keys ~w(active created_at env_var fingerprint id kind retired_at retired_at scopes)a
  @link_keys ~w(id provider provider_account_id share workspace_id)a
  @event_keys ~w(cache_creation_tokens cache_read_tokens cost_usd duration_ms exit_status id model
                 occurred_at provider repo session_id source step task_id thinking_tokens
                 tokens_in tokens_out worker_run_id workspace_id)a

  defp account!(provider, slug, attrs \\ %{}) do
    {:ok, account} =
      Ash.create(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))

    account
  end

  defp workspace!(name) do
    {:ok, ws} = Ash.create(Workspace, %{name: name, prefix: "rg"})
    ws
  end

  defp insert_event!(attrs) do
    base = %{
      task_id: "bd-#{System.unique_integer([:positive])}",
      repo: "arbiter",
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()
  defp sorted(list), do: Enum.sort(Enum.uniq(list))

  describe "account_list" do
    test "lists accounts with exactly the REST account key set" do
      account!(:claude, "rg-one")
      account!(:codex, "rg-two")

      assert {:ok, %{accounts: accounts, count: count}} =
               Catalog.call(@coordinator, "account_list", %{})

      assert count == length(accounts)
      assert Enum.any?(accounts, &(&1.slug == "rg-one"))

      for a <- accounts, do: assert(keys(a) == sorted(@account_keys))
    end

    test "filters by provider and rejects an unknown one" do
      account!(:claude, "rg-filter-claude")
      account!(:codex, "rg-filter-codex")

      assert {:ok, %{accounts: accounts}} =
               Catalog.call(@coordinator, "account_list", %{"provider" => "codex"})

      assert accounts != []
      assert Enum.all?(accounts, &(&1.provider == :codex))

      assert {:tool_error, _, _} =
               Catalog.call(@coordinator, "account_list", %{"provider" => "nope"})
    end

    test "hides soft-deleted accounts unless include_deleted" do
      account = account!(:claude, "rg-deleted")
      {:ok, _} = Accounts.delete_account(account.id)

      assert {:ok, %{accounts: live}} = Catalog.call(@coordinator, "account_list", %{})
      refute Enum.any?(live, &(&1.slug == "rg-deleted"))

      assert {:ok, %{accounts: all}} =
               Catalog.call(@coordinator, "account_list", %{"include_deleted" => true})

      assert Enum.any?(all, &(&1.slug == "rg-deleted"))
    end

    test "is coordinator-only" do
      worker = %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
      assert {:rpc_error, _, _} = Catalog.call(worker, "account_list", %{})
    end
  end

  describe "account_show" do
    test "shows credential kind + fingerprint prefix and workspaces, never the secret" do
      account = account!(:claude, "rg-show")
      ws = workspace!("rg-show-ws")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: @secret
        })

      assert {:ok, shown} = Catalog.call(@coordinator, "account_show", %{"ref" => "rg-show"})

      assert keys(shown) == sorted([:credentials, :workspaces, :spend_cap | @account_keys])
      assert [credential] = shown.credentials
      assert keys(credential) == sorted(@credential_keys)
      assert credential.kind == :oauth_token
      assert String.length(credential.fingerprint) <= 12
      assert [link] = shown.workspaces
      assert keys(link) == sorted(@link_keys)

      refute inspect(shown) =~ @secret
      refute Jason.encode!(shown) =~ @secret
    end

    test "unknown ref is not_found; an ambiguous bare slug is invalid" do
      assert {:tool_error, _, _} =
               Catalog.call(@coordinator, "account_show", %{"ref" => "rg-nope"})

      account!(:claude, "rg-ambiguous")
      account!(:codex, "rg-ambiguous")

      assert {:tool_error, message, _} =
               Catalog.call(@coordinator, "account_show", %{"ref" => "rg-ambiguous"})

      assert message =~ "ambiguous"
    end

    test "requires ref" do
      assert {:tool_error, _, _} = Catalog.call(@coordinator, "account_show", %{})
    end
  end

  describe "provider_list" do
    test "lists the active pauses in the shape REST /api/providers/paused uses" do
      assert {:ok, %{paused: []}} = Catalog.call(@coordinator, "provider_list", %{})

      {:ok, _} = Pause.pause("codex", reason: "rg test", by: "mcp")

      assert {:ok, %{paused: paused}} = Catalog.call(@coordinator, "provider_list", %{})
      assert paused == Pause.to_json()
      assert Enum.any?(paused, &(&1["target"] == "codex"))
    end

    test "is coordinator-only" do
      worker = %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
      assert {:rpc_error, _, _} = Catalog.call(worker, "provider_list", %{})
    end
  end

  describe "usage_events_list" do
    setup do
      ws = workspace!("rg-usage-#{System.unique_integer([:positive])}")
      {:ok, ws: ws}
    end

    test "returns events newest first with the REST event key set", %{ws: ws} do
      old = insert_event!(%{workspace_id: ws.id, occurred_at: ~U[2026-06-01 10:00:00.000000Z]})
      new = insert_event!(%{workspace_id: ws.id, occurred_at: ~U[2026-06-02 10:00:00.000000Z]})

      assert {:ok, %{events: events, count: 2, workspace_id: ws_id}} =
               Catalog.call(@coordinator, "usage_events_list", %{"workspace" => ws.id})

      assert ws_id == ws.id
      assert Enum.map(events, & &1.id) == [new.id, old.id]
      for e <- events, do: assert(keys(e) == sorted(@event_keys))
    end

    test "filters by task, step, source, since and account; limits", %{ws: ws} do
      account = account!(:claude, "rg-usage-acct")

      mine =
        insert_event!(%{
          workspace_id: ws.id,
          task_id: "bd-rg1",
          step: :review,
          provider_account_id: account.id,
          occurred_at: ~U[2026-06-03 10:00:00.000000Z]
        })

      _other = insert_event!(%{workspace_id: ws.id, task_id: "bd-rg2"})

      call = &Catalog.call(@coordinator, "usage_events_list", Map.put(&1, "workspace", ws.id))

      assert {:ok, %{events: [%{id: id}]}} = call.(%{"task_id" => "bd-rg1"})
      assert id == mine.id
      assert {:ok, %{events: [%{id: ^id}]}} = call.(%{"step" => "review"})
      assert {:ok, %{events: [%{id: ^id}]}} = call.(%{"account" => "rg-usage-acct"})
      assert {:ok, %{events: [_]}} = call.(%{"limit" => 1})
      assert {:ok, %{events: []}} = call.(%{"since" => "2999-01-01T00:00:00Z"})
      assert {:ok, %{events: _}} = call.(%{"source" => "task"})
    end

    test "rejects bad arguments" do
      for args <- [
            %{"step" => "nope"},
            %{"source" => "nope"},
            %{"since" => "yesterday"},
            %{"limit" => 0},
            %{"account" => "rg-no-such-account"}
          ] do
        assert {:tool_error, _, _} = Catalog.call(@coordinator, "usage_events_list", args),
               "expected #{inspect(args)} to be rejected"
      end
    end

    test "a bound coordinator naming another workspace is -32003", %{ws: ws} do
      other = workspace!("rg-usage-other")
      bound = %Scope{tier: :coordinator, workspace_id: ws.id}

      assert {:rpc_error, -32_003, _} =
               Catalog.call(bound, "usage_events_list", %{"workspace" => other.id})
    end
  end

  describe "usage_calibration" do
    test "returns the REST calibration report shape" do
      assert {:ok, report} = Catalog.call(@coordinator, "usage_calibration", %{})

      assert keys(report) ==
               sorted([:workspace_id, :window_days, :re_dispatched_flagged, :tiers, :flagged])

      assert is_list(report.tiers)
      assert is_list(report.flagged)
    end

    test "window_days must be a positive integer" do
      assert {:tool_error, _, _} =
               Catalog.call(@coordinator, "usage_calibration", %{"window_days" => 0})

      assert {:ok, %{window_days: 7}} =
               Catalog.call(@coordinator, "usage_calibration", %{"window_days" => 7})
    end
  end

  describe "account argument" do
    test "usage_summarize narrows to one account" do
      mine = account!(:claude, "rg-sum-mine")
      theirs = account!(:claude, "rg-sum-theirs")
      insert_event!(%{task_id: "bd-rgs1", cost_usd: 1.0, provider_account_id: mine.id})
      insert_event!(%{task_id: "bd-rgs2", cost_usd: 9.0, provider_account_id: theirs.id})

      assert {:ok, %{rollups: rollups}} =
               Catalog.call(@coordinator, "usage_summarize", %{
                 "by" => "task",
                 "account" => "rg-sum-mine"
               })

      assert Enum.map(rollups, & &1.group) == ["bd-rgs1"]

      assert {:tool_error, _, _} =
               Catalog.call(@coordinator, "usage_summarize", %{
                 "by" => "task",
                 "account" => "rg-nope"
               })
    end

    test "quota_get with account returns that account's snapshot, not a workspace's" do
      account!(:claude, "rg-quota")

      assert {:ok, snapshot} = Catalog.call(@coordinator, "quota_get", %{"account" => "rg-quota"})

      assert snapshot.workspace_id == nil
      assert snapshot.account.slug == "rg-quota"
      assert is_list(snapshot.quotas)
      assert Map.has_key?(snapshot, :effective_policy)

      assert {:tool_error, _, _} =
               Catalog.call(@coordinator, "quota_get", %{"account" => "rg-nope"})
    end

    test "a worker may not read an arbitrary account's quota" do
      account!(:claude, "rg-quota-worker")
      worker = %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}

      assert {:rpc_error, -32_003, _} =
               Catalog.call(worker, "quota_get", %{"account" => "rg-quota-worker"})
    end
  end
end
