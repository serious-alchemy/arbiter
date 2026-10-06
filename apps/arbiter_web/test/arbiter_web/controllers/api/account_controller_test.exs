defmodule ArbiterWeb.Api.AccountControllerTest do
  use ArbiterWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Tasks.Workspace

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp create_account!(attrs) do
    {:ok, account} = Ash.create(ProviderAccount, attrs)
    account
  end

  defp create_workspace!(name) do
    {:ok, ws} = Ash.create(Workspace, %{name: name, prefix: "ac"})
    ws
  end

  describe "POST /api/accounts" do
    test "creates an account with no credential required", %{conn: conn} do
      conn = post(conn, ~p"/api/accounts", %{provider: "claude", slug: "rest-created"})

      body = json_response(conn, 201)
      assert body["provider"] == "claude"
      assert body["slug"] == "rest-created"
      assert body["enabled"] == true
      assert body["credentials"] == []
      assert body["workspaces"] == []
    end

    test "422s on a duplicate provider+slug", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "dupe"})
      conn = post(conn, ~p"/api/accounts", %{provider: "claude", slug: "dupe"})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end
  end

  describe "PATCH /api/accounts/:ref (P8 — the concurrency ceiling)" do
    test "sets max_concurrent", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "ceiling"})

      body = json_response(patch(conn, ~p"/api/accounts/ceiling", %{max_concurrent: 4}), 200)
      assert body["max_concurrent"] == 4
    end

    test "an explicit null clears it — the ceiling is opt-in (§4.4)", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "clearable", max_concurrent: 4})

      body =
        json_response(patch(conn, ~p"/api/accounts/clearable", %{max_concurrent: nil}), 200)

      assert body["max_concurrent"] == nil
    end

    test "400s when max_concurrent is absent", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "no-field"})
      assert json_response(patch(conn, ~p"/api/accounts/no-field", %{}), 400)
    end

    test "400s on a negative ceiling", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "negative"})
      assert json_response(patch(conn, ~p"/api/accounts/negative", %{max_concurrent: -1}), 400)
    end

    test "404s on an unknown ref", %{conn: conn} do
      assert json_response(patch(conn, ~p"/api/accounts/nope", %{max_concurrent: 1}), 404)
    end
  end

  describe "PATCH /api/accounts/:ref (bd-c7ll4t — quota_config)" do
    test "sets threshold_mode without disturbing max_concurrent", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "policy", max_concurrent: 3})

      body =
        json_response(
          patch(conn, ~p"/api/accounts/policy", %{
            quota_config: %{threshold_mode: "paced"}
          }),
          200
        )

      assert body["quota_config"]["threshold_mode"] == "paced"
      assert body["max_concurrent"] == 3
    end

    test "merges into existing quota_config rather than replacing it", %{conn: conn} do
      create_account!(%{
        provider: :claude,
        slug: "merge-policy",
        quota_config: %{"throttle_threshold" => 0.8}
      })

      body =
        json_response(
          patch(conn, ~p"/api/accounts/merge-policy", %{
            quota_config: %{weekly_threshold: 0.95}
          }),
          200
        )

      assert body["quota_config"]["weekly_threshold"] == 0.95
      assert body["quota_config"]["throttle_threshold"] == 0.8
    end

    test "sets weekly_threshold, paced_floor, weekly_paced_floor together", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "full-policy"})

      body =
        json_response(
          patch(conn, ~p"/api/accounts/full-policy", %{
            quota_config: %{
              threshold_mode: "paced",
              weekly_threshold: 0.92,
              paced_floor: 0.4,
              weekly_paced_floor: 0.25
            }
          }),
          200
        )

      assert body["quota_config"] == %{
               "threshold_mode" => "paced",
               "weekly_threshold" => 0.92,
               "paced_floor" => 0.4,
               "weekly_paced_floor" => 0.25
             }
    end

    test "400s on an invalid threshold_mode", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "bad-mode"})

      assert json_response(
               patch(conn, ~p"/api/accounts/bad-mode", %{
                 quota_config: %{threshold_mode: "aggressive"}
               }),
               400
             )
    end

    test "400s on an out-of-range float", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "bad-float"})

      assert json_response(
               patch(conn, ~p"/api/accounts/bad-float", %{
                 quota_config: %{weekly_threshold: 1.5}
               }),
               400
             )
    end

    test "400s on an unknown quota_config key", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "bad-key"})

      assert json_response(
               patch(conn, ~p"/api/accounts/bad-key", %{
                 quota_config: %{not_a_real_key: "x"}
               }),
               400
             )
    end

    test "400s when neither max_concurrent nor quota_config is given", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "no-updates"})
      assert json_response(patch(conn, ~p"/api/accounts/no-updates", %{}), 400)
    end

    # bd-c7ll4t (review finding 4): an invalid quota_config alongside a valid
    # max_concurrent must not partially apply — the request is one edit, not
    # two independent ones the caller can end up half-committed to.
    test "an invalid quota_config rejects the whole request without writing max_concurrent", %{
      conn: conn
    } do
      create_account!(%{provider: :claude, slug: "atomic-update", max_concurrent: 1})

      assert json_response(
               patch(conn, ~p"/api/accounts/atomic-update", %{
                 max_concurrent: 3,
                 quota_config: %{threshold_mode: "bogus"}
               }),
               400
             )

      body = json_response(get(conn, ~p"/api/accounts/atomic-update"), 200)
      assert body["max_concurrent"] == 1
    end
  end

  describe "PATCH /api/accounts/:ref (bd-8vkqd3 — label, plan, enabled)" do
    test "sets label, plan and enabled alone", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "meta-set", max_concurrent: 2})

      body =
        json_response(
          patch(conn, ~p"/api/accounts/meta-set", %{
            label: "Work Max",
            plan: "max_20x",
            enabled: false
          }),
          200
        )

      assert body["label"] == "Work Max"
      assert body["plan"] == "max_20x"
      assert body["enabled"] == false
      assert body["max_concurrent"] == 2
    end

    test "combines with max_concurrent and quota_config in one request", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "meta-combo"})

      body =
        json_response(
          patch(conn, ~p"/api/accounts/meta-combo", %{
            label: "Combo",
            max_concurrent: 5,
            quota_config: %{threshold_mode: "paced"}
          }),
          200
        )

      assert body["label"] == "Combo"
      assert body["max_concurrent"] == 5
      assert body["quota_config"]["threshold_mode"] == "paced"
    end

    test "a blank label clears it; enabled accepts the string form", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "meta-clear", label: "Old", enabled: false})

      body =
        json_response(
          patch(conn, ~p"/api/accounts/meta-clear", %{label: "", enabled: "true"}),
          200
        )

      assert body["label"] == nil
      assert body["enabled"] == true
    end

    test "400s on a non-boolean enabled without writing anything else", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "meta-bad", max_concurrent: 1})

      response =
        json_response(
          patch(conn, ~p"/api/accounts/meta-bad", %{enabled: "maybe", max_concurrent: 9}),
          400
        )

      assert response["error"]["message"] =~ "enabled"
      assert json_response(get(conn, ~p"/api/accounts/meta-bad"), 200)["max_concurrent"] == 1
    end

    test "400s when slug or provider is sent — identity is not an edit", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "meta-identity"})
      # Not a named updatable key: only the three above count as "an update".
      assert json_response(patch(conn, ~p"/api/accounts/meta-identity", %{slug: "x"}), 400)
    end

    test "a null quota_config value clears that key and leaves siblings", %{conn: conn} do
      create_account!(%{
        provider: :claude,
        slug: "meta-unset",
        quota_config: %{"weekly_threshold" => 0.8, "paced_floor" => 0.3}
      })

      body =
        json_response(
          patch(conn, ~p"/api/accounts/meta-unset", %{quota_config: %{weekly_threshold: nil}}),
          200
        )

      refute Map.has_key?(body["quota_config"], "weekly_threshold")
      assert body["quota_config"]["paced_floor"] == 0.3
    end
  end

  describe "GET /api/accounts" do
    test "lists accounts", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "list-a"})
      create_account!(%{provider: :codex, slug: "list-b"})

      body = json_response(get(conn, ~p"/api/accounts"), 200)
      slugs = Enum.map(body["data"], & &1["slug"])
      assert "list-a" in slugs and "list-b" in slugs
    end

    test "filters by provider", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "filter-a"})
      create_account!(%{provider: :codex, slug: "filter-b"})

      body = json_response(get(conn, ~p"/api/accounts?provider=claude"), 200)
      slugs = Enum.map(body["data"], & &1["slug"])
      assert slugs == ["filter-a"]
    end

    test "400s on an unknown provider even if that atom exists elsewhere in the VM", %{
      conn: conn
    } do
      # `:enabled` is an atom already interned by unrelated code, so a naive
      # `String.to_existing_atom/1` check would let it through as a "known"
      # provider. It must still be rejected.
      _ = :enabled

      assert %{"error" => %{"type" => "invalid_request"}} =
               json_response(get(conn, ~p"/api/accounts?provider=enabled"), 400)
    end

    test "hides merged-away accounts by default, and shows them with include_merged=true", %{
      conn: conn
    } do
      into = create_account!(%{provider: :claude, slug: "index-merge-survivor"})
      from = create_account!(%{provider: :claude, slug: "index-merge-away"})
      {:ok, _} = Accounts.merge_accounts(from.id, into.id)

      default_slugs =
        get(conn, ~p"/api/accounts")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["slug"])

      refute "index-merge-away" in default_slugs

      included_slugs =
        get(conn, ~p"/api/accounts?include_merged=true")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["slug"])

      assert "index-merge-away" in included_slugs
    end
  end

  describe "GET /api/accounts/:ref" do
    test "shows an account by slug with credentials (fingerprint only) and workspaces", %{
      conn: conn
    } do
      account = create_account!(%{provider: :claude, slug: "show-me"})
      ws = create_workspace!("show-ws")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, _cred} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-super-secret-value"
        })

      body = json_response(get(conn, ~p"/api/accounts/show-me"), 200)

      assert body["slug"] == "show-me"
      assert [%{"kind" => "oauth_token", "active" => true} = credential] = body["credentials"]
      refute Map.has_key?(credential, "secret")
      refute Map.has_key?(credential, "encrypted_secret")
      refute inspect(body) =~ "sk-super-secret-value"

      assert [%{"workspace_id" => ws_id}] = body["workspaces"]
      assert ws_id == ws.id
    end

    test "404s on an unknown ref", %{conn: conn} do
      assert %{"error" => %{"type" => "not_found"}} =
               json_response(get(conn, ~p"/api/accounts/does-not-exist"), 404)
    end

    test "400s on an ambiguous bare slug shared across providers", %{conn: conn} do
      create_account!(%{provider: :claude, slug: "ambiguous"})
      create_account!(%{provider: :codex, slug: "ambiguous"})

      assert %{"error" => %{"type" => "invalid_request"}} =
               json_response(get(conn, ~p"/api/accounts/ambiguous"), 400)
    end
  end

  describe "POST /api/accounts/:ref/attach" do
    test "attaches a workspace to an account", %{conn: conn} do
      account = create_account!(%{provider: :claude, slug: "attach-me"})
      ws = create_workspace!("attach-rest-ws")

      conn =
        post(conn, ~p"/api/accounts/attach-me/attach", %{
          "workspace_id" => ws.id,
          "provider" => "claude",
          "share" => 3
        })

      body = json_response(conn, 201)
      assert body["provider_account_id"] == account.id
      assert body["share"] == 3
    end

    test "a bare re-attach (no share) leaves an existing share untouched", %{conn: conn} do
      account = create_account!(%{provider: :claude, slug: "attach-keep-share"})
      ws = create_workspace!("attach-keep-share-ws")

      post(conn, ~p"/api/accounts/attach-keep-share/attach", %{
        "workspace_id" => ws.id,
        "provider" => "claude",
        "share" => 7
      })

      conn =
        post(conn, ~p"/api/accounts/attach-keep-share/attach", %{
          "workspace_id" => ws.id,
          "provider" => "claude"
        })

      body = json_response(conn, 201)
      assert body["provider_account_id"] == account.id
      assert body["share"] == 7
    end

    test "400s (not a raise/500) on a non-uuid workspace_id", %{conn: conn} do
      _account = create_account!(%{provider: :claude, slug: "attach-bad-ws-id"})

      conn =
        post(conn, ~p"/api/accounts/attach-bad-ws-id/attach", %{
          "workspace_id" => "ws-does-not-exist",
          "provider" => "claude"
        })

      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "POST /api/accounts/:ref/rotate" do
    test "rotates a credential without ever returning the secret", %{conn: conn} do
      _account = create_account!(%{provider: :claude, slug: "rotate-me"})

      conn =
        post(conn, ~p"/api/accounts/rotate-me/rotate", %{
          "kind" => "oauth_token",
          "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
          "secret" => "sk-rotated-secret"
        })

      body = json_response(conn, 201)
      assert body["kind"] == "oauth_token"
      assert body["active"] == true
      refute Map.has_key?(body, "secret")
      refute inspect(body) =~ "sk-rotated-secret"
    end

    test "never writes the plaintext secret to the log, even at :debug level (Phoenix.Logger's router-dispatch param log)",
         %{conn: conn} do
      _account = create_account!(%{provider: :claude, slug: "rotate-log-redacted"})

      log =
        capture_log([level: :debug], fn ->
          post(conn, ~p"/api/accounts/rotate-log-redacted/rotate", %{
            "kind" => "oauth_token",
            "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
            "secret" => "sk-must-not-leak"
          })
        end)

      refute log =~ "sk-must-not-leak"
    end

    test "400s (not a raise/500) on an unrecognised kind", %{conn: conn} do
      _account = create_account!(%{provider: :claude, slug: "rotate-bad-kind"})

      conn =
        post(conn, ~p"/api/accounts/rotate-bad-kind/rotate", %{
          "kind" => "not_a_kind",
          "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
          "secret" => "sk-whatever"
        })

      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "scopes round-trip through the string-keyed params the CLI sends", %{conn: conn} do
      _account = create_account!(%{provider: :claude, slug: "rotate-scopes"})

      conn =
        post(conn, ~p"/api/accounts/rotate-scopes/rotate", %{
          "kind" => "oauth_token",
          "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
          "secret" => "sk-scoped-secret",
          "scopes" => ["user:inference", "user:profile"]
        })

      body = json_response(conn, 201)
      assert body["scopes"] == ["user:inference", "user:profile"]
    end
  end

  describe "POST /api/accounts/:ref/merge" do
    test "merges one account into another", %{conn: conn} do
      from = create_account!(%{provider: :claude, slug: "rest-merge-from"})
      into = create_account!(%{provider: :claude, slug: "rest-merge-into"})

      conn = post(conn, ~p"/api/accounts/rest-merge-from/merge", %{"into" => into.id})

      body = json_response(conn, 200)
      assert body["id"] == into.id

      # The from row is soft-deleted, not destroyed — still fetchable by id,
      # now bearing `merged_into_id` as the audit trail (§2.5).
      from_body = json_response(get(conn, ~p"/api/accounts/#{from.id}"), 200)
      assert from_body["merged_into_id"] == into.id
      assert from_body["enabled"] == false
    end

    test "400s merging accounts of different providers", %{conn: conn} do
      _from = create_account!(%{provider: :claude, slug: "cross-from"})
      into = create_account!(%{provider: :codex, slug: "cross-into"})

      conn = post(conn, ~p"/api/accounts/cross-from/merge", %{"into" => into.id})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "400s merging an already-merged-away account into a live one, instead of silently re-pointing onto a disabled row",
         %{conn: conn} do
      a = create_account!(%{provider: :claude, slug: "chain-a"})
      b = create_account!(%{provider: :claude, slug: "chain-b"})
      _live = create_account!(%{provider: :claude, slug: "chain-live"})

      assert {:ok, _} = Accounts.merge_accounts(a.id, b.id)

      # `live` was never merged; only `a` (the merge's `from` side) has been
      # merged away — attempting to merge `live` into `a` must be rejected.
      conn = post(conn, ~p"/api/accounts/chain-live/merge", %{"into" => a.id})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "DELETE /api/accounts/:ref" do
    test "soft-deletes an unattached account", %{conn: conn} do
      account = create_account!(%{provider: :claude, slug: "rest-delete-plain"})

      body = conn |> delete(~p"/api/accounts/#{account.id}") |> json_response(200)

      assert body["id"] == account.id
      refute is_nil(body["deleted_at"])
      assert body["enabled"] == false

      # Hidden from the default list, still fetchable by id.
      index_body = json_response(get(conn, ~p"/api/accounts"), 200)
      refute account.id in Enum.map(index_body["data"], & &1["id"])
      assert json_response(get(conn, ~p"/api/accounts/#{account.id}"), 200)["id"] == account.id
    end

    test "400s while attached, without ?detach=true", %{conn: conn} do
      account = create_account!(%{provider: :claude, slug: "rest-delete-attached"})
      ws = create_workspace!("rest-delete-attached-ws")
      {:ok, _link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      conn = delete(conn, ~p"/api/accounts/#{account.id}")
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "detaches and deletes with ?detach=true", %{conn: conn} do
      account = create_account!(%{provider: :claude, slug: "rest-delete-detach"})
      ws = create_workspace!("rest-delete-detach-ws")
      {:ok, _link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      conn = delete(conn, ~p"/api/accounts/#{account.id}?detach=true")
      assert json_response(conn, 200)["id"] == account.id
    end

    test "400s when required by a workspace's implementer setting, even with ?detach=true", %{
      conn: conn
    } do
      account = create_account!(%{provider: :claude, slug: "rest-delete-implementer-required"})
      ws = create_workspace!("rest-delete-implementer-ws")
      {:ok, link} = Accounts.attach_workspace(ws.id, :claude, account.id)

      link |> Ash.Changeset.for_update(:update, %{implementer_position: 0}) |> Ash.update!()

      conn = delete(conn, ~p"/api/accounts/#{account.id}?detach=true")
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "hard-deletes a clean account with ?hard=true", %{conn: conn} do
      account = create_account!(%{provider: :claude, slug: "rest-delete-hard"})

      conn = delete(conn, ~p"/api/accounts/#{account.id}?hard=true")
      assert json_response(conn, 200)["id"] == account.id

      assert json_response(get(conn, ~p"/api/accounts/#{account.id}"), 404)
    end

    test "400s a hard delete when the account has usage rows", %{conn: conn} do
      account = create_account!(%{provider: :claude, slug: "rest-delete-hard-blocked"})

      {:ok, _event} =
        Ash.create(Arbiter.Usage.Event, %{
          provider_account_id: account.id,
          task_id: "bd-rest-delete-hard",
          source: :task,
          repo: "arbiter",
          workspace_id: "ws-rest-delete-hard",
          step: :work,
          occurred_at: DateTime.utc_now()
        })

      conn = delete(conn, ~p"/api/accounts/#{account.id}?hard=true")
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end
end
