defmodule ArbiterCli.Cmd.WorkspaceTest do
  # async: false — `Main.main(["-w", ...])` seeds the process-global ARB_WORKSPACE.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Workspace

  setup do
    prev = System.get_env("ARB_WORKSPACE")
    System.delete_env("ARB_WORKSPACE")

    on_exit(fn ->
      if prev,
        do: System.put_env("ARB_WORKSPACE", prev),
        else: System.delete_env("ARB_WORKSPACE")
    end)
  end

  test "list renders the configured workspaces" do
    stub_get("/api/workspaces", %{
      "data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]
    })

    {out, _err, code} = capture(fn -> Workspace.run(["list"]) end)
    assert code == 0
    assert out =~ "default"
    assert out =~ "prefix=bd"
  end

  test "show renders one workspace by id" do
    stub_get("/api/workspaces/ws-1", %{"id" => "ws-1", "name" => "default", "prefix" => "bd"})

    {out, _err, code} = capture(fn -> Workspace.run(["show", "ws-1"]) end)
    assert code == 0
    assert out =~ "default"
  end

  test "show renders one workspace by name" do
    stub_get("/api/workspaces/default", %{"id" => "ws-1", "name" => "default", "prefix" => "bd"})

    {out, _err, code} = capture(fn -> Workspace.run(["show", "default"]) end)
    assert code == 0
    assert out =~ "default"
    assert out =~ "prefix:      bd"
  end

  test "show with -w flag renders the targeted workspace" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-acme", "name" => "acme", "prefix" => "ax"}]}, 200}},
      {{"get", "/api/workspaces/ws-acme"},
       {%{"id" => "ws-acme", "name" => "acme", "prefix" => "ax"}, 200}}
    ])

    {out, _err, code} =
      capture(fn -> ArbiterCli.Main.main(["workspace", "show", "-w", "acme"]) end)

    assert code == 0
    assert out =~ "acme"
  end

  test "show requires an id or name when no workspace can be resolved" do
    stub_get("/api/workspaces", %{"data" => []})
    {_out, err, code} = capture(fn -> Workspace.run(["show"]) end)
    assert code == 1
    assert err =~ "workspace show requires a workspace id or name"
  end

  test "show with more than one argument errors" do
    {_out, err, code} = capture(fn -> Workspace.run(["show", "a", "b"]) end)
    assert code == 1
    assert err =~ "workspace show takes exactly one argument: the workspace id or name"
  end

  test "unknown subcommand errors" do
    {_out, err, code} = capture(fn -> Workspace.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown workspace subcommand"
  end

  describe "secret" do
    defp stub_one_workspace(secret_keys) do
      stub_get("/api/workspaces", %{
        "data" => [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "secret_keys" => secret_keys}
        ]
      })
    end

    test "secret ls lists configured key names" do
      stub_one_workspace(["tracker_token", "merge_token"])

      {out, _err, code} =
        capture(fn -> Workspace.run(["secret", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "tracker_token"
      assert out =~ "merge_token"
    end

    test "secret ls reports when none are set" do
      stub_one_workspace([])

      {out, _err, code} =
        capture(fn -> Workspace.run(["secret", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "(no secrets)"
    end

    test "secret set patches the workspace and echoes the resulting keys" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "secret_keys" => []}
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"},
         {%{"id" => "ws-1", "secret_keys" => ["tracker_token"]}, 200}}
      ])

      {out, err, code} =
        capture(fn ->
          Workspace.run(["secret", "set", "tracker_token", "sct_rw_x", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "tracker_token"
      # The token value is never printed back.
      refute out =~ "sct_rw_x"
      # ...and the argv form warns, without echoing the value (P-28).
      assert err =~ "warning: a secret on the command line"
      refute err =~ "sct_rw_x"
    end

    defp stub_secret_patch(test_pid) do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "secret_keys" => []}
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:patched, Jason.decode!(body)})
           Req.Test.json(conn, %{"id" => "ws-1", "secret_keys" => ["tracker_token"]})
         end}
      ])
    end

    test "secret set reads the value from stdin with `-`, with no warning" do
      stub_secret_patch(self())

      {_out, err, 0} =
        capture(
          fn ->
            Workspace.run(["secret", "set", "tracker_token", "-", "--workspace", "default"])
          end,
          input: "from-stdin\n"
        )

      assert_received {:patched, %{"secrets" => %{"tracker_token" => "from-stdin"}}}
      refute err =~ "`set <key> -` (stdin)"
    end

    test "secret set reads the value from --file, with no warning" do
      stub_secret_patch(self())
      path = Path.join(System.tmp_dir!(), "ws-secret-#{System.unique_integer([:positive])}")
      File.write!(path, "from-file\n")
      on_exit(fn -> File.rm(path) end)

      {_out, err, 0} =
        capture(fn ->
          Workspace.run([
            "secret",
            "set",
            "tracker_token",
            "--file",
            path,
            "--workspace",
            "default"
          ])
        end)

      assert_received {:patched, %{"secrets" => %{"tracker_token" => "from-file"}}}
      refute err =~ "`set <key> -` (stdin)"
    end

    test "secret set with an unreadable --file dies" do
      {_out, err, code} =
        capture(fn ->
          Workspace.run([
            "secret",
            "set",
            "k",
            "--file",
            "/nonexistent/secret",
            "--workspace",
            "d"
          ])
        end)

      assert code == 1
      assert err =~ "cannot read --file"
    end

    test "secret set requires a value" do
      {_out, err, code} =
        capture(fn ->
          Workspace.run(["secret", "set", "tracker_token", "--workspace", "default"])
        end)

      assert code == 1
      assert err =~ "requires <key> and a value"
    end

    test "secret rm removes an existing key" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{
                "id" => "ws-1",
                "name" => "default",
                "prefix" => "bd",
                "secret_keys" => ["tracker_token"]
              }
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"}, {%{"id" => "ws-1", "secret_keys" => []}, 200}}
      ])

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["secret", "rm", "tracker_token", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "ok"
    end

    test "secret rm rejects an unknown key" do
      stub_one_workspace(["other"])

      {_out, err, code} =
        capture(fn ->
          Workspace.run(["secret", "rm", "tracker_token", "--workspace", "default"])
        end)

      assert code == 1
      assert err =~ "no secret named"
    end

    test "unknown secret subcommand errors" do
      {_out, err, code} = capture(fn -> Workspace.run(["secret", "frobnicate"]) end)
      assert code == 1
      assert err =~ "unknown workspace secret subcommand"
    end
  end

  describe "create" do
    test "posts a workspace with config built from flags" do
      stub_routes([
        {{"post", "/api/workspaces"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["name"] == "acme"
           assert decoded["prefix"] == "ac"
           assert decoded["config"]["tracker"]["type"] == "github"
           assert decoded["config"]["merge"]["strategy"] == "gitlab"
           assert decoded["description"] == "Acme backend"

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "ws-9", "name" => "acme", "prefix" => "ac"})
         end}
      ])

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "create",
            "acme",
            "--prefix",
            "ac",
            "--tracker-type",
            "github",
            "--merger-strategy",
            "gitlab",
            "--description",
            "Acme backend"
          ])
        end)

      assert code == 0
      assert out =~ "created workspace acme"
      assert out =~ "ws-9"
    end

    test "omits prefix when not given, so the server's own default applies (D-C-19)" do
      stub_routes([
        {{"post", "/api/workspaces"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           refute Map.has_key?(Jason.decode!(body), "prefix")

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "ws-1", "name" => "plain", "prefix" => "ar"})
         end}
      ])

      {out, _err, code} = capture(fn -> Workspace.run(["create", "plain"]) end)
      assert code == 0
      assert out =~ "prefix=ar"
    end

    test "defaults tracker/merger when flags omitted" do
      stub_routes([
        {{"post", "/api/workspaces"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["config"]["tracker"]["type"] == "none"
           assert decoded["config"]["merge"]["strategy"] == "direct"
           refute Map.has_key?(decoded, "description")

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "ws-1", "name" => "plain", "prefix" => "bd"})
         end}
      ])

      {out, _err, code} = capture(fn -> Workspace.run(["create", "plain"]) end)
      assert code == 0
      assert out =~ "created workspace plain"
    end

    test "requires a name" do
      {_out, err, code} = capture(fn -> Workspace.run(["create"]) end)
      assert code == 1
      assert err =~ "requires a name"
    end

    test "rejects an invalid tracker type before calling the API" do
      {_out, err, code} =
        capture(fn -> Workspace.run(["create", "x", "--tracker-type", "bogus"]) end)

      assert code == 1
      assert err =~ "invalid --tracker-type"
    end

    test "rejects an invalid merger strategy before calling the API" do
      {_out, err, code} =
        capture(fn -> Workspace.run(["create", "x", "--merger-strategy", "bogus"]) end)

      assert code == 1
      assert err =~ "invalid --merger-strategy"
    end
  end

  describe "update" do
    defp stub_update(test_pid, expected) do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"patch", "/api/workspaces/ws-1"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           send(test_pid, {:patched, decoded})
           assert decoded == expected

           Req.Test.json(conn, %{
             "id" => "ws-1",
             "name" => decoded["name"] || "default",
             "prefix" => decoded["prefix"] || "bd",
             "description" => decoded["description"]
           })
         end}
      ])
    end

    test "sends only the given fields" do
      stub_update(self(), %{"name" => "renamed", "prefix" => "rn"})

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["update", "default", "--name", "renamed", "--prefix", "rn"])
        end)

      assert code == 0
      assert out =~ "updated workspace renamed"
      assert_received {:patched, %{"name" => "renamed"}}
    end

    test "--description can be cleared with an empty string" do
      stub_update(self(), %{"description" => ""})

      {_out, _err, code} =
        capture(fn -> Workspace.run(["update", "default", "--description", ""]) end)

      assert code == 0
    end

    test "requires at least one field" do
      {_out, err, code} = capture(fn -> Workspace.run(["update", "default"]) end)
      assert code == 1
      assert err =~ "nothing to update"
    end

    test "takes the workspace from --workspace when no positional is given" do
      stub_update(self(), %{"name" => "x"})

      {_out, _err, code} =
        capture(fn -> Workspace.run(["update", "--workspace", "default", "--name", "x"]) end)

      assert code == 0
    end

    test "rejects a second positional" do
      {_out, err, code} = capture(fn -> Workspace.run(["update", "a", "b", "--name", "x"]) end)
      assert code == 1
      assert err =~ "exactly one"
    end
  end

  describe "env" do
    @env_value "tok_cli_SECRET_value"

    defp stub_env_ws(env) do
      stub_get("/api/workspaces", %{
        "data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "worker_env" => env}]
      })
    end

    defp stub_env_patch(test_pid, response_env) do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{
                "id" => "ws-1",
                "name" => "default",
                "prefix" => "bd",
                "worker_env" => [%{"name" => "OLD", "secret" => false}]
              }
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-1"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:patched, Jason.decode!(body)})
           Req.Test.json(conn, %{"id" => "ws-1", "worker_env" => response_env})
         end}
      ])
    end

    test "ls lists names and secret flags" do
      stub_env_ws([%{"name" => "API_TOKEN", "secret" => true}, %{"name" => "LOG", "secret" => false}])

      {out, _err, code} = capture(fn -> Workspace.run(["env", "ls", "--workspace", "default"]) end)
      assert code == 0
      assert out =~ "API_TOKEN"
      assert out =~ "secret"
      assert out =~ "LOG"
    end

    test "ls --json and the empty case" do
      stub_env_ws([%{"name" => "A", "secret" => false}])

      {out, _err, 0} =
        capture(fn -> Workspace.run(["env", "ls", "--workspace", "default", "--json"]) end)

      assert Jason.decode!(String.trim(out)) == %{
               "worker_env" => [%{"name" => "A", "secret" => false}]
             }

      stub_env_ws([])
      {out, _err, 0} = capture(fn -> Workspace.run(["env", "ls", "--workspace", "default"]) end)
      assert out =~ "(no worker env vars)"
    end

    test "set --secret reads the value from stdin and never prints it" do
      stub_env_patch(self(), [%{"name" => "API_TOKEN", "secret" => true}])

      {out, err, 0} =
        capture(
          fn ->
            Workspace.run(["env", "set", "API_TOKEN", "-", "--secret", "--workspace", "default"])
          end,
          input: @env_value <> "\n"
        )

      assert_received {:patched, %{"worker_env" => %{"API_TOKEN" => %{"value" => @env_value, "secret" => true}}}}
      assert out =~ "API_TOKEN"
      refute out =~ @env_value
      refute err =~ @env_value
      refute err =~ "warning: a secret on the command line"
    end

    test "set with the value on argv warns without echoing it" do
      stub_env_patch(self(), [%{"name" => "LOG", "secret" => false}])

      {out, err, 0} =
        capture(fn ->
          Workspace.run(["env", "set", "LOG", "debug", "--workspace", "default"])
        end)

      assert_received {:patched, %{"worker_env" => %{"LOG" => patch}}}
      # No flag given: the server keeps an existing var's flag (false for a new one).
      assert patch == %{"value" => "debug"}
      assert err =~ "warning: a secret on the command line"
      refute out =~ "debug"
    end

    test "set reads the value from --file" do
      stub_env_patch(self(), [%{"name" => "F", "secret" => false}])
      path = Path.join(System.tmp_dir!(), "ws-env-#{System.unique_integer([:positive])}")
      File.write!(path, "from-file\n")
      on_exit(fn -> File.rm(path) end)

      {_out, _err, 0} =
        capture(fn ->
          Workspace.run(["env", "set", "F", "--file", path, "--workspace", "default"])
        end)

      assert_received {:patched, %{"worker_env" => %{"F" => %{"value" => "from-file"}}}}
    end

    test "set --secret / --no-secret with no value toggles the flag only" do
      stub_env_patch(self(), [%{"name" => "OLD", "secret" => true}])

      {_out, _err, 0} =
        capture(fn -> Workspace.run(["env", "set", "OLD", "--secret", "--workspace", "default"]) end)

      assert_received {:patched, %{"worker_env" => %{"OLD" => patch}}}
      assert patch == %{"secret" => true}
    end

    test "set without a value or a flag dies" do
      {_out, err, code} =
        capture(fn -> Workspace.run(["env", "set", "NAME", "--workspace", "default"]) end)

      assert code == 1
      assert err =~ "requires"
    end

    test "set rejects an invalid name client-side" do
      {_out, err, code} =
        capture(fn -> Workspace.run(["env", "set", "9bad", "v", "--workspace", "default"]) end)

      assert code == 1
      assert err =~ "invalid env var name"
    end

    test "rm sends a null for an existing name" do
      stub_env_patch(self(), [])

      {out, _err, 0} =
        capture(fn -> Workspace.run(["env", "rm", "OLD", "--workspace", "default"]) end)

      assert_received {:patched, %{"worker_env" => %{"OLD" => nil}}}
      assert out =~ "ok"
    end

    test "rm rejects an unknown name" do
      stub_env_ws([%{"name" => "A", "secret" => false}])

      {_out, err, code} =
        capture(fn -> Workspace.run(["env", "rm", "NOPE", "--workspace", "default"]) end)

      assert code == 1
      assert err =~ "no worker env var named"
    end

    test "unknown subcommand errors" do
      {_out, err, code} = capture(fn -> Workspace.run(["env", "frobnicate"]) end)
      assert code == 1
      assert err =~ "unknown workspace env subcommand"
    end
  end

  describe "standing-order" do
    defp ws_with_orders(orders) do
      stub_get("/api/workspaces", %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"standing_orders" => orders}
          }
        ]
      })
    end

    defp stub_order_write(suffix, expected_body, response_status, response_body) do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1" <> suffix},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:posted, Jason.decode!(body)})
           assert Jason.decode!(body) == expected_body

           conn
           |> Plug.Conn.put_status(response_status)
           |> Req.Test.json(response_body)
         end}
      ])
    end

    test "add posts one entry to the server-side append, never the whole list" do
      stub_order_write("/standing_orders", %{"text" => "Add two"}, 200, %{
        "standing_orders" => ["Keep one", "Add two"]
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "add", "Add two", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "2 standing order(s)"
      assert out =~ "Add two"
      assert_received {:posted, %{"text" => "Add two"}}
    end

    test "add never patches the config (no read-modify-write)" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/workspaces/ws-1/standing_orders"}, {%{"standing_orders" => ["x"]}, 200}}
        # no PATCH route: a config patch would 404 and fail the run
      ])

      {_out, _err, code} =
        capture(fn -> Workspace.run(["standing-order", "add", "x", "--workspace", "default"]) end)

      assert code == 0
    end

    test "rm sends the target; the server tells an index from text" do
      stub_order_write("/standing_orders/remove", %{"target" => "2"}, 200, %{
        "standing_orders" => ["a", "c"]
      })

      {out, _err, code} =
        capture(fn -> Workspace.run(["standing-order", "rm", "2", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "2 standing order(s)"

      stub_order_write("/standing_orders/remove", %{"target" => "drop me"}, 200, %{
        "standing_orders" => ["keep"]
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "rm", "drop me", "--workspace", "default"])
        end)

      assert code == 0
      assert out =~ "1 standing order(s)"
    end

    test "a server refusal (out of range, none left) is surfaced" do
      stub_order_write(
        "/standing_orders/remove",
        %{"target" => "9"},
        422,
        %{"error" => %{"type" => "invalid", "message" => "standing order index 9 out of range (1..1)"}}
      )

      {_out, err, code} =
        capture(fn -> Workspace.run(["standing-order", "rm", "9", "--workspace", "default"]) end)

      assert code == 1
      assert err =~ "out of range"
    end

    test "add rejects empty text before calling the server" do
      {_out, err, code} =
        capture(fn -> Workspace.run(["standing-order", "add", "  ", "--workspace", "default"]) end)

      assert code == 1
      assert err =~ "text must not be empty"
    end

    test "ls lists the orders with 1-based indices" do
      ws_with_orders(["First order", "Second order"])

      {out, _err, code} =
        capture(fn -> Workspace.run(["standing-order", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "1. First order"
      assert out =~ "2. Second order"
    end

    test "ls reports when there are none" do
      ws_with_orders([])

      {out, _err, code} =
        capture(fn -> Workspace.run(["standing-order", "ls", "--workspace", "default"]) end)

      assert code == 0
      assert out =~ "(no standing orders)"
    end

  end

  describe "standing-order --repo (canonical) and --rig (deprecated alias)" do
    defp ws_with_repo_paths(repo_paths) do
      stub_get("/api/workspaces", %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"repo_paths" => repo_paths}
          }
        ]
      })
    end

    test "add and rm carry the repo, and --rig is the same alias" do
      stub_order_write("/standing_orders", %{"text" => "Add two", "repo" => "client"}, 200, %{
        "standing_orders" => ["Keep one", "Add two"],
        "repo" => "client"
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "add",
            "Add two",
            "--workspace",
            "default",
            "--rig",
            "client"
          ])
        end)

      assert code == 0
      assert out =~ "2 standing order(s)"

      stub_order_write("/standing_orders/remove", %{"target" => "1", "repo" => "client"}, 200, %{
        "standing_orders" => [],
        "repo" => "client"
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "rm",
            "1",
            "--workspace",
            "default",
            "--repo",
            "client"
          ])
        end)

      assert code == 0
      assert out =~ "0 standing order(s)"
    end

    test "an unregistered repo is the server's 404, surfaced" do
      stub_order_write(
        "/standing_orders",
        %{"text" => "text", "repo" => "nope"},
        404,
        %{"error" => %{"type" => "not_found", "message" => "no repo named \"nope\" registered"}}
      )

      {_out, err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "add",
            "text",
            "--workspace",
            "default",
            "--rig",
            "nope"
          ])
        end)

      assert code != 0
      assert err =~ "no repo named"
    end

    test "ls lists a repo's own orders, not the workspace-global ones" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "ls", "--workspace", "default", "--rig", "client"])
        end)

      assert code == 0
      assert out =~ "1. Link the Figma design."
    end

    test "ls reports when a registered repo has none" do
      ws_with_repo_paths(%{"client" => %{"path" => "/x/client"}})

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "ls", "--workspace", "default", "--rig", "client"])
        end)

      assert code == 0
      assert out =~ "(no standing orders"
    end

    test "ls accepts --repo as the canonical flag, same as --rig" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run(["standing-order", "ls", "--workspace", "default", "--repo", "client"])
        end)

      assert code == 0
      assert out =~ "1. Link the Figma design."
    end

    test "--repo wins when both --repo and --rig are given" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]},
        "server" => %{"path" => "/x/server", "standing_orders" => ["Deploy to staging."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "ls",
            "--workspace",
            "default",
            "--repo",
            "client",
            "--rig",
            "server"
          ])
        end)

      assert code == 0
      assert out =~ "1. Link the Figma design."
      refute out =~ "Deploy to staging."
    end

    test "ls --json emits both the canonical \"repo\" key and the legacy \"rig\" key" do
      ws_with_repo_paths(%{
        "client" => %{"path" => "/x/client", "standing_orders" => ["Link the Figma design."]}
      })

      {out, _err, code} =
        capture(fn ->
          Workspace.run([
            "standing-order",
            "ls",
            "--workspace",
            "default",
            "--repo",
            "client",
            "--json"
          ])
        end)

      assert code == 0
      {:ok, decoded} = Jason.decode(String.trim(out))
      assert decoded["repo"] == "client"
      assert decoded["rig"] == "client"
    end
  end
end
