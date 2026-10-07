defmodule ArbiterCli.Cmd.ConfigTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Config

  @ws_id "ws-1"

  defp default_ws(config) do
    %{"data" => [%{"name" => "default", "id" => @ws_id, "prefix" => "bd", "config" => config}]}
  end

  describe "pure helpers" do
    test "parse_value/1 covers true/false/int/json/string" do
      assert Config.parse_value("true") == true
      assert Config.parse_value("false") == false
      assert Config.parse_value("42") == 42
      assert Config.parse_value("-7") == -7
      assert Config.parse_value(~s({"a":1})) == %{"a" => 1}
      assert Config.parse_value("[1,2,3]") == [1, 2, 3]
      assert Config.parse_value("null") == nil
      assert Config.parse_value("hello") == "hello"
      # Garbage JSON falls back to the raw string.
      assert Config.parse_value("{not json}") == "{not json}"
    end

    test "parse_value/1 stores a quoted string as text — one rule, JSON-or-raw (D-C-18)" do
      assert Config.parse_value(~s("true")) == "true"
      assert Config.parse_value(~s("123")) == "123"
      assert Config.parse_value(~s("hello world")) == "hello world"
      assert Config.parse_value("1.5") == 1.5
      # not JSON → raw
      assert Config.parse_value("2026-10-06") == "2026-10-06"
      assert Config.parse_value("x.example.com") == "x.example.com"
    end

    test "split/1 drops empty segments" do
      assert Config.split("a.b.c") == ["a", "b", "c"]
      assert Config.split(".a..b") == ["a", "b"]
    end

    test "split/1 keeps an escaped dot inside a segment (D-C-17)" do
      assert Config.split("repo_paths.my\\.repo") == ["repo_paths", "my.repo"]
      assert Config.split("a\\\\.b") == ["a\\", "b"]
    end

    test "put_in_path/3 + get_in_path/2 build and read nested maps" do
      m = Config.put_in_path(%{"x" => 1}, ["a", "b", "c"], true)
      assert Config.get_in_path(m, ["a", "b", "c"]) == true
      assert Config.get_in_path(m, ["x"]) == 1
      assert Config.get_in_path(m, ["nope"]) == nil
    end

    test "deep_merge/2 preserves siblings and recurses into maps" do
      assert Config.deep_merge(
               %{"a" => %{"x" => 1}, "b" => 2},
               %{"a" => %{"y" => 9}, "c" => 3}
             ) == %{"a" => %{"x" => 1, "y" => 9}, "b" => 2, "c" => 3}
    end

    test "drop_path/2 removes a leaf, no-op for missing paths" do
      m = %{"a" => %{"b" => 1, "c" => 2}}
      assert Config.drop_path(m, ["a", "b"]) == %{"a" => %{"c" => 2}}
      assert Config.drop_path(m, ["a", "nope"]) == m
      assert Config.drop_path(m, ["nope", "x"]) == m
    end
  end

  describe "get" do
    test "prints the full config when no key is given" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{"merge" => %{"auto_merge" => true}}), 200}}
      ])

      {out, _err, code} = capture(fn -> Config.run(["get"]) end)
      assert code == 0
      assert out =~ "\"auto_merge\""
      assert out =~ "true"
    end

    test "prints a single dotted leaf with --json" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{"tracker" => %{"type" => "github"}}), 200}}
      ])

      {out, _err, code} = capture(fn -> Config.run(["get", "tracker.type", "--json"]) end)
      assert code == 0
      assert String.trim(out) == ~s("github")
    end

    test "a missing key is an error with --json too, not null/exit 0 (D-C-14)" do
      stub_routes([{{"get", "/api/workspaces"}, {default_ws(%{}), 200}}])

      {_out, err, code} = capture(fn -> Config.run(["get", "nope.here", "--json"]) end)
      assert code == 1
      assert err =~ "key not found"
    end

    test "errors on a missing key (text mode)" do
      stub_routes([{{"get", "/api/workspaces"}, {default_ws(%{}), 200}}])

      {_out, err, code} = capture(fn -> Config.run(["get", "nope.here"]) end)
      assert code == 1
      assert err =~ "key not found"
    end
  end

  describe "set" do
    test "sends a deep-merge patch built from the dotted key" do
      initial = %{
        "merge" => %{
          "strategy" => "github",
          "config" => %{"owner" => "acme", "repo" => "arbiter"}
        }
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(initial), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["patch"] == %{"merge" => %{"auto_merge" => true}}

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "id" => @ws_id,
             "name" => "default",
             "config" => Map.put(initial, "merge", Map.put(initial["merge"], "auto_merge", true))
           })
         end}
      ])

      {out, _err, code} = capture(fn -> Config.run(["set", "merge.auto_merge", "true"]) end)
      assert code == 0
      assert out =~ "updated workspace default"
    end

    test "parses int and json values" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["patch"] == %{"review" => %{"rounds" => 5}}

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => %{}})
         end}
      ])

      {_out, _err, code} = capture(fn -> Config.run(["set", "review.rounds", "5"]) end)
      assert code == 0
    end

    test "the safety rails are the server's: its refusal is reported and no force is sent" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           refute Map.has_key?(Jason.decode!(body), "force")

           conn
           |> Plug.Conn.put_status(422)
           |> Req.Test.json(%{
             "error" => %{
               "type" => "validation_error",
               "message" => "tracker.type is \"github\" but tracker.config is missing/empty",
               "details" => %{}
             }
           })
         end}
      ])

      {_out, err, code} = capture(fn -> Config.run(["set", "tracker.type", "github"]) end)
      assert code == 1
      assert err =~ "tracker.config is missing"
    end

    test "secret* keys are refused by the server, on the CLI too (P-20, D-C-4)" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["patch"] == %{"secrets" => %{"x" => "tok"}}

           conn
           |> Plug.Conn.put_status(422)
           |> Req.Test.json(%{
             "error" => %{
               "type" => "validation_error",
               "message" =>
                 "cannot set \"secrets\" in the workspace config — use `arb workspace secret`",
               "details" => %{}
             }
           })
         end}
      ])

      {_out, err, code} = capture(fn -> Config.run(["set", "secrets.x", "tok"]) end)
      assert code == 1
      assert err =~ "arb workspace secret"
    end

    test "a quoted value is sent as the string, not the boolean" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["patch"] == %{"feature" => %{"flag" => "true"}}

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => %{}})
         end}
      ])

      {_out, _err, code} = capture(fn -> Config.run(["set", "feature.flag", ~s("true")]) end)
      assert code == 0
    end

    test "an escaped dot addresses a repo name containing a dot (D-C-17)" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["patch"] == %{"repo_paths" => %{"my.repo" => "/srv/x"}}

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => %{}})
         end}
      ])

      {_out, _err, code} =
        capture(fn -> Config.run(["set", "repo_paths.my\\.repo", "/srv/x"]) end)

      assert code == 0
    end

    test "--force is forwarded to the server as force: true" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["force"] == true

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "id" => @ws_id,
             "name" => "default",
             "config" => %{"tracker" => %{"type" => "github"}}
           })
         end}
      ])

      {_out, _err, code} =
        capture(fn -> Config.run(["set", "tracker.type", "github", "--force"]) end)

      assert code == 0
    end

    test "destructive overwrite of a non-empty leaf needs --force" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {default_ws(%{"tracker" => %{"type" => "github", "config" => %{"owner" => "old"}}}), 200}}
      ])

      {_out, err, code} =
        capture(fn -> Config.run(["set", "tracker.config.owner", "new"]) end)

      assert code == 1
      assert err =~ "before:"
      assert err =~ "after:"
      assert err =~ "--force"
    end
  end

  describe "unset" do
    test "removes a dotted leaf, server-side via unset_paths" do
      initial = %{
        "tracker" => %{"type" => "jira", "config" => %{"host" => "h", "project_key" => "AX"}}
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(initial), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["unset_paths"] == ["tracker.config.host"]

           updated = %{
             "tracker" => %{"type" => "jira", "config" => %{"project_key" => "AX"}}
           }

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => updated})
         end}
      ])

      # Use --force because removing a leaf is destructive.
      {_out, _err, code} =
        capture(fn -> Config.run(["unset", "tracker.config.host", "--force"]) end)

      assert code == 0
    end

    test "an absent key is an idempotent success, sent to the server (D-C-15)" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["unset_paths"] == ["no.such.key"]

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => %{}})
         end}
      ])

      {_out, _err, code} = capture(fn -> Config.run(["unset", "no.such.key"]) end)
      assert code == 0
    end

    test "sends the raw (escaped) key so the server splits it" do
      initial = %{"repo_paths" => %{"my.repo" => "/a", "b" => "/b"}}

      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(initial), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["unset_paths"] == ["repo_paths.my\\.repo"]

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => %{}})
         end}
      ])

      {_out, _err, code} =
        capture(fn -> Config.run(["unset", "repo_paths.my\\.repo", "--force"]) end)

      assert code == 0
    end
  end

  describe "errors" do
    test "no subcommand" do
      {_out, err, code} = capture(fn -> Config.run([]) end)
      assert code == 1
      assert err =~ "requires a subcommand"
    end

    test "unknown subcommand" do
      {_out, err, code} = capture(fn -> Config.run(["frobnicate"]) end)
      assert code == 1
      assert err =~ "unknown config subcommand"
    end

    test "set without value" do
      {_out, err, code} = capture(fn -> Config.run(["set", "x"]) end)
      assert code == 1
      assert err =~ "requires a value"
    end
  end

  describe "--workspace override" do
    test "set targets the named workspace, not the default" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"name" => "default", "id" => "ws-default", "config" => %{}},
              %{"name" => "other", "id" => "ws-other", "config" => %{}}
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-other/config"},
         {%{"id" => "ws-other", "name" => "other", "config" => %{}}, 200}}
      ])

      {_out, _err, code} =
        capture(fn ->
          Config.run(["set", "review.rounds", "3", "--workspace", "other"])
        end)

      assert code == 0
    end
  end

  describe "overview" do
    test "renders grouped sections from config" do
      config = %{
        "tracker" => %{"type" => "github", "config" => %{"owner" => "acme"}},
        "merge" => %{"strategy" => "github", "auto_merge" => true},
        "agent" => %{"type" => "claude"},
        "routing" => %{"policy" => "by_priority"},
        "review" => %{"required" => true, "rounds" => 2},
        "standing_orders" => ["Check your inbox", "Keep PRs small"]
      }

      stub_routes([{{"get", "/api/workspaces"}, {default_ws(config), 200}}])

      {out, _err, code} = capture(fn -> Config.run(["overview"]) end)
      assert code == 0
      assert out =~ "== Tracker =="
      assert out =~ "type: github"
      assert out =~ "owner: acme"
      assert out =~ "== Merge =="
      assert out =~ "strategy: github"
      assert out =~ "auto_merge: true"
      assert out =~ "== Routing =="
      assert out =~ "policy: by_priority"
      assert out =~ "== Standing orders =="
      assert out =~ "1. Check your inbox"
    end

    # bd-73zv62: a per-repo merge override shows under the Merge section.
    test "renders merge.repos per-repo overrides" do
      config = %{
        "merge" => %{
          "strategy" => "github",
          "repos" => %{"mesaana" => %{"strategy" => "direct"}}
        }
      }

      stub_routes([{{"get", "/api/workspaces"}, {default_ws(config), 200}}])

      {out, _err, code} = capture(fn -> Config.run(["overview"]) end)
      assert code == 0
      assert out =~ "strategy: github"
      assert out =~ "repos.mesaana: strategy=direct"
    end

    test "never prints secret values — only key names" do
      config = %{"tracker" => %{"type" => "github"}}

      ws = %{
        "data" => [
          %{
            "name" => "default",
            "id" => @ws_id,
            "prefix" => "bd",
            "config" => config,
            "secret_keys" => ["tracker_token"]
          }
        ]
      }

      stub_routes([{{"get", "/api/workspaces"}, {ws, 200}}])

      {out, _err, code} = capture(fn -> Config.run(["overview"]) end)
      assert code == 0
      assert out =~ "== Secrets =="
      assert out =~ "tracker_token"
      assert out =~ "value hidden"
    end

    test "--json emits a structured, secret-safe map" do
      config = %{"merge" => %{"strategy" => "direct"}, "standing_orders" => ["A"]}

      stub_routes([{{"get", "/api/workspaces"}, {default_ws(config), 200}}])

      {out, _err, code} = capture(fn -> Config.run(["overview", "--json"]) end)
      assert code == 0
      decoded = Jason.decode!(out)
      assert decoded["merge"]["strategy"] == "direct"
      assert decoded["standing_orders"] == ["A"]
      assert Map.has_key?(decoded, "secret_keys")
    end
  end

  describe "schema" do
    test "prints the reference served by the server" do
      stub_get("/api/workspaces/config_schema", %{
        "text" => "WORKSPACE CONFIG REFERENCE\n  tracker (map)",
        "enums" => %{"tracker_types" => ["none"]}
      })

      {out, _err, code} = capture(fn -> Config.run(["schema"]) end)
      assert code == 0
      assert out =~ "WORKSPACE CONFIG REFERENCE"
    end

    test "--json emits the whole payload" do
      stub_get("/api/workspaces/config_schema", %{
        "text" => "T",
        "enums" => %{"quota_modes" => []}
      })

      {out, _err, 0} = capture(fn -> Config.run(["schema", "--json"]) end)
      assert %{"text" => "T", "enums" => _} = Jason.decode!(String.trim(out))
    end

    test "a server error is surfaced" do
      stub_get("/api/workspaces/config_schema", %{"error" => %{"message" => "boom"}}, 500)
      {_out, err, code} = capture(fn -> Config.run(["schema"]) end)
      assert code != 0
      assert err =~ "boom"
    end
  end
end
