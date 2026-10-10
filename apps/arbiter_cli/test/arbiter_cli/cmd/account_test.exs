defmodule ArbiterCli.Cmd.AccountTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Account

  test "account list renders provider:slug and id" do
    stub_get("/api/accounts", %{
      "data" => [
        %{
          "id" => "acct-1",
          "provider" => "claude",
          "slug" => "personal-max",
          "max_concurrent" => nil,
          "enabled" => true,
          "merged_into_id" => nil
        }
      ]
    })

    {out, _err, exit_code} = capture(fn -> Account.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "claude:personal-max  (acct-1)"
  end

  test "account list with no accounts" do
    stub_get("/api/accounts", %{"data" => []})
    {out, _err, exit_code} = capture(fn -> Account.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "(no accounts)"
  end

  test "account list --include-merged forwards include_merged=true and renders the merged suffix" do
    stub_routes([
      {{"get", "/api/accounts"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["include_merged"] == "true"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "data" => [
             %{
               "id" => "acct-1",
               "provider" => "claude",
               "slug" => "merged-away",
               "max_concurrent" => nil,
               "enabled" => false,
               "merged_into_id" => "acct-2"
             }
           ]
         })
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Account.run(["list", "--include-merged"]) end)
    assert exit_code == 0
    assert out =~ "[merged -> acct-2]"
  end

  # ---- set (P8, `docs/provider-account-design.md` §4.2-§4.4) ---------------

  test "account set --max-concurrent PATCHes the ceiling" do
    stub_routes([
      {{"patch", "/api/accounts/personal-max"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"max_concurrent" => 4}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "id" => "acct-1",
           "provider" => "claude",
           "slug" => "personal-max",
           "max_concurrent" => 4,
           "enabled" => true,
           "merged_into_id" => nil
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Account.run(["set", "personal-max", "--max-concurrent", "4"]) end)

    assert exit_code == 0
    assert out =~ "claude:personal-max max_concurrent=4"
  end

  test "account set --max-concurrent none clears the ceiling (§4.4: opt-in)" do
    stub_routes([
      {{"patch", "/api/accounts/personal-max"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"max_concurrent" => nil}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "id" => "acct-1",
           "provider" => "claude",
           "slug" => "personal-max",
           "max_concurrent" => nil,
           "enabled" => true,
           "merged_into_id" => nil
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Account.run(["set", "personal-max", "--max-concurrent", "none"]) end)

    assert exit_code == 0
    assert out =~ "max_concurrent=(none)"
  end

  test "account set --json emits the account" do
    stub_patch("/api/accounts/acct-1", %{
      "id" => "acct-1",
      "provider" => "claude",
      "slug" => "personal-max",
      "max_concurrent" => 2,
      "enabled" => true,
      "merged_into_id" => nil
    })

    {out, _err, exit_code} =
      capture(fn -> Account.run(["set", "acct-1", "--max-concurrent", "2", "--json"]) end)

    assert exit_code == 0
    assert Jason.decode!(out)["max_concurrent"] == 2
  end

  test "account set without --max-concurrent is an error" do
    {_out, err, exit_code} = capture(fn -> Account.run(["set", "personal-max"]) end)
    assert exit_code != 0
    assert err =~ "--max-concurrent"
  end

  test "account set rejects a negative ceiling" do
    {_out, err, exit_code} =
      capture(fn -> Account.run(["set", "personal-max", "--max-concurrent", "-1"]) end)

    assert exit_code != 0
    assert err =~ "--max-concurrent"
  end

  test "account set requires a ref" do
    {_out, err, exit_code} = capture(fn -> Account.run(["set", "--max-concurrent", "2"]) end)
    assert exit_code != 0
    assert err =~ "account set requires"
  end

  # ---- set --threshold-mode / --weekly-threshold / ... (bd-c7ll4t) ---------

  test "account set --threshold-mode PATCHes quota_config without max_concurrent" do
    stub_routes([
      {{"patch", "/api/accounts/personal-max"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"quota_config" => %{"threshold_mode" => "paced"}}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "id" => "acct-1",
           "provider" => "claude",
           "slug" => "personal-max",
           "max_concurrent" => nil,
           "quota_config" => %{"threshold_mode" => "paced"},
           "enabled" => true,
           "merged_into_id" => nil
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Account.run(["set", "personal-max", "--threshold-mode", "paced"]) end)

    assert exit_code == 0
    assert out =~ "threshold_mode=paced"
  end

  test "account set combines --max-concurrent with the quota_config flags in one PATCH" do
    stub_routes([
      {{"patch", "/api/accounts/personal-max"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)

         assert Jason.decode!(body) == %{
                  "max_concurrent" => 4,
                  "quota_config" => %{
                    "threshold_mode" => "paced",
                    "weekly_threshold" => 0.92,
                    "paced_floor" => 0.4,
                    "weekly_paced_floor" => 0.25
                  }
                }

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "id" => "acct-1",
           "provider" => "claude",
           "slug" => "personal-max",
           "max_concurrent" => 4,
           "quota_config" => %{"threshold_mode" => "paced"},
           "enabled" => true,
           "merged_into_id" => nil
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn ->
        Account.run([
          "set",
          "personal-max",
          "--max-concurrent",
          "4",
          "--threshold-mode",
          "paced",
          "--weekly-threshold",
          "0.92",
          "--paced-floor",
          "0.4",
          "--weekly-paced-floor",
          "0.25"
        ])
      end)

    assert exit_code == 0
    assert out =~ "max_concurrent=4"
  end

  test "account set rejects an out-of-range --weekly-threshold" do
    {_out, err, exit_code} =
      capture(fn ->
        Account.run(["set", "personal-max", "--weekly-threshold", "1.5"])
      end)

    assert exit_code != 0
    assert err =~ "--weekly-threshold"
  end

  # ---- every editable quota key (bd-1kr3qf, D-A-15) ----------------------------

  defp patch_body_route(expected) do
    {{"patch", "/api/accounts/personal-max"},
     fn conn ->
       {:ok, body, conn} = Plug.Conn.read_body(conn)
       assert Jason.decode!(body) == expected

       conn
       |> Plug.Conn.put_status(200)
       |> Req.Test.json(%{
         "id" => "acct-1",
         "provider" => "claude",
         "slug" => "personal-max",
         "max_concurrent" => nil,
         "quota_config" => %{},
         "enabled" => true,
         "merged_into_id" => nil
       })
     end}
  end

  test "account set reaches every quota key the registry names" do
    stub_routes([
      patch_body_route(%{
        "quota_config" => %{
          "threshold_mode" => "paced",
          "throttle_threshold" => 0.7,
          "weekly_threshold" => 0.9,
          "paced_floor" => 0.3,
          "weekly_paced_floor" => 0.2,
          "weekly_warning_policy" => "hold",
          "window_seconds" => %{"5h" => 18_000, "7d" => 604_800},
          "pace_exempt_priority" => 1,
          "pace_exempt_threshold" => 0.95,
          "weekly_pace_exempt_threshold" => 0.97
        }
      })
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Account.run(~w(set personal-max --threshold-mode paced --throttle-threshold 0.7
          --weekly-threshold 0.9 --paced-floor 0.3 --weekly-paced-floor 0.2
          --weekly-warning-policy hold --window-seconds 5h=18000 --window-seconds 7d=604800
          --pace-exempt-priority 1 --pace-exempt-threshold 0.95
          --weekly-pace-exempt-threshold 0.97))
      end)

    assert exit_code == 0
  end

  test "--spend-cap / --spend-window / --spend-mode / --spend-metered send the spend cap" do
    stub_routes([
      patch_body_route(%{
        "quota_config" => %{
          "spend_cap" => 20.0,
          "spend_window" => "week",
          "spend_mode" => "paced",
          "spend_metered" => true
        }
      })
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Account.run(~w(set personal-max --spend-cap 20 --spend-window week --spend-mode paced
          --spend-metered true))
      end)

    assert exit_code == 0
  end

  test "--spend-cap none clears the cap" do
    stub_routes([patch_body_route(%{"quota_config" => %{"spend_cap" => nil}})])

    {_out, _err, exit_code} =
      capture(fn -> Account.run(~w(set personal-max --spend-cap none)) end)

    assert exit_code == 0
  end

  test "bad spend flags die client-side naming the flag" do
    for {args, flag} <- [
          {~w(--spend-cap 0), "--spend-cap"},
          {~w(--spend-cap abc), "--spend-cap"},
          {~w(--spend-window fortnight), "--spend-window"},
          {~w(--spend-mode strict), "--spend-mode"},
          {~w(--spend-metered maybe), "--spend-metered"}
        ] do
      {_out, err, exit_code} = capture(fn -> Account.run(["set", "personal-max" | args]) end)
      assert exit_code != 0, "#{flag} should have failed"
      assert err =~ flag
    end
  end

  test "--window-seconds also takes a comma list" do
    stub_routes([
      patch_body_route(%{"quota_config" => %{"window_seconds" => %{"5h" => 1, "7d" => 2}}})
    ])

    {_out, _err, exit_code} =
      capture(fn -> Account.run(~w(set personal-max --window-seconds 5h=1,7d=2)) end)

    assert exit_code == 0
  end

  test "--pace-exempt-priority none clears the key" do
    stub_routes([patch_body_route(%{"quota_config" => %{"pace_exempt_priority" => nil}})])

    {_out, _err, exit_code} =
      capture(fn -> Account.run(~w(set personal-max --pace-exempt-priority none)) end)

    assert exit_code == 0
  end

  test "--unset clears a quota key (underscore or dash spelling), repeatable" do
    stub_routes([
      patch_body_route(%{
        "quota_config" => %{"weekly_threshold" => nil, "window_seconds" => nil}
      })
    ])

    {_out, _err, exit_code} =
      capture(fn ->
        Account.run(~w(set personal-max --unset weekly_threshold --unset window-seconds))
      end)

    assert exit_code == 0
  end

  test "--unset rejects a key that is not a quota key" do
    {_out, err, exit_code} =
      capture(fn -> Account.run(~w(set personal-max --unset label)) end)

    assert exit_code != 0
    assert err =~ "--unset"
    assert err =~ "weekly_threshold"
  end

  test "--unset together with a value for the same key is refused" do
    {_out, err, exit_code} =
      capture(fn ->
        Account.run(~w(set personal-max --weekly-threshold 0.9 --unset weekly_threshold))
      end)

    assert exit_code != 0
    assert err =~ "weekly_threshold"
  end

  test "bad values for the new flags die client-side naming the flag" do
    for {args, flag} <- [
          {~w(--throttle-threshold 2), "--throttle-threshold"},
          {~w(--pace-exempt-priority 9), "--pace-exempt-priority"},
          {~w(--pace-exempt-threshold x), "--pace-exempt-threshold"},
          {~w(--weekly-pace-exempt-threshold 0), "--weekly-pace-exempt-threshold"},
          {~w(--weekly-warning-policy maybe), "--weekly-warning-policy"},
          {~w(--window-seconds 5h), "--window-seconds"},
          {~w(--window-seconds 5h=0), "--window-seconds"}
        ] do
      {_out, err, exit_code} = capture(fn -> Account.run(["set", "personal-max" | args]) end)
      assert exit_code != 0, "#{flag} should have failed"
      assert err =~ flag
    end
  end

  test "every registry quota key has an `arb account set` flag" do
    keys = Arbiter.Accounts.Fields.quota_keys() |> Enum.sort()
    assert Enum.sort(Account.quota_keys()) == keys
  end

  test "account create carries the same quota flags, --disable and the identity refs" do
    stub_routes([
      {{"post", "/api/accounts"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)

         assert Jason.decode!(body) == %{
                  "provider" => "claude",
                  "slug" => "fresh",
                  "enabled" => false,
                  "provider_account_ref" => "uuid-a",
                  "provider_org_ref" => "uuid-o",
                  "quota_config" => %{
                    "threshold_mode" => "paced",
                    "window_seconds" => %{"5h" => 9}
                  }
                }

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"id" => "acct-9", "provider" => "claude", "slug" => "fresh"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn ->
        Account.run(~w(create claude fresh --disable --provider-account-ref uuid-a
          --provider-org-ref uuid-o --threshold-mode paced --window-seconds 5h=9))
      end)

    assert exit_code == 0
    assert out =~ "created account claude:fresh"
  end

  test "account list --include-deleted forwards include_deleted=true" do
    stub_routes([
      {{"get", "/api/accounts"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["include_deleted"] == "true"
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => []})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Account.run(["list", "--include-deleted"]) end)
    assert exit_code == 0
  end

  test "account set with no flags at all is an error" do
    {_out, err, exit_code} = capture(fn -> Account.run(["set", "personal-max"]) end)
    assert exit_code != 0
    assert err =~ "account set requires at least one of"
  end

  test "account set --label/--plan/--disable PATCHes the account attributes (bd-8vkqd3)" do
    stub_routes([
      {{"patch", "/api/accounts/personal-max"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)

         assert Jason.decode!(body) ==
                  %{"label" => "Work Max", "plan" => "max_20x", "enabled" => false}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "id" => "acct-1",
           "provider" => "claude",
           "slug" => "personal-max",
           "label" => "Work Max",
           "plan" => "max_20x",
           "max_concurrent" => nil,
           "enabled" => false,
           "merged_into_id" => nil
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn ->
        Account.run([
          "set",
          "personal-max",
          "--label",
          "Work Max",
          "--plan",
          "max_20x",
          "--disable"
        ])
      end)

    assert exit_code == 0
    assert out =~ "enabled=false"
  end

  test "account set --enable sends enabled true; an empty --label clears it" do
    stub_routes([
      {{"patch", "/api/accounts/personal-max"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == %{"label" => "", "enabled" => true}

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "id" => "acct-1",
           "provider" => "claude",
           "slug" => "personal-max",
           "max_concurrent" => nil,
           "enabled" => true,
           "merged_into_id" => nil
         })
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> Account.run(["set", "personal-max", "--label", "", "--enable"]) end)

    assert exit_code == 0
  end

  test "account set refuses --enable together with --disable" do
    {_out, err, exit_code} =
      capture(fn -> Account.run(["set", "personal-max", "--enable", "--disable"]) end)

    assert exit_code != 0
    assert err =~ "--enable and --disable"
  end

  test "account show prints credentials and workspaces, never a secret" do
    stub_get("/api/accounts/personal-max", %{
      "id" => "acct-1",
      "provider" => "claude",
      "slug" => "personal-max",
      "label" => "Personal Max",
      "plan" => "max_20x",
      "enabled" => true,
      "max_concurrent" => nil,
      "merged_into_id" => nil,
      "credentials" => [
        %{
          "kind" => "oauth_token",
          "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
          "fingerprint" => "abc123def456",
          "active" => true,
          "retired_at" => nil
        }
      ],
      "workspaces" => [%{"workspace_id" => "ws-1", "share" => 2}]
    })

    {out, _err, exit_code} = capture(fn -> Account.run(["show", "personal-max"]) end)
    assert exit_code == 0
    assert out =~ "Slug:        personal-max"
    assert out =~ "oauth_token"
    assert out =~ "fingerprint=abc123def456"
    assert out =~ "workspace ws-1 share=2"
    refute out =~ "secret"
  end

  test "account create posts provider+slug and reports" do
    stub_post("/api/accounts", %{"id" => "acct-2", "provider" => "codex", "slug" => "team-plan"})

    {out, _err, exit_code} = capture(fn -> Account.run(["create", "codex", "team-plan"]) end)
    assert exit_code == 0
    assert out =~ "created account codex:team-plan (acct-2)"
  end

  defp ws_list_route do
    {{"get", "/api/workspaces"},
     {%{
        "data" => [
          %{"id" => "ws-1", "name" => "alpha"},
          %{"id" => "ws-2", "name" => "beta"}
        ]
      }, 200}}
  end

  test "account attach resolves a workspace id and posts workspace/provider/share" do
    stub_routes([
      ws_list_route(),
      {{"post", "/api/accounts/personal-max/attach"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)

         assert Jason.decode!(body) == %{
                  "workspace_id" => "ws-1",
                  "provider" => "claude",
                  "share" => 2
                }

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{
           "workspace_id" => "ws-1",
           "provider" => "claude",
           "provider_account_id" => "acct-1",
           "share" => 2
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Account.run(["attach", "ws-1", "claude", "personal-max", "--share", "2"]) end)

    assert exit_code == 0
    assert out =~ "attached workspace ws-1 -> account acct-1 share=2"
  end

  # D-A-17: a workspace *name* resolves, like every other workspace-scoped verb.
  test "account attach resolves a workspace name to its id" do
    stub_routes([
      ws_list_route(),
      {{"post", "/api/accounts/personal-max/attach"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert %{"workspace_id" => "ws-2"} = Jason.decode!(body)

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{"workspace_id" => "ws-2", "provider_account_id" => "acct-1"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Account.run(["attach", "beta", "claude", "personal-max"]) end)

    assert exit_code == 0
    assert out =~ "attached workspace ws-2"
  end

  test "account attach with an unknown workspace dies before posting" do
    stub_routes([ws_list_route()])

    {_out, err, exit_code} =
      capture(fn -> Account.run(["attach", "nope", "claude", "personal-max"]) end)

    assert exit_code != 0
    assert err =~ "no workspace named"
  end

  test "account detach resolves the workspace and DELETEs the one link" do
    stub_routes([
      ws_list_route(),
      {{"delete", "/api/accounts/personal-max/attach/ws-2"},
       {%{"workspace_id" => "ws-2", "provider" => "claude", "provider_account_id" => "acct-1"},
        200}}
    ])

    {out, _err, exit_code} = capture(fn -> Account.run(["detach", "beta", "personal-max"]) end)
    assert exit_code == 0
    assert out =~ "detached workspace ws-2 from account acct-1"
  end

  test "account detach requires a workspace and a ref" do
    {_out, err, exit_code} = capture(fn -> Account.run(["detach", "beta"]) end)
    assert exit_code != 0
    assert err =~ "account detach requires"
  end

  test "account detach surfaces the server's refusal" do
    stub_routes([
      ws_list_route(),
      {{"delete", "/api/accounts/personal-max/attach/ws-1"},
       {%{
          "error" => %{"type" => "invalid_request", "message" => "that workspace is not attached"}
        }, 400}}
    ])

    {_out, err, exit_code} = capture(fn -> Account.run(["detach", "alpha", "personal-max"]) end)
    assert exit_code != 0
    assert err =~ "not attached"
  end

  test "account rotate never prints the secret it just wrote" do
    stub_post("/api/accounts/personal-max/rotate", %{
      "id" => "cred-2",
      "kind" => "oauth_token",
      "fingerprint" => "fedcba987654",
      "active" => true
    })

    {out, err, exit_code} =
      capture(fn ->
        Account.run([
          "rotate",
          "personal-max",
          "--kind",
          "oauth_token",
          "--env-var",
          "CLAUDE_CODE_OAUTH_TOKEN",
          "--secret",
          "sk-super-secret-value"
        ])
      end)

    assert exit_code == 0
    # P-28: the argv form warns, and the warning does not echo the value.
    assert err =~ "warning: a secret on the command line"
    refute err =~ "sk-super-secret-value"
    assert out =~ "rotated oauth_token credential (fingerprint=fedcba987654)"
    refute out =~ "sk-super-secret-value"
    refute out =~ "secret"
  end

  test "account rotate --kind cli_credentials_path sends an absolute path under CLAUDE_CONFIG_DIR" do
    parent = self()

    stub_routes([
      {{"post", "/api/accounts/personal-max/rotate"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted_body, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{
           "id" => "cred-4",
           "kind" => "cli_credentials_path",
           "fingerprint" => "ddddeeeeffff",
           "active" => true
         })
       end}
    ])

    {out, _err, exit_code} =
      capture(fn ->
        Account.run([
          "rotate",
          "personal-max",
          "--kind",
          "cli_credentials_path",
          "--secret",
          "relative/quota-claude"
        ])
      end)

    assert exit_code == 0
    assert out =~ "rotated cli_credentials_path credential"

    assert_received {:posted_body,
                     %{
                       "kind" => "cli_credentials_path",
                       "env_var" => "CLAUDE_CONFIG_DIR",
                       "secret" => secret
                     }}

    assert secret == Path.expand("relative/quota-claude")
  end

  test "account rotate requires a secret source" do
    {_out, err, exit_code} =
      capture(fn ->
        Account.run(["rotate", "personal-max", "--kind", "oauth_token", "--env-var", "X"])
      end)

    assert exit_code != 0
    assert err =~ "requires a secret"
  end

  test "account rotate reads the secret from stdin when \"-\" is passed as an explicit rotate argument" do
    parent = self()

    stub_routes([
      {{"post", "/api/accounts/personal-max/rotate"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted_body, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{
           "id" => "cred-3",
           "kind" => "oauth_token",
           "fingerprint" => "aaaabbbbcccc",
           "active" => true
         })
       end}
    ])

    out =
      capture_io("sk-from-stdin\n", fn ->
        capture_io(:stderr, fn ->
          Account.run([
            "rotate",
            "personal-max",
            "--kind",
            "oauth_token",
            "--env-var",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "-"
          ])
        end)
      end)

    assert out =~ "rotated oauth_token credential (fingerprint=aaaabbbbcccc)"
    refute out =~ "sk-from-stdin"

    assert_received {:posted_body, %{"secret" => "sk-from-stdin"}}
  end

  test "account merge posts into and reports the survivor" do
    stub_post("/api/accounts/merge-from/merge", %{
      "id" => "acct-into",
      "provider" => "claude",
      "slug" => "merge-into"
    })

    {out, _err, exit_code} =
      capture(fn -> Account.run(["merge", "merge-from", "--into", "merge-into"]) end)

    assert exit_code == 0
    assert out =~ "merged into account claude:merge-into (acct-into)"
  end

  test "account merge requires --into" do
    {_out, err, exit_code} = capture(fn -> Account.run(["merge", "merge-from"]) end)
    assert exit_code != 0
    assert err =~ "--into"
  end

  test "account delete soft-deletes by default" do
    stub_delete(
      "/api/accounts/delete-me",
      %{
        "id" => "acct-del",
        "provider" => "claude",
        "slug" => "delete-me",
        "deleted_at" => "2026-09-27T00:00:00Z"
      },
      200
    )

    {out, _err, exit_code} = capture(fn -> Account.run(["delete", "delete-me"]) end)

    assert exit_code == 0
    assert out =~ "soft-deleted account claude:delete-me (acct-del)"
  end

  test "account delete --detach forwards detach=true" do
    stub_routes([
      {{"delete", "/api/accounts/delete-with-detach"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["detach"] == "true"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "acct-del", "provider" => "claude", "slug" => "detached"})
       end}
    ])

    {out, _err, exit_code} =
      capture(fn -> Account.run(["delete", "delete-with-detach", "--detach"]) end)

    assert exit_code == 0
    assert out =~ "soft-deleted account claude:detached"
  end

  test "account delete --hard forwards hard=true and reports a hard delete" do
    stub_routes([
      {{"delete", "/api/accounts/delete-hard"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["hard"] == "true"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{"id" => "acct-del", "provider" => "claude", "slug" => "hard-deleted"})
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Account.run(["delete", "delete-hard", "--hard"]) end)

    assert exit_code == 0
    assert out =~ "deleted account claude:hard-deleted (acct-del)"
    refute out =~ "soft-deleted"
  end

  test "account delete surfaces a refusal reason" do
    stub_delete(
      "/api/accounts/delete-attached",
      %{
        "error" => %{
          "type" => "invalid_request",
          "message" => "account is attached to workspace(s) ws-1"
        }
      },
      400
    )

    {_out, err, exit_code} = capture(fn -> Account.run(["delete", "delete-attached"]) end)

    assert exit_code != 0
    assert err =~ "attached to workspace"
  end

  test "unknown subcommand dies with a helpful message" do
    {_out, err, exit_code} = capture(fn -> Account.run(["bogus"]) end)
    assert exit_code != 0
    assert err =~ "unknown account subcommand"
  end

  test "--help prints the moduledoc" do
    {out, _err, exit_code} = capture(fn -> Account.run(["--help"]) end)
    assert exit_code == 0
    assert out =~ "arb account"
    assert out =~ "merge"
  end
end
